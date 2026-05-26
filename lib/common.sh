#!/usr/bin/env bash

# AWS SSO Profile Generator - 共通関数とカラー設定
# 全スクリプトで共通利用される関数とカラー定義

# ESCシーケンス定義
ESC=$(printf '\033')
CSI="${ESC}["

# カラー定義
RESET="${CSI}0m"
RED="${CSI}31m"
GREEN="${CSI}32m"
YELLOW="${CSI}33m"
BLUE="${CSI}34m"
GRAY="${CSI}37m"
NC="$RESET" # No Color (後方互換性のため)

# スピナー用制御文字
ERASE_LINE="${CSI}2K"
HIDE_CURSOR="${CSI}?25l"
SHOW_CURSOR="${CSI}?25h"

# ログ出力関数
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_debug() {
    if [ "${DEBUG:-}" = "1" ]; then
        echo -e "${GRAY}🔍 $1${NC}"
    fi
}

# ログファイル出力（カラーコードなし）
LOG_FILE=""

log_to_file() {
    if [ -n "${LOG_FILE:-}" ]; then
        # bash 4.2+ 内蔵の printf %()T で date サブシェルを排除 (~12x 高速)
        local ts
        printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
        printf '[%s] %s\n' "$ts" "$1" >> "$LOG_FILE"
    fi
}

# 設定ファイルのパスを取得
get_config_file() {
    if [ -n "${AWS_CONFIG_FILE:-}" ]; then
        echo "$AWS_CONFIG_FILE"
    else
        echo "$HOME/.aws/config"
    fi
}

# AWS_SSO_CONFIG_GENERATOR ブロックの START/END マーカー整合性チェック
# 不一致の場合は非ゼロを返し、stderr にエラー詳細を出力する
verify_marker_integrity() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 0
    fi

    local starts ends
    # grep -c は 0件のとき exit 1 を返すが、stdout に "0" を出力する
    # || true で exit 1 を吸収し、出力は "0" のまま残す（"0\n0" の重複出力を避ける）
    starts=$(grep -c '^# AWS_SSO_CONFIG_GENERATOR START' "$config_file" 2>/dev/null || true)
    ends=$(grep -c '^# AWS_SSO_CONFIG_GENERATOR END' "$config_file" 2>/dev/null || true)
    starts=${starts:-0}
    ends=${ends:-0}

    if [ "$starts" != "$ends" ]; then
        log_error "AWS_SSO_CONFIG_GENERATOR マーカーが不整合です"
        log_error "  START: $starts 個 / END: $ends 個"
        log_error "  対象ファイル: $config_file"
        log_error "  自動削除を中止しました。手動で確認してください。"
        return 1
    fi
    return 0
}

# 古いバックアップを最新 N 世代に絞る
# 引数: $1=設定ファイルパス, $2=保持世代数(省略時10)
rotate_backups() {
    local config_file="$1"
    local keep="${2:-10}"

    local removed
    # シェルグロブを使わず ls -t ベースで安全に列挙
    # shellcheck disable=SC2012
    removed=$(ls -t "${config_file}".backup.* 2>/dev/null | tail -n +"$((keep + 1))" || true)
    if [ -n "$removed" ]; then
        echo "$removed" | while IFS= read -r f; do
            [ -n "$f" ] && rm -f -- "$f"
        done
        local removed_count
        removed_count=$(echo "$removed" | grep -c . || true)
        log_info "古いバックアップを ${removed_count} 個削除しました (保持: ${keep} 世代)"
    fi
}

# ============================================================================
# キャッシュ層 (AWS SSO API レスポンスのローカルキャッシュ)
# ============================================================================

# キャッシュディレクトリと TTL (環境変数で上書き可能)
CACHE_DIR="${CACHE_DIR:-${PWD}/.aws-sso-cache}"
CACHE_EXPIRY_HOURS="${CACHE_EXPIRY_HOURS:-24}"

# セッション識別ハッシュ (start_url から 8 桁の hex を生成)
# 同じ start_url なら同じハッシュになるため、セッション設定変更時に自動無効化される
cache_session_hash() {
    local start_url="$1"
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$start_url" | md5sum | cut -c1-8
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$start_url" | md5 -q | cut -c1-8
    else
        # フォールバック: cksum (POSIX、ハッシュ強度は低いが常用可)
        printf '%s' "$start_url" | cksum | awk '{print $1}' | head -c 8
    fi
}

# キャッシュファイルパス算出
cache_file_accounts() {
    local session_name="$1"
    local hash="$2"
    echo "${CACHE_DIR}/accounts-${session_name}-${hash}.json"
}

cache_file_roles() {
    local account_id="$1"
    local hash="$2"
    echo "${CACHE_DIR}/roles-${account_id}-${hash}.json"
}

# キャッシュ有効性チェック (ファイル存在 + 非空 + TTL 内)
is_cache_valid() {
    local file="$1"
    [ -f "$file" ] && [ -s "$file" ] || return 1
    local max_mmin
    max_mmin=$(awk -v h="${CACHE_EXPIRY_HOURS:-24}" 'BEGIN{ printf "%.0f", h * 60 }')
    # find -mmin -N : 過去 N 分以内に変更されたファイルを返す (BSD/GNU 両対応)
    [ -n "$(find "$file" -mmin "-${max_mmin}" 2>/dev/null)" ]
}

# キャッシュディレクトリの確実な作成
ensure_cache_dir() {
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || {
            log_error "キャッシュディレクトリを作成できません: $CACHE_DIR"
            return 1
        }
    fi
}

# 原子的にキャッシュファイルを書き込む (.tmp 経由 + mv)
# 中断やプロセス競合でも壊れたファイルが残らない
write_cache_atomic() {
    local file="$1"
    local content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s\n' "$content" > "$tmp" || return 1
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# アカウント一覧のキャッシュ付き取得
# 引数: <session_name> <start_url> <access_token>
# 出力: list-accounts の raw JSON (stdout)
get_cached_accounts() {
    local session_name="$1"
    local start_url="$2"
    local token="$3"

    ensure_cache_dir || return 1

    local hash cache_file
    hash=$(cache_session_hash "$start_url")
    cache_file=$(cache_file_accounts "$session_name" "$hash")

    if is_cache_valid "$cache_file"; then
        log_debug "キャッシュヒット: $cache_file"
        cat "$cache_file"
        return 0
    fi

    log_debug "キャッシュミス: $cache_file (API 呼び出し)"
    local json
    if ! json=$(unset AWS_PROFILE; aws sso list-accounts --access-token "$token" --region "${SSO_REGION:-}" --output json 2>/dev/null); then
        return 1
    fi
    if ! echo "$json" | jq -e '.accountList' >/dev/null 2>&1; then
        return 1
    fi
    write_cache_atomic "$cache_file" "$json" || return 1
    echo "$json"
}

# ロール一覧のキャッシュ付き取得
# 引数: <account_id> <access_token> <session_name> <start_url>
# 出力: list-account-roles の raw JSON (stdout)
# 引数順は test/test-cache.sh および CACHE_USAGE.md の慣例に合わせる
get_cached_roles() {
    local account_id="$1"
    local token="$2"
    # session_name は将来の拡張用に受け取るが現時点では未使用 (hash は start_url から計算)
    local _session_name="$3"
    local start_url="$4"

    ensure_cache_dir || return 1

    local hash cache_file
    hash=$(cache_session_hash "$start_url")
    cache_file=$(cache_file_roles "$account_id" "$hash")

    if is_cache_valid "$cache_file"; then
        cat "$cache_file"
        return 0
    fi

    local json
    if ! json=$(unset AWS_PROFILE; aws sso list-account-roles --access-token "$token" --account-id "$account_id" --region "${SSO_REGION:-}" --output json 2>/dev/null); then
        return 1
    fi
    if ! echo "$json" | jq -e '.roleList' >/dev/null 2>&1; then
        return 1
    fi
    write_cache_atomic "$cache_file" "$json" || return 1
    echo "$json"
}

# キャッシュ削除
# 引数: [session_name]  指定時はそのセッションの accounts のみ削除、未指定は全削除
clear_cache() {
    local session_filter="${1:-}"

    if [ ! -d "$CACHE_DIR" ]; then
        log_info "キャッシュディレクトリが存在しません: $CACHE_DIR"
        return 0
    fi

    if [ -n "$session_filter" ]; then
        log_info "セッション '$session_filter' のキャッシュを削除中..."
        # accounts-{session}-{hash}.json から hash を抽出し、対応する roles-*-{hash}.json も削除
        local f basename prefix hash
        while IFS= read -r f; do
            basename="${f##*/}"
            prefix="accounts-${session_filter}-"
            hash="${basename#"$prefix"}"
            hash="${hash%.json}"
            rm -f "$f"
            if [ -n "$hash" ]; then
                find "$CACHE_DIR" -maxdepth 1 -type f -name "roles-*-${hash}.json" -delete 2>/dev/null || true
            fi
        done < <(find "$CACHE_DIR" -maxdepth 1 -type f -name "accounts-${session_filter}-*.json" 2>/dev/null)
    else
        log_info "全キャッシュを削除中..."
        find "$CACHE_DIR" -maxdepth 1 -type f \
            \( -name "accounts-*.json" -o -name "roles-*.json" -o -name "metadata.json" \) \
            -delete 2>/dev/null || true
    fi
    log_success "キャッシュを削除しました"
}

# キャッシュ統計表示
show_cache_stats() {
    log_info "キャッシュ統計:"
    echo "  キャッシュディレクトリ: $CACHE_DIR"

    if [ ! -d "$CACHE_DIR" ]; then
        echo "  (ディレクトリ未作成)"
        return 0
    fi

    local total accounts roles metadata
    total=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    accounts=$(find "$CACHE_DIR" -maxdepth 1 -type f -name "accounts-*.json" 2>/dev/null | wc -l | tr -d ' ')
    roles=$(find "$CACHE_DIR" -maxdepth 1 -type f -name "roles-*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ -f "$CACHE_DIR/metadata.json" ]; then
        metadata=1
    else
        metadata=0
    fi

    echo "  総ファイル数: $total"
    echo "  アカウントキャッシュ: $accounts"
    echo "  ロールキャッシュ: $roles"
    echo "  メタデータファイル: $metadata"
    echo "  有効期限: ${CACHE_EXPIRY_HOURS} 時間"

    local max_mmin expired
    max_mmin=$(awk -v h="${CACHE_EXPIRY_HOURS:-24}" 'BEGIN{ printf "%.0f", h * 60 }')
    expired=$(find "$CACHE_DIR" -maxdepth 1 -type f \
        \( -name "accounts-*.json" -o -name "roles-*.json" \) \
        ! -mmin "-${max_mmin}" 2>/dev/null | wc -l | tr -d ' ')
    echo "  期限切れファイル: $expired"
}

# メタデータファイルの更新 (親プロセスのみが呼ぶこと)
update_cache_metadata() {
    local session_name="$1"
    local start_url="$2"

    ensure_cache_dir || return 1

    local hash metadata_file content
    hash=$(cache_session_hash "$start_url")
    metadata_file="${CACHE_DIR}/metadata.json"
    content=$(cat <<EOF
{
  "last_session": "$session_name",
  "last_start_url": "$start_url",
  "session_hash": "$hash",
  "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "cache_expiry_hours": ${CACHE_EXPIRY_HOURS}
}
EOF
)
    write_cache_atomic "$metadata_file" "$content"
}

# 現在の日付と時間を取得
get_current_datetime() {
    date '+%Y/%m/%d %H:%M:%S'
}

# 現在の日付を取得（後方互換性のため）
get_current_date() {
    date '+%Y/%m/%d'
}

# 現在のタイムゾーン情報を取得
get_current_timezone() {
    date '+%Z %z'
}

# GNU dateコマンドの検出
is_gnu_date() {
    if date --version 2>/dev/null | grep -q "GNU"; then
        return 0  # GNU date
    else
        return 1  # BSD date or other
    fi
}

# UTC時刻をローカルタイムゾーンに変換
convert_utc_to_local() {
    local utc_time="$1"
    local local_time=""
    local timezone_info
    timezone_info=$(get_current_timezone)
    
    if is_gnu_date; then
        # GNU date (Linux or GNU coreutils)
        local_time=$(date -d "$utc_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        if [ -n "$local_time" ]; then
            echo "$local_time $timezone_info"
        else
            echo "$utc_time (GNU date変換失敗)"
        fi
    elif command -v gdate &> /dev/null; then
        # GNU date installed as gdate (common on macOS with Homebrew)
        local_time=$(gdate -d "$utc_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        if [ -n "$local_time" ]; then
            echo "$local_time $timezone_info"
        else
            echo "$utc_time (gdate変換失敗)"
        fi
    elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$utc_time" "+%Y-%m-%d %H:%M:%S" &>/dev/null; then
        # BSD date (macOS default, FreeBSD)
        local_time=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$utc_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        if [ -n "$local_time" ]; then
            echo "$local_time $timezone_info"
        else
            echo "$utc_time (BSD date変換失敗)"
        fi
    else
        # フォールバック: 元の時刻にタイムゾーン情報を付加
        echo "$utc_time (UTC) → ローカル変換不可、現在のTZ: $timezone_info"
    fi
}

# プロファイル統計の表示
show_profile_stats() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_warning "設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    local total_profiles
    local sso_profiles
    local total_sso_sessions
    local managed_count
    
    # 基本統計の取得
    total_profiles=$(grep -c "^\[profile " "$config_file" 2>/dev/null || echo "0")
    sso_profiles=$(grep -c "sso_session" "$config_file" 2>/dev/null || echo "0")
    total_sso_sessions=$(grep -c "^\[sso-session " "$config_file" 2>/dev/null || echo "0")
    
    # 自動生成プロファイル数の取得
    managed_count=$(sed -n '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/p' "$config_file" 2>/dev/null | grep -c "^\[profile " || echo "0")

    log_info "プロファイル統計:"
    echo "  総プロファイル数: $total_profiles"
    echo "  SSOプロファイル数: $sso_profiles"
    echo "  SSO セッション数: $total_sso_sessions"
    echo "  自動生成プロファイル数: $managed_count"
}

# 詳細なプロファイルサマリーの表示
show_detailed_profile_summary() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_warning "設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    local total_profiles
    local total_sso_sessions
    local managed_count
    
    # 基本統計の取得
    total_profiles=$(grep -c "^\[profile " "$config_file" 2>/dev/null || true)
    total_profiles=${total_profiles:-0}
    total_sso_sessions=$(grep -c "^\[sso-session " "$config_file" 2>/dev/null || true)
    total_sso_sessions=${total_sso_sessions:-0}

    # SSO セッション情報の取得
    local sso_sessions
    sso_sessions=$(grep -n "^\[sso-session " "$config_file" 2>/dev/null | head -5 || true)

    # 自動生成プロファイル数の取得
    managed_count=$(sed -n '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/p' "$config_file" 2>/dev/null | grep -c "^\[profile " || true)
    managed_count=${managed_count:-0}

    # 自動生成ブロックのタイムスタンプ取得
    local gen_timestamps
    gen_timestamps=$(grep "^# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null | sed 's/^# AWS_SSO_CONFIG_GENERATOR START //' || true)

    echo "設定サマリー:"
    echo "  SSO セッション数: $total_sso_sessions"
    echo "  プロファイル数: $total_profiles"
    echo "  自動生成プロファイル数: $managed_count"

    # SSO セッション一覧の表示
    if [ "$total_sso_sessions" -gt 0 ]; then
        echo
        echo "SSO セッション:"
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local session_name
                session_name=${line#*[sso-session }
                session_name=${session_name%]*}
                echo "  - $session_name"
            fi
        done <<< "$sso_sessions"
    fi

    # 自動生成プロファイルの生成日時一覧の表示
    if [ "$managed_count" -gt 0 ] && [ -n "$gen_timestamps" ]; then
        echo
        echo "自動生成プロファイル (生成日時):"
        while IFS= read -r ts; do
            if [ -n "$ts" ]; then
                echo "  - $ts"
            fi
        done <<< "$gen_timestamps"
    fi
}

# プロファイル統計データの取得（diff用）
get_profile_stats_data() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo "0 0 0 0"
        return 1
    fi
    
    local total_profiles
    local sso_profiles
    local total_sso_sessions
    local managed_count
    
    # 基本統計の取得
    total_profiles=$(grep -c "^\[profile " "$config_file" 2>/dev/null || echo "0")
    sso_profiles=$(grep -c "sso_session" "$config_file" 2>/dev/null || echo "0")
    total_sso_sessions=$(grep -c "^\[sso-session " "$config_file" 2>/dev/null || echo "0")
    
    # 自動生成プロファイル数の取得
    managed_count=$(sed -n '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/p' "$config_file" 2>/dev/null | grep -c "^\[profile " || echo "0")

    echo "$total_profiles $sso_profiles $total_sso_sessions $managed_count"
}

# プロファイル統計のdiff表示
show_profile_diff() {
    local before_stats="$1"
    local after_stats="$2"
    
    # 統計データを配列に分割
    read -r before_total before_sso before_sessions before_managed <<< "$before_stats"
    read -r after_total after_sso after_sessions after_managed <<< "$after_stats"
    
    # 差分を計算
    local diff_total=$((after_total - before_total))
    local diff_sso=$((after_sso - before_sso))
    local diff_sessions=$((after_sessions - before_sessions))
    local diff_managed=$((after_managed - before_managed))
    
    # diff形式で表示
    echo "--- 削除前"
    echo "+++ 削除後"
    echo "@@ プロファイル統計の変更 @@"
    
    # 総プロファイル数
    if [ "$diff_total" -ne 0 ]; then
        echo "- 総プロファイル数: $before_total"
        echo "+ 総プロファイル数: $after_total"
        if [ "$diff_total" -lt 0 ]; then
            echo "  (${diff_total#-} 個削除)"
        else
            echo "  (+$diff_total 個追加)"
        fi
    else
        echo "  総プロファイル数: $after_total (変更なし)"
    fi
    
    # SSOプロファイル数
    if [ "$diff_sso" -ne 0 ]; then
        echo "- SSOプロファイル数: $before_sso"
        echo "+ SSOプロファイル数: $after_sso"
        if [ "$diff_sso" -lt 0 ]; then
            echo "  (${diff_sso#-} 個削除)"
        else
            echo "  (+$diff_sso 個追加)"
        fi
    else
        echo "  SSOプロファイル数: $after_sso (変更なし)"
    fi
    
    # SSO セッション数
    if [ "$diff_sessions" -ne 0 ]; then
        echo "- SSO セッション数: $before_sessions"
        echo "+ SSO セッション数: $after_sessions"
        if [ "$diff_sessions" -lt 0 ]; then
            echo "  (${diff_sessions#-} 個削除)"
        else
            echo "  (+$diff_sessions 個追加)"
        fi
    else
        echo "  SSO セッション数: $after_sessions (変更なし)"
    fi
    
    # 自動生成プロファイル数
    if [ "$diff_managed" -ne 0 ]; then
        echo "- 自動生成プロファイル数: $before_managed"
        echo "+ 自動生成プロファイル数: $after_managed"
        if [ "$diff_managed" -lt 0 ]; then
            echo "  (${diff_managed#-} 個削除)"
        else
            echo "  (+$diff_managed 個追加)"
        fi
    else
        echo "  自動生成プロファイル数: $after_managed (変更なし)"
    fi
    
    # サマリー
    echo
    if [ "$diff_total" -lt 0 ]; then
        log_success "合計 ${diff_total#-} 個のプロファイルを削除しました"
    elif [ "$diff_total" -gt 0 ]; then
        log_info "合計 $diff_total 個のプロファイルが追加されました"
    else
        log_info "プロファイル数に変更はありませんでした"
    fi
}

# スピナー表示関数
show_spinner() {
    local pid=$1
    local message="${2:-処理中}"
    local i=0
    local spin='⠧⠏⠛⠹⠼⠶'
    local n=${#spin}

    printf "%s" "$HIDE_CURSOR"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s" "$ERASE_LINE"
        printf "%s %s" "${GREEN}${spin:i++%n:1}${RESET}" "$message"
        sleep 0.1
    done

    # スピナーをクリアしてカーソルを表示
    printf "\r%s%s" "$ERASE_LINE" "$SHOW_CURSOR"
}

# バックグラウンド実行でスピナー付きコマンド実行
run_with_spinner() {
    local message="$1"
    shift
    local command="$*"
    
    # コマンドをバックグラウンドで実行
    eval "$command" &
    local pid=$!
    
    # スピナーを表示
    show_spinner $pid "$message"
    
    # プロセスの終了を待つ
    wait $pid
    local exit_code=$?
    
    return $exit_code
}

# 簡単なスピナー（固定時間）
show_spinner_for_seconds() {
    local seconds="$1"
    local message="${2:-処理中}"
    local i=0
    local spin='⠧⠏⠛⠹⠼⠶'
    local n=${#spin}
    local count=0
    local max_count=$((seconds * 10))
    
    printf "%s" "$HIDE_CURSOR"
    while [ $count -lt $max_count ]; do
        printf "\r%s" "$ERASE_LINE"
        printf "%s %s" "${GREEN}${spin:i++%n:1}${RESET}" "$message"
        sleep 0.1
        count=$((count + 1))
    done

    # スピナーをクリアしてカーソルを表示
    printf "\r%s%s" "$ERASE_LINE" "$SHOW_CURSOR"
}

# プログレスバー風スピナー
show_progress_spinner() {
    local pid=$1
    local message="${2:-処理中}"
    local i=0
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local n=${#spin}
    
    printf "%s" "$HIDE_CURSOR"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s" "$ERASE_LINE"
        printf "%s %s" "${BLUE}${spin:i++%n:1}${RESET}" "$message"
        sleep 0.2
    done

    # スピナーをクリアしてカーソルを表示
    printf "\r%s%s" "$ERASE_LINE" "$SHOW_CURSOR"
}

# プログレス表示付きスピナー
show_progress_with_counter() {
    local current="$1"
    local total="$2"
    local message="${3:-処理中}"
    local i=0
    local spin='⠧⠏⠛⠹⠼⠶'
    local n=${#spin}
    
    # プログレス計算
    local percentage=0
    if [ "$total" -gt 0 ]; then
        percentage=$(( (current * 100) / total ))
    fi
    
    # プログレスバー作成（20文字）
    local progress_width=20
    local filled=$(( (current * progress_width) / total ))
    local progress_bar=""
    
    for ((j=0; j<progress_width; j++)); do
        if [ $j -lt $filled ]; then
            progress_bar+="█"
        else
            progress_bar+="░"
        fi
    done
    
    printf "\r%s" "$ERASE_LINE"
    printf "%s [%s] %d/%d (%d%%) %s" \
        "${GREEN}${spin:i++%n:1}${RESET}" \
        "$progress_bar" \
        "$current" \
        "$total" \
        "$percentage" \
        "$message"
}

# プログレス完了表示
show_progress_complete() {
    local total="$1"
    local message="${2:-完了}"
    
    printf "%s" "$ERASE_LINE"
    printf "%s [████████████████████] %d/%d (100%%) %s\n" \
        "${GREEN}✅${RESET}" \
        "$total" \
        "$total" \
        "$message"
    printf "%s" "$SHOW_CURSOR"
}
# SSO設定情報の取得
get_sso_config() {
    local config_file="$1"
    local selected_session="${2:-}"  # オプション: 特定のセッション名を指定
    
    if [ ! -f "$config_file" ]; then
        log_error "AWS設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    # 全てのSSO sessionセクションを取得
    local sso_sessions=()
    while IFS= read -r line; do
        if [[ $line =~ ^\[sso-session[[:space:]]*([^]]+)\] ]]; then
            sso_sessions+=("${BASH_REMATCH[1]}")
        fi
    done < "$config_file"
    

    
    if [ ${#sso_sessions[@]} -eq 0 ]; then
        log_error "SSO Session設定が見つかりません"
        return 1
    fi
    
    # 複数のセッションがある場合の処理
    local session_name=""
    if [ ${#sso_sessions[@]} -gt 1 ]; then
        if [ -n "$selected_session" ]; then
            # 指定されたセッション名が存在するかチェック
            local found=false
            for session in "${sso_sessions[@]}"; do
                if [ "$session" = "$selected_session" ]; then
                    session_name="$selected_session"
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                log_error "指定されたSSO Session '$selected_session' が見つかりません"
                return 1
            fi
        else
            # 複数のセッションを表示して最初のものを使用
            log_info "複数のSSO Sessionが見つかりました:"
            for i in "${!sso_sessions[@]}"; do
                echo "  $((i+1)). ${sso_sessions[i]}"
            done
            session_name="${sso_sessions[0]}"
            log_info "最初のセッション '${session_name}' を使用します"
        fi
    else
        session_name="${sso_sessions[0]}"
    fi
    
    # 指定されたセッションの設定詳細を取得
    local sso_region=""
    local sso_start_url=""
    local in_target_section=false
    
    while IFS= read -r line; do
        if [[ $line =~ ^\[sso-session[[:space:]]*([^]]+)\] ]]; then
            if [ "${BASH_REMATCH[1]}" = "$session_name" ]; then
                in_target_section=true
            else
                in_target_section=false
            fi
            continue
        elif [[ $line =~ ^\[ ]] && [[ $in_target_section == true ]]; then
            # 別のセクションに入ったら終了
            break
        elif [[ $in_target_section == true ]]; then
            if [[ $line =~ ^sso_region[[:space:]]*=[[:space:]]*(.*) ]]; then
                sso_region="${BASH_REMATCH[1]}"
            elif [[ $line =~ ^sso_start_url[[:space:]]*=[[:space:]]*(.*) ]]; then
                sso_start_url="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$config_file"
    
    # グローバル変数に設定（他のスクリプトで使用）
    export SSO_SESSION_NAME="$session_name"
    export SSO_REGION="$sso_region"
    export SSO_START_URL="$sso_start_url"
    
    return 0
}

# アクセストークンの取得
get_access_token() {
    local sso_start_url="$1"
    
    if [ -z "$sso_start_url" ]; then
        log_error "SSO Start URLが指定されていません"
        return 1
    fi
    
    log_info "アクセストークンの取得中..."
    
    local sso_cache_dir="$HOME/.aws/sso/cache"
    
    # SSO キャッシュディレクトリの存在確認
    if [ ! -d "$sso_cache_dir" ]; then
        log_error "SSO キャッシュディレクトリが見つかりません: $sso_cache_dir"
        show_sso_login_command "$SSO_SESSION_NAME"
        return 1
    fi

    # SSO Start URLを含むJSONファイルを検索
    local cache_files
    cache_files=$(grep -l -r "$sso_start_url" "$sso_cache_dir" 2>/dev/null || true)

    if [ -z "$cache_files" ]; then
        log_error "SSO セッションキャッシュが見つかりません"
        show_sso_login_command "$SSO_SESSION_NAME"
        return 1
    fi

    # 複数ファイルがある場合は最新のファイルを取得
    local latest_file
    latest_file=$(echo "$cache_files" | xargs ls -t | head -n1)

    log_info "SSO キャッシュファイル: $(basename "$latest_file")"

    # jqでaccessTokenを取得
    if ! command -v jq &> /dev/null; then
        log_error "jq コマンドが見つかりません。jqをインストールしてください"
        return 1
    fi

    local access_token
    access_token=$(jq -r '.accessToken // empty' "$latest_file" 2>/dev/null)

    if [ -z "$access_token" ]; then
        log_error "アクセストークンが見つかりません"
        show_sso_login_command "$SSO_SESSION_NAME"
        return 1
    fi
    
    # 有効期限もチェック
    local expires_at
    expires_at=$(jq -r '.expiresAt // empty' "$latest_file" 2>/dev/null)
    
    if [ -n "$expires_at" ]; then
        # 有効期限をローカルタイムゾーンで表示
        local local_expires
        local_expires=$(convert_utc_to_local "$expires_at")
        
        # 現在時刻と比較して有効性をチェック
        local current_timestamp
        local expires_timestamp
        
        if is_gnu_date; then
            # GNU date (Linux or GNU coreutils)
            current_timestamp=$(date +%s)
            expires_timestamp=$(date -d "$expires_at" +%s 2>/dev/null || echo "0")
        elif command -v gdate &> /dev/null; then
            # GNU date installed as gdate (common on macOS with Homebrew)
            current_timestamp=$(gdate +%s)
            expires_timestamp=$(gdate -d "$expires_at" +%s 2>/dev/null || echo "0")
        elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" "+%s" &>/dev/null; then
            # BSD date (macOS default, FreeBSD)
            current_timestamp=$(date +%s)
            expires_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" "+%s" 2>/dev/null || echo "0")
        else
            # タイムスタンプ比較をスキップ
            log_warning "セッション有効性の自動判定をスキップしました"
            echo "  有効期限: $local_expires"
            export ACCESS_TOKEN="$access_token"
            return 0
        fi
        
        if [ "$expires_timestamp" -le "$current_timestamp" ]; then
            echo "  有効期限: $local_expires"
            log_error "SSO セッションが期限切れです"
            show_sso_login_command "$SSO_SESSION_NAME"
            return 1
        else
            log_success "有効なアクセストークンを取得しました"
            echo "  有効期限: $local_expires"
        fi
    else
        log_success "有効なアクセストークンを取得しました（有効期限情報なし）"
    fi

    export ACCESS_TOKEN="$access_token"
    return 0
}

# SSO ログインコマンドの表示
show_sso_login_command() {
    local session_name="$1"
    
    if [ -n "$session_name" ]; then
        log_info "以下のコマンドでSSO ログインを実行してください:"
        echo "  aws sso login --sso-session $session_name"
        echo
        log_info "ブラウザが利用できない環境の場合:"
        echo "  aws sso login --sso-session $session_name --use-device-code"
    else
        log_info "以下のコマンドでSSO ログインを実行してください:"
        echo "  aws sso login --sso-session <session-name>"
        echo
        log_info "ブラウザが利用できない環境の場合:"
        echo "  aws sso login --sso-session <session-name> --use-device-code"
    fi
}

# SSO セッション状態チェック
check_sso_session_status() {
    local sso_start_url="$1"
    local session_name="$2"
    
    if [ -z "$sso_start_url" ]; then
        log_error "SSO Start URLが指定されていません"
        return 1
    fi
    
    log_info "SSO セッション状態を確認中..."
    
    local sso_cache_dir="$HOME/.aws/sso/cache"
    
    # SSO キャッシュディレクトリの存在確認
    if [ ! -d "$sso_cache_dir" ]; then
        log_warning "SSO キャッシュディレクトリが見つかりません: $sso_cache_dir"
        show_sso_login_command "$session_name"
        return 1
    fi
    
    # SSO Start URLを含むJSONファイルを検索
    local cache_files
    cache_files=$(grep -l -r "$sso_start_url" "$sso_cache_dir" 2>/dev/null || true)
    
    if [ -z "$cache_files" ]; then
        log_warning "SSO セッションキャッシュが見つかりません"
        show_sso_login_command "$session_name"
        return 1
    fi
    
    # 複数ファイルがある場合は最新のファイルを取得
    local latest_file
    latest_file=$(echo "$cache_files" | xargs ls -t | head -n1)
    
    log_info "SSO キャッシュファイル: $(basename "$latest_file")"
    
    # jqでセッション情報を取得
    if ! command -v jq &> /dev/null; then
        log_error "jq コマンドが見つかりません。jqをインストールしてください"
        return 1
    fi
    
    local access_token
    local expires_at
    access_token=$(jq -r '.accessToken // empty' "$latest_file" 2>/dev/null)
    expires_at=$(jq -r '.expiresAt // empty' "$latest_file" 2>/dev/null)
    
    if [ -z "$access_token" ]; then
        log_warning "アクセストークンが見つかりません"
        show_sso_login_command "$session_name"
        return 1
    fi
    
    if [ -n "$expires_at" ]; then
        # 有効期限をローカルタイムゾーンで表示
        local local_expires
        local_expires=$(convert_utc_to_local "$expires_at")
        
        # 現在時刻と比較して有効性をチェック
        local current_timestamp
        local expires_timestamp
        
        if is_gnu_date; then
            # GNU date (Linux or GNU coreutils)
            current_timestamp=$(date +%s)
            expires_timestamp=$(date -d "$expires_at" +%s 2>/dev/null || echo "0")
        elif command -v gdate &> /dev/null; then
            # GNU date installed as gdate (common on macOS with Homebrew)
            current_timestamp=$(gdate +%s)
            expires_timestamp=$(gdate -d "$expires_at" +%s 2>/dev/null || echo "0")
        elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" "+%s" &>/dev/null; then
            # BSD date (macOS default, FreeBSD)
            current_timestamp=$(date +%s)
            expires_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" "+%s" 2>/dev/null || echo "0")
        else
            log_warning "セッション有効性の自動判定をスキップしました"
            echo "  有効期限: $local_expires"
            return 0
        fi
        
        if [ "$expires_timestamp" -le "$current_timestamp" ]; then
            echo "  有効期限: $local_expires"
            log_error "SSO セッションが期限切れです"
            show_sso_login_command "$session_name"
            return 1
        else
            log_success "SSO セッションが有効です"
            echo "  有効期限: $local_expires"
        fi
    else
        log_success "SSO セッションが見つかりました（有効期限情報なし）"
    fi
    
    return 0
}