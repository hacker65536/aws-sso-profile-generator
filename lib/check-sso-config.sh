#!/usr/bin/env bash

# AWS SSO 設定確認スクリプト

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"



# 全てのSSO Sessionを表示する関数
show_all_sso_sessions() {
    local config_file="$1"
    
    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        echo "0" >&2
        return 0
    fi
    
    log_info "Available SSO Sessions:"
    
    local session_count=0
    local current_session=""
    local in_sso_section=false
    local sso_region=""
    local sso_start_url=""
    
    # 一時ファイルを使用してセッション情報を保存
    local temp_file
    temp_file=$(mktemp)
    
    while IFS= read -r line; do
        if [[ $line =~ ^\[sso-session[[:space:]]*([^]]+)\] ]]; then
            # 前のセッション情報を保存
            if [ -n "$current_session" ]; then
                echo "$current_session|$sso_region|$sso_start_url" >> "$temp_file"
            fi
            
            # 新しいセッション開始
            current_session="${BASH_REMATCH[1]}"
            in_sso_section=true
            sso_region=""
            sso_start_url=""
            continue
        elif [[ $line =~ ^\[ ]] && [[ $in_sso_section == true ]]; then
            # 別のセクションに入った
            in_sso_section=false
        elif [[ $in_sso_section == true ]]; then
            if [[ $line =~ ^sso_region[[:space:]]*=[[:space:]]*(.*) ]]; then
                sso_region="${BASH_REMATCH[1]}"
            elif [[ $line =~ ^sso_start_url[[:space:]]*=[[:space:]]*(.*) ]]; then
                sso_start_url="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$config_file"
    
    # 最後のセッション情報を保存
    if [ -n "$current_session" ]; then
        echo "$current_session|$sso_region|$sso_start_url" >> "$temp_file"
    fi
    

    
    # セッション情報を表示
    if [ -s "$temp_file" ]; then
        session_count=$(wc -l < "$temp_file" | tr -d ' ')
        
        # 最初の5個まで詳細表示、それ以降は省略
        if [ $session_count -le 5 ]; then
            # 5個以下の場合は全て表示
            awk -F'|' '
            {
                if (NF >= 3 && $1 != "") {
                    printf "  %d. %s\n", NR, $1
                    printf "     Region: %s\n", ($2 != "" ? $2 : "unset")
                    printf "     Start URL: %s\n", ($3 != "" ? $3 : "unset")
                    printf "\n"
                }
            }
            ' "$temp_file"
        else
            # 5個を超える場合は最初の5個のみ詳細表示
            awk -F'|' '
            {
                if (NF >= 3 && $1 != "") {
                    if (NR <= 5) {
                        printf "  %d. %s\n", NR, $1
                        printf "     Region: %s\n", ($2 != "" ? $2 : "unset")
                        printf "     Start URL: %s\n", ($3 != "" ? $3 : "unset")
                        printf "\n"
                    }
                }
            }
            END {
                if (NR > 5) {
                    printf "  ... and %d more sessions (details omitted)\n", (NR - 5)
                    printf "\n"
                }
            }
            ' "$temp_file"
        fi
    fi
    
    # 一時ファイルを削除
    rm -f "$temp_file"
    
    # セッション数を標準エラー出力に出力し、成功として0を返す
    echo "${session_count:-0}" >&2
    return 0
}

# SSO設定チェック関数
check_sso_config() {
    # 設定ファイルのパスを決定
    local config_file
    config_file=$(get_config_file)

    log_info "Checking AWS SSO configuration..."
    log_info "Config file: $config_file"
    echo

    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_error "AWS config file not found: $config_file"
        log_info "Please create a config file"
        log_info "Example:"
        echo "  [sso-session session-name]"
        echo "  sso_region = ap-northeast-1"
        echo "  sso_start_url = https://your-domain.awsapps.com/start/"
        echo "  sso_registration_scopes = sso:account:access"
        return 1
    fi

    # まず全てのSSO Sessionを表示
    local session_count
    session_count=$(show_all_sso_sessions "$config_file" 2>&1 >/dev/tty)
    
    # session_countが空の場合は0に設定
    session_count=${session_count:-0}

    if [ "$session_count" -eq 0 ]; then
        log_error "No SSO Session configuration found"
        log_info "Example:"
        echo "  [sso-session session-name]"
        echo "  sso_region = ap-northeast-1"
        echo "  sso_start_url = https://your-domain.awsapps.com/start/"
        echo "  sso_registration_scopes = sso:account:access"
        return 1
    fi

    # 共通のSSO設定取得関数を使用（最初のセッションを使用）
    if get_sso_config "$config_file"; then
        if [ "$session_count" -gt 1 ]; then
            log_info "Multiple SSO sessions configured (total: $session_count)"
            log_info "Default session to use: $SSO_SESSION_NAME"
        else
            log_success "SSO Session configuration found"
        fi

        echo "📋 Active session details:"
        log_kv "Session"        "$SSO_SESSION_NAME"
        log_kv "SSO Region"     "$SSO_REGION"
        log_kv "SSO Start URL"  "$SSO_START_URL"

        log_success "SSO configuration is OK"
        
        # SSO セッション状態もチェック
        echo
        check_sso_session_status "$SSO_START_URL" "$SSO_SESSION_NAME"
        
        return 0
    else

        log_error "Failed to load SSO Session configuration"
        return 1
    fi
}

# 使用方法を表示
show_usage() {
    echo "Usage: $0 [SESSION_NAME]"
    echo
    echo "Arguments:"
    echo "  SESSION_NAME          Specific SSO session name to check (default: show all)"
    echo
    echo "Options:"
    echo "  -h, --help            Show this help"
    echo
    echo "Examples:"
    echo "  $0                    # Show all sessions and use the first"
    echo "  $0 my-session         # Check the 'my-session' session"
    echo "  $0 --help             # Show help"
}

# 特定のセッションをチェックする関数
check_specific_sso_session() {
    local session_name="$1"
    local config_file
    config_file=$(get_config_file)

    local message="Checking AWS SSO configuration (session: ${session_name})..."
    log_info "$message"
    log_info "Config file: $config_file"
    echo

    # 指定されたセッションの設定を取得
    if get_sso_config "$config_file" "$session_name"; then
        log_success "Specified SSO Session configuration found"

        echo "📋 Session details:"
        log_kv "Session"        "$SSO_SESSION_NAME"
        log_kv "SSO Region"     "$SSO_REGION"
        log_kv "SSO Start URL"  "$SSO_START_URL"

        log_success "SSO configuration is OK"

        # SSO セッション状態もチェック
        echo
        check_sso_session_status "$SSO_START_URL" "$SSO_SESSION_NAME"

        return 0
    else
        log_error "Specified SSO Session '$session_name' not found"
        echo
        log_info "Available sessions:"
        show_all_sso_sessions "$config_file"
        return 1
    fi
}

# メイン実行
main() {
    # ヘルプオプションの処理
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        show_usage
        exit 0
    fi

    echo "🔍 AWS SSO Configuration Check"
    echo "==================="
    echo

    local result
    if [ -n "${1:-}" ]; then
        # 特定のセッションを確認
        check_specific_sso_session "$1"
        result=$?
    else
        # 全てのセッションを表示して最初のものを使用
        check_sso_config
        result=$?
    fi
    
    echo
    if [ $result -eq 0 ]; then
        log_success "AWS SSO configuration check complete"
    else
        log_error "AWS SSO configuration has issues"
    fi
    
    exit $result
}

# スクリプト実行
main "$@"