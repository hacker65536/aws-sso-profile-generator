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
    local message="$1"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    fi
}

# 設定ファイルのパスを取得
get_config_file() {
    if [ -n "$AWS_CONFIG_FILE" ]; then
        echo "$AWS_CONFIG_FILE"
    else
        echo "$HOME/.aws/config"
    fi
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
    total_profiles=$(grep -c "^\[profile " "$config_file" 2>/dev/null || echo "0")
    total_sso_sessions=$(grep -c "^\[sso-session " "$config_file" 2>/dev/null || echo "0")
    
    # SSO セッション情報の取得
    local sso_sessions
    sso_sessions=$(grep -n "^\[sso-session " "$config_file" 2>/dev/null | head -5 || true)
    
    # 自動生成プロファイル数の取得
    managed_count=$(sed -n '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/p' "$config_file" 2>/dev/null | grep -c "^\[profile " || echo "0")

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
    
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        printf "%s" "$ERASE_LINE"
        printf "%s %s" "${GREEN}${spin:i++%n:1}${RESET}" "$message"
        printf "%s\r" "$HIDE_CURSOR"
    done
    
    # スピナーをクリアしてカーソルを表示
    printf "%s%s" "$ERASE_LINE" "$SHOW_CURSOR"
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
    
    while [ $count -lt $max_count ]; do
        sleep 0.1
        printf "%s" "$ERASE_LINE"
        printf "%s %s" "${GREEN}${spin:i++%n:1}${RESET}" "$message"
        printf "%s\r" "$HIDE_CURSOR"
        count=$((count + 1))
    done
    
    # スピナーをクリアしてカーソルを表示
    printf "%s%s" "$ERASE_LINE" "$SHOW_CURSOR"
}

# プログレスバー風スピナー
show_progress_spinner() {
    local pid=$1
    local message="${2:-処理中}"
    local i=0
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local n=${#spin}
    
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        printf "%s" "$ERASE_LINE"
        printf "%s %s" "${BLUE}${spin:i++%n:1}${RESET}" "$message"
        printf "%s\r" "$HIDE_CURSOR"
    done
    
    # スピナーをクリアしてカーソルを表示
    printf "%s%s" "$ERASE_LINE" "$SHOW_CURSOR"
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
    
    printf "%s" "$ERASE_LINE"
    printf "%s [%s] %d/%d (%d%%) %s" \
        "${GREEN}${spin:i++%n:1}${RESET}" \
        "$progress_bar" \
        "$current" \
        "$total" \
        "$percentage" \
        "$message"
    printf "%s\r" "$HIDE_CURSOR"
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