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
    # カーソル表示を確実に戻す (スピナーで非表示にしていた場合)
    printf "%s" "${SHOW_CURSOR:-}" 2>/dev/null || true
    # advisory lock を解放 (取得していなければ no-op)
    type -t release_lock >/dev/null 2>&1 && release_lock || true
}
# Ctrl+C / kill 受信時もクリーンアップして適切に終了
trap 'cleanup_temp_files; echo; log_warning "Interrupted"; exit 130' INT
trap 'cleanup_temp_files; echo; log_warning "Termination signal received"; exit 143' TERM
trap cleanup_temp_files EXIT


# AWS CLI SSO: ListAccounts (キャッシュ経由)
# 出力: "<account_id> <account_name>" の改行区切り
get_accounts_data() {
    if [ -z "$ACCESS_TOKEN" ]; then
        log_debug "ACCESS_TOKEN is not set"
        return 1
    fi

    local accounts_json
    if ! accounts_json=$(get_cached_accounts "$SSO_SESSION_NAME" "$SSO_START_URL" "$ACCESS_TOKEN"); then
        log_debug "get_cached_accounts failed"
        return 1
    fi

    echo "$accounts_json" | jq -r '.accountList[] | "\(.accountId) \(.accountName)"'
}

# AWS CLI SSO: ListAccounts (with logging)
list_accounts() {
    log_info "Fetching account list..."

    local accounts_data
    if accounts_data=$(get_accounts_data); then
        log_success "Account list fetched"
        echo "$accounts_data"
        return 0
    else
        log_error "Failed to fetch account list"
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
        log_error "Account ID is required"
        return 1
    fi

    log_info "Fetching roles for account $account_id..."

    local roles_data
    if roles_data=$(get_account_roles_data "$account_id"); then
        log_success "Roles fetched"
        echo "$roles_data"
        return 0
    else
        log_error "Failed to fetch roles"
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
        log_info "Removing existing auto-generated block..."
        sed -i.tmp '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/d' "$config_file"
        rm -f "${config_file}.tmp"
        # sed が残す末尾空行を整理 (再実行ごとの空行累積を防ぐ)
        trim_trailing_empty_lines "$config_file"
        log_success "Existing auto-generated block removed"
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
        log_info "DRY-RUN mode: previewing up to $max_accounts accounts..."
    else
        log_info "Generating profiles for up to $max_accounts accounts..."
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
        log_error "Failed to fetch account list"
        return 1
    fi

    # --account-filter が指定されていれば accounts_data を絞る (glob マッチ)
    if [ -n "${ACCOUNT_FILTER:-}" ]; then
        local _filtered
        _filtered=$(echo "$accounts_data" | awk -v pat="$ACCOUNT_FILTER" '
            BEGIN { gsub(/[.+]/, "\\&", pat); gsub(/\*/, ".*", pat); gsub(/\?/, ".", pat); pat = "^" pat "$" }
            { name = $0; sub(/^[0-9]+ /, "", name); if (name ~ pat) print }
        ')
        local _before _after
        _before=$(echo "$accounts_data" | grep -c . 2>/dev/null || true)
        _after=$(echo "$_filtered" | grep -c . 2>/dev/null || true)
        log_info "--account-filter '$ACCOUNT_FILTER' applied: ${_before:-0} -> ${_after:-0} accounts"
        accounts_data="$_filtered"
    fi

    # アカウント数をカウントし、max_accounts で絞る
    local total_accounts
    total_accounts=$(echo "$accounts_data" | grep -c . 2>/dev/null || true)
    total_accounts=${total_accounts:-0}
    if [ "$total_accounts" -eq 0 ]; then
        log_error "No accounts to process (check your --account-filter pattern)"
        return 1
    fi
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
            log_info "Config file backed up to: $backup_file"
            rotate_backups "$config_file" 10
        fi

        if ! remove_generated_blocks "$config_file"; then
            log_error "Failed to remove existing block; aborting"
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
        log_warning "Invalid parallel value '$parallel'; falling back to 8"
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
    log_info "Phase 2: fetch roles (parallel=$parallel, $total_accounts accounts)"

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
        log_info "Cache hit: processing ${hit_n} accounts inline (parallel=${parallel})..."
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
                    printf "%s\n" "Failed to parse roles JSON" > "${_ROLES_TMPDIR_X}/${aid}.err"
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
            show_progress_with_counter "$done_count" "$total_accounts" "Fetching roles (cache)"
            sleep 0.3
        done
        wait "$inline_pid" || true
    fi

    # === Worker 並列処理: キャッシュ未ヒットのみ (フル機能の worker = API 呼び出し対応) ===
    if [ "$miss_n" -gt 0 ]; then
        log_info "Cache miss: fetching ${miss_n} accounts via AWS API (parallel=${parallel})..."
        printf '%s\n' "${miss_list[@]}" | xargs -P "$parallel" -I {} \
            bash "$worker" {} "$roles_tmpdir" \
            >> "$xargs_log" 2>&1 &
        local xargs_pid=$!

        while kill -0 "$xargs_pid" 2>/dev/null; do
            local done_count
            done_count=$(find "$roles_tmpdir" -maxdepth 1 -type f \
                \( -name "*.roles" -o -name "*.err" \) 2>/dev/null | wc -l | tr -d ' ')
            show_progress_with_counter "$done_count" "$total_accounts" "Fetching roles (API)"
            sleep 0.3
        done
        wait "$xargs_pid" || true
    fi

    show_progress_complete "$total_accounts" "Phase 2 complete"

    # キャッシュ統計 (ログとサマリ表示)
    local hit_count fetch_count err_count
    hit_count=$(grep -c '^hit ' "$xargs_log" 2>/dev/null || true)
    fetch_count=$(grep -c '^fetch ' "$xargs_log" 2>/dev/null || true)
    err_count=$(grep -c '^err ' "$xargs_log" 2>/dev/null || true)
    hit_count=${hit_count:-0}
    fetch_count=${fetch_count:-0}
    err_count=${err_count:-0}
    log_to_file "Phase 2 stats: cache hit=$hit_count / API fetch=$fetch_count / error=$err_count"
    log_info "Cache hit: $hit_count / API fetch: $fetch_count / errors: $err_count"

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
    log_info "Phase 3: writing profile configs"

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

        show_progress_with_counter "$((count + 1))" "$total_accounts" "Writing: $account_name"

        local roles_file="${roles_tmpdir}/${account_id}.roles"
        local err_file="${roles_tmpdir}/${account_id}.err"

        if [ -f "$roles_file" ]; then
            local role_count=0
            while IFS= read -r role_name; do
                if [ -n "$role_name" ]; then
                    # --role-filter が指定されていればロール名で絞り込み (bash パターンマッチ)
                    # shellcheck disable=SC2053  # 右辺は glob として展開させる意図的な使い方
                    if [ -n "${ROLE_FILTER:-}" ] && [[ ! "$role_name" == ${ROLE_FILTER} ]]; then
                        continue
                    fi
                    local profile_name
                    profile_name=$(generate_profile_name "$prefix" "$account_name" "$account_id" "$role_name" "$normalization_type")
                    if [ "$dry_run" != true ]; then
                        create_profile_config "$config_file" "$profile_name" "$account_id" "$role_name" "$region"
                    fi
                    generated_profiles+=("$profile_name")
                    log_to_file "✅ Profile created: $profile_name"
                    role_count=$((role_count + 1))
                    total_profiles=$((total_profiles + 1))
                fi
            done < "$roles_file"
            log_to_file "Account $account_name: $role_count profiles processed"
        elif [ -f "$err_file" ]; then
            failed_accounts+=("$account_name ($account_id)")
            local err_detail
            err_detail=$(head -n1 "$err_file")
            log_to_file "⚠️ Account $account_name failed to fetch roles: $err_detail"
        else
            failed_accounts+=("$account_name ($account_id)")
            log_to_file "⚠️ Account $account_name has no result file"
        fi

        count=$((count + 1))
    done < "$temp_accounts_file"

    show_progress_complete "$total_accounts" "Phase 3 complete"

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
        log_success "DRY-RUN: $total_profiles profiles would be generated (config file unchanged)"
        # プレビュー: 先頭 10 件 + 末尾省略表示
        if [ "$total_profiles" -gt 0 ]; then
            echo "  ▼ Preview (first 10):"
            local _i
            for _i in "${generated_profiles[@]:0:10}"; do
                echo "    [profile $_i]"
            done
            if [ "$total_profiles" -gt 10 ]; then
                echo "    ... ($((total_profiles - 10)) more, see log file)"
            fi
        fi
    else
        log_success "Generated $total_profiles profiles in total"
    fi
    log_info "Elapsed: total ${t_total}s (Phase1: ${t_phase1}s / Phase2: ${t_phase2}s / Phase3: ${t_phase3}s)"

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
        log_to_file "Diff: initial generation (new: $total_profiles)"
    else
        log_to_file "Diff: added=$_added_count / removed=$_removed_count / unchanged=$_unchanged_count"
    fi

    echo
    if [ ! -s "$_diff_before_file" ]; then
        log_info "📋 Initial generation: $total_profiles new profiles"
    elif [ "$_added_count" -eq 0 ] && [ "$_removed_count" -eq 0 ]; then
        log_info "📋 No changes since last run ($_unchanged_count profiles)"
    else
        log_info "📋 Diff from last run:"
        if [ "$_added_count" -gt 0 ]; then
            echo "   + $_added_count added"
            printf '%s\n' "$_added" | head -5 | sed 's/^/     + /'
            [ "$_added_count" -gt 5 ] && echo "     ... ($((_added_count - 5)) more, see log)"
        fi
        if [ "$_removed_count" -gt 0 ]; then
            echo "   - $_removed_count removed"
            printf '%s\n' "$_removed" | head -5 | sed 's/^/     - /'
            [ "$_removed_count" -gt 5 ] && echo "     ... ($((_removed_count - 5)) more, see log)"
        fi
        echo "   = $_unchanged_count unchanged"

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
        log_warning "Accounts that failed to fetch roles (${#failed_accounts[@]}):"
        local acct
        for acct in "${failed_accounts[@]}"; do
            echo "  - $acct"
        done
        log_info "See ${LOG_FILE} for details"
    fi
}

# ヘルプメッセージの表示
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Auto-generate AWS SSO profiles in ~/.aws/config."
    echo "On each run, the existing auto-generated block is removed and re-created."
    echo
    echo "Options:"
    echo "  --help, -h           Show this help message"
    echo "  --force, -f          Run with default values (non-interactive)"
    echo "  --refresh-cache      Clear cache then re-fetch from AWS API"
    echo "  --parallel N         Parallelism (default: PARALLEL env var or 8)"
    echo "  --dry-run            Preview profiles without modifying the config file"
    echo "  --account-filter PATTERN  Filter accounts by name glob (e.g. 'prod-*')"
    echo "  --role-filter PATTERN     Filter roles by name glob (e.g. 'AWSReadOnly*')"
    echo
    echo "Examples:"
    echo "  $0                   # Interactive mode"
    echo "  $0 --force           # Non-interactive with defaults"
    echo "  $0 --refresh-cache   # Invalidate cache and re-fetch"
    echo "  $0 --parallel 16     # Run with parallelism 16"
    echo "  $0 --dry-run --force # Preview only (no file changes)"
    echo "  $0 --help            # Show help"
    echo
    echo "Cache:"
    echo "  AWS SSO API responses are stored in ${CACHE_DIR:-.aws-sso-cache}"
    echo "  Default TTL: ${CACHE_EXPIRY_HOURS:-24} hours"
    echo "  Env vars: CACHE_DIR / CACHE_EXPIRY_HOURS"
    echo
    echo "Parallel processing:"
    echo "  list-account-roles is parallelized per account"
    echo "  Default 8 is within AWS SSO Portal API's safe range (5-10 concurrent)"
    echo "  Env var PARALLEL also works (--parallel flag takes precedence)"
    echo
    echo "Defaults:"
    echo "  Prefix:       awssso"
    echo "  Max accounts: all available"
    echo "  Region:       from SSO config"
    echo "  Normalization: minimal (space -> underscore only)"
    echo
    echo "Notes:"
    echo "  - An active AWS SSO session is required"
    echo "  - The config file is automatically backed up before changes"
    echo "  - Existing auto-generated profiles are removed and re-created"
}

# AWS_PROFILE環境変数のチェックと処理
check_and_handle_aws_profile() {
    if [ -n "${AWS_PROFILE:-}" ]; then
        log_warning "AWS_PROFILE is set: $AWS_PROFILE"
        echo
        log_info "When AWS_PROFILE is set, the following issues may occur:"
        echo "  - AWS SSO commands fail if the profile does not exist"
        echo "  - Errors after profile deletion during regeneration"
        echo "  - Unintended AWS API calls under the wrong profile"
        echo
        log_info "Unsetting AWS_PROFILE temporarily for safety..."

        # 元の値を保存（情報表示用）
        local original_aws_profile="$AWS_PROFILE"
        unset AWS_PROFILE

        log_success "AWS_PROFILE has been unset"
        log_info "Original value: $original_aws_profile"
        log_info "AWS_PROFILE will be restored after this script exits"
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
            --account-filter)
                if [ $# -lt 2 ]; then
                    log_error "--account-filter requires a glob pattern (e.g. 'prod-*')"
                    exit 1
                fi
                export ACCOUNT_FILTER="$2"
                shift 2
                ;;
            --role-filter)
                if [ $# -lt 2 ]; then
                    log_error "--role-filter requires a glob pattern (e.g. 'AWSReadOnly*')"
                    exit 1
                fi
                export ROLE_FILTER="$2"
                shift 2
                ;;
            --parallel)
                if [ $# -lt 2 ]; then
                    log_error "--parallel requires a numeric argument"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
                    log_error "--parallel value must be an integer >= 1: $2"
                    exit 1
                fi
                # generate_profiles_for_accounts は PARALLEL_OPT を最優先で読む
                export PARALLEL_OPT="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                echo
                show_usage
                exit 1
                ;;
        esac
    done

    echo "🔄 AWS SSO Profile Generator"
    echo "==============================="
    echo

    # 並行実行ガード (mkdir ベース advisory lock)
    # ~/.aws/.aws-sso-pg.lock があれば二重起動とみなし即座に終了
    if ! acquire_lock; then
        log_error "Another instance is running (lock dir: \$HOME/.aws/.aws-sso-pg.lock)"
        log_info "generate-sso-profiles.sh may be running in another terminal"
        log_info "To force-remove the lock: rm -rf \"\$HOME/.aws/.aws-sso-pg.lock\""
        exit 1
    fi

    if [ "$force_mode" = true ]; then
        log_info "Force mode: running with defaults"
        echo
    fi

    if [ "$refresh_cache" = true ]; then
        log_info "--refresh-cache: clearing existing cache"
        clear_cache
        echo
    fi

    # AWS_PROFILE環境変数のチェック
    check_and_handle_aws_profile

    # ログファイルの初期化
    LOG_FILE="${HOME}/.aws/sso-profile-generator-$(date +%Y%m%d_%H%M%S).log"
    echo "# AWS SSO Profile Generator Log - $(get_current_datetime)" > "$LOG_FILE"
    log_info "Log file: $LOG_FILE"
    # ログファイルローテーション (最新 N 件保持、デフォルト 30)
    rotate_files_by_pattern "${HOME}/.aws/sso-profile-generator-*.log" "${LOG_KEEP_COUNT:-30}" "Log files"

    # 設定ファイルの取得
    local config_file
    config_file=$(get_config_file)

    log_info "Config file: $config_file"

    # SSO設定の取得
    if ! get_sso_config "$config_file"; then
        exit 1
    fi

    log_success "SSO config loaded"
    log_kv "Session"        "$SSO_SESSION_NAME"
    log_kv "Region"         "$SSO_REGION"
    log_kv "Start URL"      "$SSO_START_URL"
    echo

    # アクセストークンの取得
    if ! get_access_token "$SSO_START_URL"; then
        echo
        log_error "SSO session is invalid. Cannot proceed with profile generation."
        show_sso_login_command "$SSO_SESSION_NAME"
        echo
        log_info "After logging in, run this script again."
        exit 1
    fi

    echo

    # プロファイル自動生成の実行
    log_info "Starting profile generation..."

    # デフォルト設定
    local prefix="awssso"
    local region="$SSO_REGION"  # SSO設定から取得

    # ユーザー入力の取得
    echo
    if [ "$force_mode" = true ]; then
        log_info "Force mode: using prefix '$prefix'"
    else
        read -r -p "Profile name prefix (default: $prefix): " user_prefix
        prefix=${user_prefix:-$prefix}
    fi

    # 利用可能なアカウント数を事前に取得・表示
    echo
    local available_accounts_data
    local max_accounts
    log_info "Checking available accounts..."

    if available_accounts_data=$(get_accounts_data); then
        local available_count
        available_count=$(echo "$available_accounts_data" | wc -l | tr -d ' ')
        log_success "Available accounts: $available_count"

        # デフォルト値を利用可能な全アカウント数に設定
        max_accounts="$available_count"
    else
        log_warning "Failed to fetch account list."
        log_info "Possible causes:"
        echo "  - SSO session has expired"
        echo "  - AWS CLI configuration issue"
        echo "  - Network connectivity problem"
        log_info "Debug mode: DEBUG=1 ./generate-sso-profiles.sh"

        # フォールバック値として5を設定
        max_accounts=5
        log_info "Falling back to $max_accounts accounts"
    fi

    echo
    if [ "$force_mode" = true ]; then
        log_info "Force mode: processing all $max_accounts accounts"
    else
        read -r -p "Number of accounts to process (default: $max_accounts - all): " user_max_accounts
        max_accounts=${user_max_accounts:-$max_accounts}
    fi

    if [ "$force_mode" = true ]; then
        log_info "Force mode: default region '$region'"
    else
        read -r -p "Default region (default: $region): " user_region
        region=${user_region:-$region}
    fi

    local normalization_type="minimal"
    if [ "$force_mode" = true ]; then
        log_info "Force mode: normalization 'minimal'"
    else
        echo
        echo "Select account name normalization:"
        echo "  1. minimal - space -> underscore only (preserves case and hyphens)"
        echo "  2. full    - lowercase + hyphen -> underscore + space -> underscore"
        read -r -p "Normalization (1 or 2, default: 1): " normalization_choice

        if [ "${normalization_choice:-}" = "2" ]; then
            normalization_type="full"
        fi
    fi

    echo
    log_info "Settings:"
    log_kv "Prefix"        "$prefix"
    log_kv "Max accounts"  "$max_accounts"
    log_kv "Region"        "$region"
    log_kv "Normalization" "$normalization_type"
    echo

    # 正規化例を表示
    echo "Normalization examples:"
    echo "  Original: 'My Perfect-Web-Service Prod'"
    echo "  full:     '$(normalize_account_name_full "My Perfect-Web-Service Prod")'"
    echo "  minimal:  '$(normalize_account_name_minimal "My Perfect-Web-Service Prod")'"
    echo

    if [ "$force_mode" = true ]; then
        if [ "$dry_run" = true ]; then
            log_info "Force + DRY-RUN: config file will not be modified (preview only)"
        else
            log_info "Force mode: removing existing block and regenerating"
        fi
        generate_profiles_for_accounts "$config_file" "$prefix" "$max_accounts" "$region" "$normalization_type" "$dry_run"
        update_cache_metadata "$SSO_SESSION_NAME" "$SSO_START_URL" || true
        echo
        if [ "$dry_run" = true ]; then
            log_success "DRY-RUN complete (no files were modified)"
        else
            log_success "Profile generation complete!"
            log_info "To list generated profiles: aws configure list-profiles"
        fi
        log_info "Detail log: $LOG_FILE"
    else
        local prompt_msg
        if [ "$dry_run" = true ]; then
            prompt_msg="Run DRY-RUN with these settings? (y/n): "
        else
            prompt_msg="Generate profiles with these settings? (y/n): "
        fi
        read -r -p "$prompt_msg" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            generate_profiles_for_accounts "$config_file" "$prefix" "$max_accounts" "$region" "$normalization_type" "$dry_run"
            update_cache_metadata "$SSO_SESSION_NAME" "$SSO_START_URL" || true
            echo
            if [ "$dry_run" = true ]; then
                log_success "DRY-RUN complete (no files were modified)"
            else
                log_success "Profile generation complete!"
                log_info "To list generated profiles: aws configure list-profiles"
            fi
            log_info "Detail log: $LOG_FILE"
        else
            log_info "Profile generation cancelled"
        fi
    fi
}

# スクリプト実行
main "$@"
