#!/usr/bin/env bash

# AWS SSO 設定確認スクリプト

set -e

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
    
    log_info "利用可能なSSO Sessions:"
    
    local session_count=0
    local current_session=""
    local in_sso_section=false
    local sso_region=""
    local sso_start_url=""
    
    # 一時ファイルを使用してセッション情報を保存
    local temp_file=$(mktemp)
    
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
                    printf "     Region: %s\n", ($2 != "" ? $2 : "未設定")
                    printf "     Start URL: %s\n", ($3 != "" ? $3 : "未設定")
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
                        printf "     Region: %s\n", ($2 != "" ? $2 : "未設定")
                        printf "     Start URL: %s\n", ($3 != "" ? $3 : "未設定")
                        printf "\n"
                    }
                }
            }
            END {
                if (NR > 5) {
                    printf "  ... 他 %d 個のセッション（詳細は省略）\n", (NR - 5)
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

    log_info "AWS SSO設定の確認中..."
    log_info "設定ファイル: $config_file"
    echo

    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_error "AWS設定ファイルが見つかりません: $config_file"
        log_info "設定ファイルを作成してください"
        log_info "設定例:"
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
        log_error "SSO Session設定が見つかりません"
        log_info "設定例:"
        echo "  [sso-session session-name]"
        echo "  sso_region = ap-northeast-1"
        echo "  sso_start_url = https://your-domain.awsapps.com/start/"
        echo "  sso_registration_scopes = sso:account:access"
        return 1
    fi

    # 共通のSSO設定取得関数を使用（最初のセッションを使用）
    if get_sso_config "$config_file"; then
        if [ "$session_count" -gt 1 ]; then
            log_info "複数のSSO Sessionが設定されています（合計: $session_count 個）"
            log_info "デフォルトで使用するセッション: $SSO_SESSION_NAME"
        else
            log_success "SSO Session設定が見つかりました"
        fi
        
        echo "📋 使用中のセッション詳細:"
        echo "  Session名: $SSO_SESSION_NAME"
        echo "  SSO Region: $SSO_REGION"
        echo "  SSO Start URL: $SSO_START_URL"
        
        log_success "SSO設定は正常です"
        
        # SSO セッション状態もチェック
        echo
        check_sso_session_status "$SSO_START_URL" "$SSO_SESSION_NAME"
        
        return 0
    else

        log_error "SSO Session設定の読み込みに失敗しました"
        return 1
    fi
}

# 使用方法を表示
show_usage() {
    echo "使用方法: $0 [SESSION_NAME]"
    echo
    echo "引数:"
    echo "  SESSION_NAME          確認する特定のSSO Session名（省略時は全セッション表示）"
    echo
    echo "オプション:"
    echo "  -h, --help            このヘルプを表示"
    echo
    echo "例:"
    echo "  $0                    # 全てのセッションを表示し、最初のものを使用"
    echo "  $0 my-session         # 'my-session' セッションを確認"
    echo "  $0 --help             # ヘルプを表示"
}

# 特定のセッションをチェックする関数
check_specific_sso_session() {
    local session_name="$1"
    local config_file
    config_file=$(get_config_file)

    local message="AWS SSO設定の確認中（セッション: ${session_name}）..."
    log_info "$message"
    log_info "設定ファイル: $config_file"
    echo

    # 指定されたセッションの設定を取得
    if get_sso_config "$config_file" "$session_name"; then
        log_success "指定されたSSO Session設定が見つかりました"
        
        echo "📋 セッション詳細:"
        echo "  Session名: $SSO_SESSION_NAME"
        echo "  SSO Region: $SSO_REGION"
        echo "  SSO Start URL: $SSO_START_URL"
        
        log_success "SSO設定は正常です"
        
        # SSO セッション状態もチェック
        echo
        check_sso_session_status "$SSO_START_URL" "$SSO_SESSION_NAME"
        
        return 0
    else
        log_error "指定されたSSO Session '$session_name' が見つかりません"
        echo
        log_info "利用可能なセッション一覧:"
        show_all_sso_sessions "$config_file"
        return 1
    fi
}

# メイン実行
main() {
    # ヘルプオプションの処理
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    echo "🔍 AWS SSO 設定確認"
    echo "==================="
    echo
    
    local result
    if [ -n "$1" ]; then
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
        log_success "AWS SSO設定の確認が完了しました"
    else
        log_error "AWS SSO設定に問題があります"
    fi
    
    exit $result
}

# スクリプト実行
main "$@"