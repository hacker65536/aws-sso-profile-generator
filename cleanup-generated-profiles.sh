#!/usr/bin/env bash

# AWS SSO 自動生成プロファイル削除スクリプト
# AWS_SSO_CONFIG_GENERATOR で生成されたプロファイルを削除します

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/lib/common.sh"

# 削除予定プロファイルの表示
show_profiles_to_delete() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    log_info "Profiles to delete:"

    # AWS_SSO_CONFIG_GENERATOR で囲まれたブロック内のプロファイルを抽出
    local in_generator_block=false
    local profile_count=0

    while IFS= read -r line; do
        if [[ $line =~ ^#[[:space:]]*AWS_SSO_CONFIG_GENERATOR[[:space:]]+START ]]; then
            in_generator_block=true
            continue
        elif [[ $line =~ ^#[[:space:]]*AWS_SSO_CONFIG_GENERATOR[[:space:]]+END ]]; then
            in_generator_block=false
            continue
        elif [[ $in_generator_block == true ]] && [[ $line =~ ^\[profile[[:space:]]+(.+)\] ]]; then
            local profile_name="${BASH_REMATCH[1]}"
            echo "  - $profile_name"
            profile_count=$((profile_count + 1))
        fi
    done < "$config_file"

    if [ $profile_count -eq 0 ]; then
        echo "  (no profiles match for deletion)"
    else
        echo
        log_info "Profiles to delete: $profile_count"
    fi
}

# 自動生成プロファイルの確認
check_generated_profiles() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_error "AWS config file not found: $config_file"
        return 1
    fi

    # AWS_SSO_CONFIG_GENERATOR コメントの検索
    local generator_blocks
    generator_blocks=$(grep -n "AWS_SSO_CONFIG_GENERATOR" "$config_file" 2>/dev/null || true)

    if [ -z "$generator_blocks" ]; then
        log_info "No auto-generated profiles found"
        return 1
    fi

    log_info "Auto-generated profile blocks detected:"
    echo "$generator_blocks"
    echo

    return 0
}

# 自動生成プロファイルの削除
# 引数: $1=config_file, $2=session_filter (省略可。指定時は特定セッションのみ削除)
remove_generated_profiles() {
    local config_file="$1"
    local session_filter="${2:-}"

    # マーカー整合性チェック（不一致なら sed による事故的全削除を防ぐ）
    if ! verify_marker_integrity "$config_file"; then
        return 1
    fi

    log_info "Backing up config file..."
    local backup_file
    backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$config_file" "$backup_file"
    log_success "Backup created: $backup_file"

    rotate_backups "$config_file" 10

    if [ -n "$session_filter" ]; then
        log_info "Deleting profiles for session '$session_filter' only..."
        # awk で AWS_SSO_CONFIG_GENERATOR ブロック内の特定セッションプロファイルのみ除外
        awk -v session="$session_filter" '
            BEGIN { in_block = 0; in_profile = 0; buf = ""; sess = "" }
            /^# AWS_SSO_CONFIG_GENERATOR START/ { in_block = 1; print; next }
            /^# AWS_SSO_CONFIG_GENERATOR END/ {
                if (in_profile) {
                    if (sess != session) printf "%s", buf
                }
                in_block = 0; in_profile = 0; buf = ""; sess = ""
                print; next
            }
            in_block && /^\[profile / {
                # 前のプロファイルを flush
                if (in_profile && sess != session) printf "%s", buf
                buf = $0 "\n"
                sess = ""
                in_profile = 1
                next
            }
            in_block && in_profile {
                buf = buf $0 "\n"
                if ($0 ~ /^sso_session[[:space:]]*=/) {
                    s = $0
                    sub(/^sso_session[[:space:]]*=[[:space:]]*/, "", s)
                    sub(/[[:space:]]+$/, "", s)
                    sess = s
                }
                next
            }
            { print }
        ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    else
        log_info "Deleting auto-generated profiles..."
        # AWS_SSO_CONFIG_GENERATOR で囲まれたブロックを丸ごと削除
        sed -i.tmp '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/d' "$config_file"
        rm -f "${config_file}.tmp"
    fi

    # 末尾空行を整理 (空行累積を防ぐ)
    trim_trailing_empty_lines "$config_file"

    log_success "Auto-generated profiles deleted"
}

# 削除結果の確認
verify_cleanup() {
    local config_file="$1"
    
    log_info "Verifying cleanup..."

    local remaining_blocks
    remaining_blocks=$(grep -n "AWS_SSO_CONFIG_GENERATOR" "$config_file" 2>/dev/null || true)

    if [ -z "$remaining_blocks" ]; then
        log_success "All auto-generated profiles removed successfully"
        return 0
    else
        log_warning "Some auto-generated profiles may remain:"
        echo "$remaining_blocks"
        return 1
    fi
}



# メイン実行
main() {
    local dry_run=false
    local session_filter=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                dry_run=true
                shift
                ;;
            --session)
                if [ $# -lt 2 ]; then
                    log_error "--session requires a session name"
                    exit 1
                fi
                session_filter="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--dry-run] [--session NAME] [--help]"
                echo "  --dry-run         Show profiles that would be deleted without modifying the file"
                echo "  --session NAME    Delete only profiles belonging to the given SSO session"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [ "$dry_run" = true ]; then
        echo "🗑️ AWS SSO Auto-generated Profile Cleanup (DRY-RUN)"
    else
        echo "🗑️ AWS SSO Auto-generated Profile Cleanup"
    fi
    echo "====================================="
    echo

    # 設定ファイルの取得
    local config_file
    config_file=$(get_config_file)

    log_info "Config file: $config_file"
    echo

    # 削除前の統計を取得
    local before_stats
    before_stats=$(get_profile_stats_data "$config_file")

    # 削除前の統計表示
    log_info "Before cleanup:"
    echo
    show_profile_stats "$config_file"
    echo

    # 自動生成プロファイルの確認
    if ! check_generated_profiles "$config_file"; then
        log_info "No profiles to delete"
        exit 0
    fi

    # 削除予定プロファイルの表示
    echo
    show_profiles_to_delete "$config_file"

    if [ "$dry_run" = true ]; then
        echo
        log_success "DRY-RUN complete (no actual deletion performed)"
        exit 0
    fi

    # 削除確認
    echo
    log_warning "All auto-generated profiles (AWS_SSO_CONFIG_GENERATOR) will be removed"
    read -r -p "Continue? (y/n): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi

    echo

    # プロファイル削除の実行
    remove_generated_profiles "$config_file" "$session_filter"

    echo

    # 削除結果の確認
    verify_cleanup "$config_file"

    # 削除後の統計を取得
    local after_stats
    after_stats=$(get_profile_stats_data "$config_file")

    # 削除後の統計表示
    echo
    log_info "After cleanup:"
    echo
    show_profile_stats "$config_file"

    # diff形式での変更表示
    echo
    log_info "Changes (diff):"
    show_profile_diff "$before_stats" "$after_stats"

    echo
    log_success "Auto-generated profile cleanup completed!"
}

# スクリプト実行
main "$@"