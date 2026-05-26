#!/usr/bin/env bash

# AWS SSO プロファイル自動生成スクリプト
# SSO Portal APIを使用してアカウントとロールを取得し、プロファイルを自動生成します

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/lib/common.sh"

# グローバル変数の初期化
SSO_SESSION_NAME=""
SSO_REGION=""
SSO_START_URL=""
ACCESS_TOKEN=""

# 一時ファイル/ディレクトリの管理
TEMP_FILES=()
TEMP_DIRS=()
cleanup_temp_files() {
    for f in "${TEMP_FILES[@]:-}"; do
        rm -f "$f"
    done
    for d in "${TEMP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup_temp_files EXIT


# AWS CLI SSO: ListAccounts (キャッシュ経由)
# 出力: "<account_id> <account_name>" の改行区切り
get_accounts_data() {
    if [ -z "$ACCESS_TOKEN" ]; then
        log_debug "ACCESS_TOKEN が設定されていません"
        return 1
    fi

    local accounts_json
    if ! accounts_json=$(get_cached_accounts "$SSO_SESSION_NAME" "$SSO_START_URL" "$ACCESS_TOKEN"); then
        log_debug "get_cached_accounts が失敗しました"
        return 1
    fi

    echo "$accounts_json" | jq -r '.accountList[] | "\(.accountId) \(.accountName)"'
}

# AWS CLI SSO: ListAccounts (ログ付き版)
list_accounts() {
    log_info "アカウント一覧を取得中..."

    local accounts_data
    if accounts_data=$(get_accounts_data); then
        log_success "アカウント一覧を取得しました"
        echo "$accounts_data"
        return 0
    else
        log_error "アカウント一覧の取得に失敗しました"
        show_sso_login_command "$SSO_SESSION_NAME"
        return 1
    fi
}

# AWS CLI SSO: ListAccountRoles (キャッシュ経由)
# 出力: ロール名の改行区切り
get_account_roles_data() {
    local account_id="$1"

    if [ -z "$account_id" ]; then
        return 1
    fi

    local roles_json
    if ! roles_json=$(get_cached_roles "$account_id" "$ACCESS_TOKEN" "$SSO_SESSION_NAME" "$SSO_START_URL"); then
        return 1
    fi

    echo "$roles_json" | jq -r '.roleList[] | "\(.roleName)"'
}

# AWS CLI SSO: ListAccountRoles (ログ付き版)
list_account_roles() {
    local account_id="$1"

    if [ -z "$account_id" ]; then
        log_error "アカウントIDが指定されていません"
        return 1
    fi

    log_info "アカウント $account_id のロール一覧を取得中..."

    local roles_data
    if roles_data=$(get_account_roles_data "$account_id"); then
        log_success "ロール一覧を取得しました"
        echo "$roles_data"
        return 0
    else
        log_error "ロール一覧の取得に失敗しました"
        return 1
    fi
}

# アカウント名の正規化（フル正規化）- pure bash パラメータ展開
# 小文字化 + スペース/ハイフン→アンダースコア + 英数字_以外を除去
normalize_account_name_full() {
    local s="${1,,}"                 # bash 4+ 小文字化
    s="${s//[[:space:]-]/_}"         # space/hyphen → underscore
    echo "${s//[^a-z0-9_]/}"         # 非 [a-z0-9_] を除去
}

# アカウント名の正規化（最小限）- pure bash パラメータ展開
# スペースのみアンダースコア化、大文字とハイフンはそのまま
normalize_account_name_minimal() {
    local s="${1//[[:space:]]/_}"    # space → underscore
    echo "${s//[^a-zA-Z0-9_-]/}"     # 非 [a-zA-Z0-9_-] を除去
}

# アカウント名の正規化（デフォルト）
normalize_account_name() {
    local account_name="$1"
    local normalization_type="${2:-minimal}"

    case "$normalization_type" in
        "full")
            normalize_account_name_full "$account_name"
            ;;
        *)
            normalize_account_name_minimal "$account_name"
            ;;
    esac
}

# プロファイル名の生成
generate_profile_name() {
    local prefix="$1"
    local account_name="$2"
    local account_id="$3"
    local role_name="$4"
    local normalization_type="$5"

    local normalized_name
    normalized_name=$(normalize_account_name "$account_name" "$normalization_type")

    # 元のロール名をそのまま使用
    echo "${prefix}-${normalized_name}-${account_id}:${role_name}"
}



# プロファイル設定の作成 - 単一 printf で外部プロセスゼロ
create_profile_config() {
    local config_file="$1" profile_name="$2" account_id="$3" role_name="$4" region="$5"
    printf '\n[profile %s]\nsso_session = %s\nsso_account_id = %s\nsso_role_name = %s\nregion = %s\noutput = json\ncli_pager =\n' \
        "$profile_name" "$SSO_SESSION_NAME" "$account_id" "$role_name" "$region" \
        >> "$config_file"
}

# 一括処理開始コメントの追加
add_batch_start_comment() {
    local config_file="$1"
    local current_datetime
    current_datetime=$(get_current_datetime)

    echo "" >> "$config_file"
    echo "# AWS_SSO_CONFIG_GENERATOR START $current_datetime" >> "$config_file"
}

# 一括処理終了コメントの追加
add_batch_end_comment() {
    local config_file="$1"
    local current_datetime
    current_datetime=$(get_current_datetime)

    echo "# AWS_SSO_CONFIG_GENERATOR END $current_datetime" >> "$config_file"
}

# 既存の自動生成ブロックをすべて削除
remove_generated_blocks() {
    local config_file="$1"

    if grep -q "^# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null; then
        # マーカー整合性チェック（不一致なら sed による事故的全削除を防ぐ）
        if ! verify_marker_integrity "$config_file"; then
            return 1
        fi
        log_info "既存の自動生成ブロックを削除中..."
        sed -i.tmp '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/d' "$config_file"
        rm -f "${config_file}.tmp"
        log_success "既存の自動生成ブロックを削除しました"
    fi
}

# 複数アカウントのプロファイル自動生成
# Phase 1: list-accounts でアカウント一覧取得 (キャッシュ経由)
# Phase 2: xargs -P でロール取得を並列化 (ワーカー: lib/fetch-account-roles.sh)
# Phase 3: 親プロセスが直列に設定ファイルへ追記
generate_profiles_for_accounts() {
    local config_file="$1"
    local prefix="$2"
    local max_accounts="$3"
    local region="$4"
    local normalization_type="$5"
    local dry_run="${6:-false}"

    if [ "$dry_run" = true ]; then
        log_info "DRY-RUN モード: 最大 $max_accounts アカウント分のプレビューを表示します..."
    else
        log_info "最大 $max_accounts 個のアカウントでプロファイルを生成します..."
    fi

    # 全体計測の開始
    local t_total_start
    t_total_start=$(perf_now)

    # Diff 用: 実行前の既存自動生成プロファイル一覧を取得 (空ならスキップ)
    local _diff_before_file
    _diff_before_file=$(mktemp)
    TEMP_FILES+=("$_diff_before_file")
    extract_auto_profiles "$config_file" > "$_diff_before_file"

    # ---------- Phase 1: アカウント一覧 + 設定ファイル準備 ----------
    local t_phase1_start
    t_phase1_start=$(perf_now)

    local accounts_data
    if ! accounts_data=$(get_accounts_data); then
        log_error "アカウント一覧の取得に失敗しました"
        return 1
    fi

    # アカウント数をカウントし、max_accounts で絞る
    local total_accounts
    total_accounts=$(echo "$accounts_data" | wc -l | tr -d ' ')
    if [ "$total_accounts" -gt "$max_accounts" ]; then
        total_accounts="$max_accounts"
    fi

    local accounts_subset
    accounts_subset=$(echo "$accounts_data" | head -n "$total_accounts")

    # ---------- 設定ファイルの準備 (バックアップ + 既存ブロック削除) ----------
    # dry_run の場合、設定ファイルへの書き込みは一切行わない
    if [ "$dry_run" != true ]; then
        if [ -f "$config_file" ]; then
            local backup_file
            backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$config_file" "$backup_file"
            log_info "設定ファイルをバックアップしました: $backup_file"
            rotate_backups "$config_file" 10
        fi

        if ! remove_generated_blocks "$config_file"; then
            log_error "既存ブロックの削除に失敗したため生成処理を中止します"
            return 1
        fi

        add_batch_start_comment "$config_file"
    fi

    # ---------- Phase 2: ロール取得を並列化 ----------
    local roles_tmpdir xargs_log script_dir worker parallel
    roles_tmpdir=$(mktemp -d)
    TEMP_DIRS+=("$roles_tmpdir")
    xargs_log=$(mktemp)
    TEMP_FILES+=("$xargs_log")

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    worker="${script_dir}/lib/fetch-account-roles.sh"

    # 並列度: --parallel フラグ > PARALLEL 環境変数 > デフォルト 8
    parallel="${PARALLEL_OPT:-${PARALLEL:-8}}"
    if ! [[ "$parallel" =~ ^[0-9]+$ ]] || [ "$parallel" -lt 1 ]; then
        log_warning "不正な並列度 '$parallel'。デフォルト 8 を使用します"
        parallel=8
    fi

    # ワーカーに必要な環境変数を export
    export ACCESS_TOKEN SSO_REGION SSO_SESSION_NAME SSO_START_URL CACHE_DIR CACHE_EXPIRY_HOURS

    # Phase 1 完了 → Phase 2 開始 (timing)
    local t_phase1 t_phase2_start
    t_phase1=$(perf_diff "$t_phase1_start")
    log_to_file "[TIMING] Phase 1 (list-accounts + setup): ${t_phase1}s"
    t_phase2_start=$(perf_now)

    echo
    log_info "Phase 2: ロール取得 (並列度 $parallel, 対象 $total_accounts アカウント)"
    echo

    printf "%s" "$HIDE_CURSOR"

    local account_ids
    account_ids=$(echo "$accounts_subset" | grep -oE '^[0-9]+')

    # === Pre-flight: 単一 batch stat で hit/miss 分類 ===
    # 各 cache file を find/stat で 1 件ずつ確認すると 187 件で ~6 秒かかるため、
    # bash でパス計算 (subshell ゼロ) + 単一 stat 呼び出しで全 mtime を一括取得する。
    local session_hash
    session_hash=$(cache_session_hash "$SSO_START_URL")

    local -a cache_paths=() account_array=()
    local _aid
    while IFS= read -r _aid; do
        [ -z "$_aid" ] && continue
        account_array+=("$_aid")
        cache_paths+=("${CACHE_DIR}/roles-${_aid}-${session_hash}.json")
    done <<< "$account_ids"

    # 単一 stat 呼び出しで全ファイルの mtime を取得 (BSD/GNU 両対応)
    # 存在しないファイルは出力されないため、後段の :-0 で自然に miss 扱いになる
    local -A _mtimes=()
    local _stat_path _stat_mtime
    if stat -f '%N %m' /dev/null &>/dev/null; then
        # BSD stat (macOS)
        while IFS=' ' read -r _stat_path _stat_mtime; do
            [ -n "$_stat_path" ] && [ -n "$_stat_mtime" ] && _mtimes["$_stat_path"]="$_stat_mtime"
        done < <(stat -f '%N %m' "${cache_paths[@]}" 2>/dev/null || true)
    else
        # GNU stat (Linux)
        while IFS=' ' read -r _stat_path _stat_mtime; do
            [ -n "$_stat_path" ] && [ -n "$_stat_mtime" ] && _mtimes["$_stat_path"]="$_stat_mtime"
        done < <(stat -c '%n %Y' "${cache_paths[@]}" 2>/dev/null || true)
    fi

    # TTL しきい値計算
    local _now_epoch _ttl_sec _threshold
    printf -v _now_epoch '%(%s)T' -1
    _ttl_sec=$(awk -v h="${CACHE_EXPIRY_HOURS:-24}" 'BEGIN{printf "%d", h*3600}')
    _threshold=$((_now_epoch - _ttl_sec))

    # 分類 (subshell ゼロ)
    local -a hit_list=() miss_list=()
    local _i _path _mtime
    for _i in "${!account_array[@]}"; do
        _path="${cache_paths[$_i]}"
        _mtime="${_mtimes[$_path]:-0}"
        if [ "$_mtime" -ge "$_threshold" ]; then
            hit_list+=("${account_array[$_i]}")
        else
            miss_list+=("${account_array[$_i]}")
        fi
    done

    local hit_n="${#hit_list[@]}" miss_n="${#miss_list[@]}"
    log_to_file "Phase 2 pre-flight: hit=$hit_n miss=$miss_n"

    # === Inline 並列処理: キャッシュヒットを軽量 bash -c で並列 (source common.sh 不要) ===
    # worker (lib/fetch-account-roles.sh) は ~870 行の common.sh を毎回 source するため
    # spawn コスト ~400ms。bash -c なら ~30-50ms で済み、cache hit ケースが大幅高速化。
    if [ "$hit_n" -gt 0 ]; then
        log_info "キャッシュヒット ${hit_n} アカウントを軽量並列で処理 (並列度 ${parallel})..."
        export _CACHE_DIR_X="$CACHE_DIR"
        export _SESSION_HASH_X="$session_hash"
        export _ROLES_TMPDIR_X="$roles_tmpdir"

        printf '%s\n' "${hit_list[@]}" | xargs -P "$parallel" -I {} \
            bash -c '
                aid="$1"
                cf="${_CACHE_DIR_X}/roles-${aid}-${_SESSION_HASH_X}.json"
                if jq -r ".roleList[].roleName" < "$cf" > "${_ROLES_TMPDIR_X}/${aid}.roles" 2>/dev/null; then
                    printf "hit %s\n" "$aid"
                else
                    printf "%s\n" "ロール JSON 解析失敗" > "${_ROLES_TMPDIR_X}/${aid}.err"
                    printf "err %s jq_parse_failed\n" "$aid"
                fi
            ' _ {} \
            >> "$xargs_log" 2>&1 &
        local inline_pid=$!

        # 進捗ポーリング
        while kill -0 "$inline_pid" 2>/dev/null; do
            local done_count
            done_count=$(find "$roles_tmpdir" -maxdepth 1 -type f \
                \( -name "*.roles" -o -name "*.err" \) 2>/dev/null | wc -l | tr -d ' ')
            show_progress_with_counter "$done_count" "$total_accounts" "ロール取得中 (cache)"
            sleep 0.3
        done
        wait "$inline_pid" || true
    fi

    # === Worker 並列処理: キャッシュ未ヒットのみ (フル機能の worker = API 呼び出し対応) ===
    if [ "$miss_n" -gt 0 ]; then
        log_info "キャッシュ未ヒット ${miss_n} アカウントを並列度 ${parallel} で取得中..."
        printf '%s\n' "${miss_list[@]}" | xargs -P "$parallel" -I {} \
            bash "$worker" {} "$roles_tmpdir" \
            >> "$xargs_log" 2>&1 &
        local xargs_pid=$!

        while kill -0 "$xargs_pid" 2>/dev/null; do
            local done_count
            done_count=$(find "$roles_tmpdir" -maxdepth 1 -type f \
                \( -name "*.roles" -o -name "*.err" \) 2>/dev/null | wc -l | tr -d ' ')
            show_progress_with_counter "$done_count" "$total_accounts" "ロール取得中 (API)"
            sleep 0.3
        done
        wait "$xargs_pid" || true
    fi

    show_progress_complete "$total_accounts" "ロール取得完了"

    # キャッシュ統計 (ログとサマリ表示)
    local hit_count fetch_count err_count
    hit_count=$(grep -c '^hit ' "$xargs_log" 2>/dev/null || true)
    fetch_count=$(grep -c '^fetch ' "$xargs_log" 2>/dev/null || true)
    err_count=$(grep -c '^err ' "$xargs_log" 2>/dev/null || true)
    hit_count=${hit_count:-0}
    fetch_count=${fetch_count:-0}
    err_count=${err_count:-0}
    log_to_file "Phase 2 統計: cache hit=$hit_count / API fetch=$fetch_count / error=$err_count"
    echo
    log_info "キャッシュヒット: $hit_count / API 取得: $fetch_count / 失敗: $err_count"

    # Phase 2 完了 → Phase 3 開始 (timing)
    local t_phase2 t_phase3_start
    t_phase2=$(perf_diff "$t_phase2_start")
    log_to_file "[TIMING] Phase 2 (list-account-roles × $total_accounts, parallel=$parallel, hit=$hit_count fetch=$fetch_count err=$err_count): ${t_phase2}s"
    t_phase3_start=$(perf_now)

    # ---------- Phase 3: 設定ファイル直列書き込み ----------
    local temp_accounts_file
    temp_accounts_file=$(mktemp)
    TEMP_FILES+=("$temp_accounts_file")
    echo "$accounts_subset" > "$temp_accounts_file"

    echo
    log_info "Phase 3: プロファイル設定書き込み"
    echo

    local count=0
    local total_profiles=0
    local failed_accounts=()
    local generated_profiles=()   # dry-run および diff 用に生成プロファイル名を蓄積

    while IFS= read -r line; do
        # pure bash パラメータ展開 (echo | grep の subshell 排除)
        local account_id="${line%% *}"      # 最初の空白までを抽出
        local account_name="${line#* }"     # 最初の空白以降

        # 数字のみであることを確認 (旧 grep -o '^[0-9]\+' の代替)
        if [ -z "$account_id" ] || [ -z "$account_name" ] || ! [[ "$account_id" =~ ^[0-9]+$ ]]; then
            continue
        fi

        show_progress_with_counter "$((count + 1))" "$total_accounts" "書き込み中: $account_name"

        local roles_file="${roles_tmpdir}/${account_id}.roles"
        local err_file="${roles_tmpdir}/${account_id}.err"

        if [ -f "$roles_file" ]; then
            local role_count=0
            while IFS= read -r role_name; do
                if [ -n "$role_name" ]; then
                    local profile_name
                    profile_name=$(generate_profile_name "$prefix" "$account_name" "$account_id" "$role_name" "$normalization_type")
                    if [ "$dry_run" != true ]; then
                        create_profile_config "$config_file" "$profile_name" "$account_id" "$role_name" "$region"
                    fi
                    generated_profiles+=("$profile_name")
                    log_to_file "✅ プロファイル作成: $profile_name"
                    role_count=$((role_count + 1))
                    total_profiles=$((total_profiles + 1))
                fi
            done < "$roles_file"
            log_to_file "アカウント $account_name: $role_count 個のプロファイルを処理"
        elif [ -f "$err_file" ]; then
            failed_accounts+=("$account_name ($account_id)")
            local err_detail
            err_detail=$(head -n1 "$err_file")
            log_to_file "⚠️ アカウント $account_name のロール取得に失敗: $err_detail"
        else
            failed_accounts+=("$account_name ($account_id)")
            log_to_file "⚠️ アカウント $account_name の結果ファイルが見つかりません"
        fi

        count=$((count + 1))
    done < "$temp_accounts_file"

    show_progress_complete "$total_accounts" "プロファイル生成完了"

    if [ "$dry_run" != true ]; then
        add_batch_end_comment "$config_file"
    fi

    # Phase 3 完了 + 全体集計 (timing)
    local t_phase3 t_total
    t_phase3=$(perf_diff "$t_phase3_start")
    t_total=$(perf_diff "$t_total_start")
    log_to_file "[TIMING] Phase 3 (config write × $total_profiles profiles): ${t_phase3}s"
    log_to_file "[TIMING] TOTAL (generate_profiles_for_accounts): ${t_total}s"

    echo
    if [ "$dry_run" = true ]; then
        log_success "DRY-RUN: $total_profiles 個のプロファイルが生成される予定です (設定ファイルは未変更)"
        # プレビュー: 先頭 10 件 + 末尾省略表示
        if [ "$total_profiles" -gt 0 ]; then
            echo "  ▼ プレビュー (先頭 10 件):"
            local _i
            for _i in "${generated_profiles[@]:0:10}"; do
                echo "    [profile $_i]"
            done
            if [ "$total_profiles" -gt 10 ]; then
                echo "    ... (残り $((total_profiles - 10)) 件はログファイルを参照)"
            fi
        fi
    else
        log_success "合計 $total_profiles 個のプロファイルを作成しました"
    fi
    log_info "処理時間: 全体 ${t_total}s (Phase1: ${t_phase1}s / Phase2: ${t_phase2}s / Phase3: ${t_phase3}s)"

    # === Diff 表示 (前回の自動生成プロファイル vs 今回) ===
    local _diff_after_file _added _removed _unchanged _added_count _removed_count _unchanged_count
    _diff_after_file=$(mktemp)
    TEMP_FILES+=("$_diff_after_file")
    printf '%s\n' "${generated_profiles[@]}" | sort > "$_diff_after_file"

    _added=$(comm -13 "$_diff_before_file" "$_diff_after_file")
    _removed=$(comm -23 "$_diff_before_file" "$_diff_after_file")
    _unchanged=$(comm -12 "$_diff_before_file" "$_diff_after_file")
    _added_count=$(printf '%s\n' "$_added" | grep -c . 2>/dev/null || true)
    _removed_count=$(printf '%s\n' "$_removed" | grep -c . 2>/dev/null || true)
    _unchanged_count=$(printf '%s\n' "$_unchanged" | grep -c . 2>/dev/null || true)
    _added_count=${_added_count:-0}
    _removed_count=${_removed_count:-0}
    _unchanged_count=${_unchanged_count:-0}

    # 初回実行は前回データなし → "初回生成" 扱い
    if [ ! -s "$_diff_before_file" ]; then
        log_to_file "Diff: 初回生成 (新規 $total_profiles 件)"
    else
        log_to_file "Diff: 追加=$_added_count / 削除=$_removed_count / 変更なし=$_unchanged_count"
    fi

    echo
    if [ ! -s "$_diff_before_file" ]; then
        log_info "📋 初回生成: 新規 $total_profiles プロファイル"
    elif [ "$_added_count" -eq 0 ] && [ "$_removed_count" -eq 0 ]; then
        log_info "📋 前回と同一 (変更なし: $_unchanged_count プロファイル)"
    else
        log_info "📋 前回からの差分:"
        if [ "$_added_count" -gt 0 ]; then
            echo "   + $_added_count 件 追加"
            printf '%s\n' "$_added" | head -5 | sed 's/^/     + /'
            [ "$_added_count" -gt 5 ] && echo "     ... (残り $((_added_count - 5)) 件はログ参照)"
        fi
        if [ "$_removed_count" -gt 0 ]; then
            echo "   - $_removed_count 件 削除"
            printf '%s\n' "$_removed" | head -5 | sed 's/^/     - /'
            [ "$_removed_count" -gt 5 ] && echo "     ... (残り $((_removed_count - 5)) 件はログ参照)"
        fi
        echo "   = $_unchanged_count 件 変更なし"

        # 追加/削除の完全リストはログにのみ出す
        if [ -n "$_added" ]; then
            printf '%s\n' "$_added" | while IFS= read -r p; do
                [ -n "$p" ] && log_to_file "Diff: + $p"
            done
        fi
        if [ -n "$_removed" ]; then
            printf '%s\n' "$_removed" | while IFS= read -r p; do
                [ -n "$p" ] && log_to_file "Diff: - $p"
            done
        fi
    fi

    # 失敗アカウントの集約報告
    if [ "${#failed_accounts[@]}" -gt 0 ]; then
        echo
        log_warning "ロール取得に失敗したアカウント (${#failed_accounts[@]} 個):"
        local acct
        for acct in "${failed_accounts[@]}"; do
            echo "  - $acct"
        done
        log_info "詳細は ${LOG_FILE} を参照してください"
    fi
}

# ヘルプメッセージの表示
show_usage() {
    echo "使用方法: $0 [OPTIONS]"
    echo
    echo "AWS SSO プロファイルの自動生成を行います。"
    echo "実行のたびに既存の自動生成ブロックを削除してから再生成します。"
    echo
    echo "オプション:"
    echo "  --help, -h          このヘルプメッセージを表示"
    echo "  --force, -f         デフォルト値で自動実行（対話なし）"
    echo "  --refresh-cache     既存キャッシュを削除してから API を再取得"
    echo "  --parallel N        並列度 (省略時 PARALLEL 環境変数または 8)"
    echo "  --dry-run           設定ファイルを変更せず、生成予定のプロファイルだけ表示"
    echo
    echo "例:"
    echo "  $0                  # 対話モードで実行"
    echo "  $0 --force          # デフォルト値で自動実行"
    echo "  $0 --refresh-cache  # キャッシュ無効化してから実行"
    echo "  $0 --parallel 16    # 並列度 16 で実行"
    echo "  $0 --dry-run --force # プレビューのみ (実ファイル変更なし)"
    echo "  $0 --help           # ヘルプを表示"
    echo
    echo "キャッシュ:"
    echo "  AWS SSO API レスポンスを ${CACHE_DIR:-.aws-sso-cache} に保存します"
    echo "  デフォルト TTL: ${CACHE_EXPIRY_HOURS:-24} 時間"
    echo "  環境変数: CACHE_DIR / CACHE_EXPIRY_HOURS で上書き可能"
    echo
    echo "並列処理:"
    echo "  list-account-roles をアカウント単位で並列実行します"
    echo "  AWS SSO Portal API の経験的安全圏 (5-10) からデフォルト 8 を採用"
    echo "  環境変数 PARALLEL でも上書き可能 (--parallel フラグが優先)"
    echo
    echo "デフォルト設定:"
    echo "  プレフィックス: awssso"
    echo "  処理アカウント数: 利用可能な全アカウント"
    echo "  リージョン: SSO設定から取得"
    echo "  正規化方式: minimal（スペース→アンダースコアのみ）"
    echo
    echo "注意事項:"
    echo "  - AWS SSO セッションが有効である必要があります"
    echo "  - 実行前に設定ファイルのバックアップが自動作成されます"
    echo "  - 既存の自動生成プロファイルは削除されてから再生成されます"
}

# AWS_PROFILE環境変数のチェックと処理
check_and_handle_aws_profile() {
    if [ -n "${AWS_PROFILE:-}" ]; then
        log_warning "AWS_PROFILE環境変数が設定されています: $AWS_PROFILE"
        echo
        log_info "AWS_PROFILEが設定されていると、以下の問題が発生する可能性があります:"
        echo "  - 指定されたプロファイルが存在しない場合、AWS SSOコマンドが失敗"
        echo "  - プロファイル削除後の再生成時にエラーが発生"
        echo "  - 意図しないプロファイルでのAWS API呼び出し"
        echo
        log_info "安全のため、AWS_PROFILE環境変数を一時的にunsetして続行します"

        # 元の値を保存（情報表示用）
        local original_aws_profile="$AWS_PROFILE"
        unset AWS_PROFILE

        log_success "AWS_PROFILE環境変数をunsetしました"
        log_info "元の値: $original_aws_profile"
        log_info "このスクリプト終了後、AWS_PROFILEは元の状態に戻ります"
        echo
    fi
}

# メイン実行
main() {
    local force_mode=false
    local refresh_cache=false
    local dry_run=false

    # コマンドライン引数の処理
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_usage
                exit 0
                ;;
            --force|-f)
                force_mode=true
                shift
                ;;
            --refresh-cache)
                refresh_cache=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --parallel)
                if [ $# -lt 2 ]; then
                    log_error "--parallel には数値引数が必要です"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
                    log_error "--parallel の値は 1 以上の整数で指定してください: $2"
                    exit 1
                fi
                # generate_profiles_for_accounts は PARALLEL_OPT を最優先で読む
                export PARALLEL_OPT="$2"
                shift 2
                ;;
            *)
                log_error "不明なオプション: $1"
                echo
                show_usage
                exit 1
                ;;
        esac
    done

    echo "🔄 AWS SSO プロファイル自動生成"
    echo "==============================="
    echo

    if [ "$force_mode" = true ]; then
        log_info "フォースモード: デフォルト値で自動実行します"
        echo
    fi

    if [ "$refresh_cache" = true ]; then
        log_info "--refresh-cache: 既存キャッシュを削除します"
        clear_cache
        echo
    fi

    # AWS_PROFILE環境変数のチェック
    check_and_handle_aws_profile

    # ログファイルの初期化
    LOG_FILE="${HOME}/.aws/sso-profile-generator-$(date +%Y%m%d_%H%M%S).log"
    echo "# AWS SSO Profile Generator Log - $(get_current_datetime)" > "$LOG_FILE"
    log_info "ログファイル: $LOG_FILE"

    # 設定ファイルの取得
    local config_file
    config_file=$(get_config_file)

    log_info "設定ファイル: $config_file"

    # SSO設定の取得
    if ! get_sso_config "$config_file"; then
        exit 1
    fi

    log_success "SSO設定を取得しました"
    echo "  セッション名: $SSO_SESSION_NAME"
    echo "  リージョン: $SSO_REGION"
    echo "  Start URL: $SSO_START_URL"
    echo

    # アクセストークンの取得
    if ! get_access_token "$SSO_START_URL"; then
        echo
        log_error "SSO セッションが無効です。プロファイル生成を続行できません。"
        show_sso_login_command "$SSO_SESSION_NAME"
        echo
        log_info "ログイン後、再度このスクリプトを実行してください。"
        exit 1
    fi

    echo

    # プロファイル自動生成の実行
    echo
    log_info "プロファイル自動生成を開始します..."

    # デフォルト設定
    local prefix="awssso"
    local region="$SSO_REGION"  # SSO設定から取得

    # ユーザー入力の取得
    echo
    if [ "$force_mode" = true ]; then
        log_info "フォースモード: プレフィックス '$prefix' を使用します"
    else
        read -r -p "プロファイル名のプレフィックス (デフォルト: $prefix): " user_prefix
        prefix=${user_prefix:-$prefix}
    fi

    # 利用可能なアカウント数を事前に取得・表示
    echo
    local available_accounts_data
    local max_accounts
    log_info "利用可能なアカウント数を確認中..."

    if available_accounts_data=$(get_accounts_data); then
        local available_count
        available_count=$(echo "$available_accounts_data" | wc -l | tr -d ' ')
        log_success "利用可能なアカウント数: $available_count 個"

        # デフォルト値を利用可能な全アカウント数に設定
        max_accounts="$available_count"
    else
        log_warning "アカウント数の取得に失敗しました。"
        log_info "考えられる原因:"
        echo "  - SSO セッションが期限切れ"
        echo "  - AWS CLI の設定に問題がある"
        echo "  - ネットワーク接続の問題"
        log_info "デバッグモード実行: DEBUG=1 ./generate-sso-profiles.sh"

        # フォールバック値として5を設定
        max_accounts=5
        log_info "フォールバック値として $max_accounts 個のアカウントを設定しました"
    fi

    echo
    if [ "$force_mode" = true ]; then
        log_info "フォースモード: 処理アカウント数 $max_accounts 個（全アカウント）を使用します"
    else
        read -r -p "処理するアカウント数 (デフォルト: $max_accounts - 全アカウント): " user_max_accounts
        max_accounts=${user_max_accounts:-$max_accounts}
    fi

    if [ "$force_mode" = true ]; then
        log_info "フォースモード: デフォルトリージョン '$region' を使用します"
    else
        read -r -p "デフォルトリージョン (デフォルト: $region): " user_region
        region=${user_region:-$region}
    fi

    local normalization_type="minimal"
    if [ "$force_mode" = true ]; then
        log_info "フォースモード: 正規化方式 'minimal' を使用します"
    else
        echo
        echo "アカウント名の正規化方式を選択してください:"
        echo "  1. minimal - スペース→アンダースコアのみ（大文字・ハイフンはそのまま）"
        echo "  2. full    - 小文字変換 + ハイフン→アンダースコア + スペース→アンダースコア"
        read -r -p "正規化方式 (1 または 2, デフォルト: 1): " normalization_choice

        if [ "${normalization_choice:-}" = "2" ]; then
            normalization_type="full"
        fi
    fi

    echo
    log_info "設定内容:"
    echo "  プレフィックス: $prefix"
    echo "  処理アカウント数: $max_accounts"
    echo "  デフォルトリージョン: $region"
    echo "  正規化方式: $normalization_type"
    echo

    # 正規化例を表示
    echo "正規化例:"
    echo "  元の名前: 'My Perfect-Web-Service Prod'"
    echo "  full:     '$(normalize_account_name_full "My Perfect-Web-Service Prod")'"
    echo "  minimal:  '$(normalize_account_name_minimal "My Perfect-Web-Service Prod")'"
    echo

    echo
    if [ "$force_mode" = true ]; then
        if [ "$dry_run" = true ]; then
            log_info "フォース + DRY-RUN: 設定ファイルは変更されません (プレビューのみ)"
        else
            log_info "フォースモード: 既存の自動生成ブロックを削除して再生成します"
        fi
        generate_profiles_for_accounts "$config_file" "$prefix" "$max_accounts" "$region" "$normalization_type" "$dry_run"
        update_cache_metadata "$SSO_SESSION_NAME" "$SSO_START_URL" || true
        echo
        if [ "$dry_run" = true ]; then
            log_success "DRY-RUN 完了 (実際の書き込みは行われませんでした)"
        else
            log_success "プロファイル自動生成が完了しました！"
            log_info "生成されたプロファイルを確認するには: aws configure list-profiles"
        fi
        log_info "詳細ログ: $LOG_FILE"
    else
        local prompt_msg
        if [ "$dry_run" = true ]; then
            prompt_msg="この設定で DRY-RUN を実行しますか？ (y/n): "
        else
            prompt_msg="この設定でプロファイルを生成しますか？ (y/n): "
        fi
        read -r -p "$prompt_msg" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            generate_profiles_for_accounts "$config_file" "$prefix" "$max_accounts" "$region" "$normalization_type" "$dry_run"
            update_cache_metadata "$SSO_SESSION_NAME" "$SSO_START_URL" || true
            echo
            if [ "$dry_run" = true ]; then
                log_success "DRY-RUN 完了 (実際の書き込みは行われませんでした)"
            else
                log_success "プロファイル自動生成が完了しました！"
                log_info "生成されたプロファイルを確認するには: aws configure list-profiles"
            fi
            log_info "詳細ログ: $LOG_FILE"
        else
            log_info "プロファイル生成をキャンセルしました"
        fi
    fi
}

# スクリプト実行
main "$@"
