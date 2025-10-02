#!/usr/bin/env bash

# AWS SSO プロファイル自動生成スクリプト
# SSO Portal APIを使用してアカウントとロールを取得し、プロファイルを自動生成します

set -e

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"



# AWS CLI SSO: ListAccounts (ログメッセージなし版)
get_accounts_data() {
    local accounts_json
    if accounts_json=$(aws sso list-accounts --access-token "$ACCESS_TOKEN" --output json 2>/dev/null); then
        if echo "$accounts_json" | jq -e '.accountList' >/dev/null 2>&1; then
            echo "$accounts_json" | jq -r '.accountList[] | "\(.accountId) \(.accountName)"'
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
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
        log_info "aws sso login を実行してください"
        return 1
    fi
}

# AWS CLI SSO: ListAccountRoles (ログメッセージなし版)
get_account_roles_data() {
    local account_id="$1"
    
    if [ -z "$account_id" ]; then
        return 1
    fi
    
    local roles_json
    if roles_json=$(aws sso list-account-roles --access-token "$ACCESS_TOKEN" --account-id "$account_id" --output json 2>/dev/null); then
        if echo "$roles_json" | jq -e '.roleList' >/dev/null 2>&1; then
            echo "$roles_json" | jq -r '.roleList[] | "\(.roleName)"'
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
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

# アカウント名の正規化（フル正規化）
normalize_account_name_full() {
    local account_name="$1"
    # 小文字に変換し、スペースやハイフンをアンダースコアに置換
    echo "$account_name" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]-]/_/g' | sed 's/[^a-z0-9_]//g'
}

# アカウント名の正規化（最小限）
normalize_account_name_minimal() {
    local account_name="$1"
    # スペースのみをアンダースコアに変換、大文字小文字とハイフンはそのまま
    echo "$account_name" | sed 's/[[:space:]]/_/g' | sed 's/[^a-zA-Z0-9_-]//g'
}

# アカウント名の正規化（デフォルト）
normalize_account_name() {
    local account_name="$1"
    local normalization_type="${2:-minimal}"
    
    case "$normalization_type" in
        "minimal")
            normalize_account_name_minimal "$account_name"
            ;;
        "full"|*)
            normalize_account_name_full "$account_name"
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



# プロファイル設定の作成（コメントなし）
create_profile_config() {
    local config_file="$1"
    local profile_name="$2"
    local account_id="$3"
    local role_name="$4"
    local region="$5"
    
    # 設定内容を作成（コメントなし）
    local config_content
    config_content=$(cat << EOF

[profile $profile_name]
sso_session = $SSO_SESSION_NAME
sso_account_id = $account_id
sso_role_name = $role_name
region = $region
output = json
cli_pager = 
EOF
)
    
    # 設定ファイルに追加
    echo "$config_content" >> "$config_file"
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

# 複数アカウントのプロファイル自動生成
generate_profiles_for_accounts() {
    local config_file="$1"
    local prefix="$2"
    local max_accounts="$3"
    local region="$4"
    local normalization_type="$5"
    
    log_info "最大 $max_accounts 個のアカウントでプロファイルを生成します..."
    
    local accounts_data
    if ! accounts_data=$(get_accounts_data); then
        log_error "アカウント一覧の取得に失敗しました"
        return 1
    fi
    
    # 設定ファイルのバックアップ
    if [ -f "$config_file" ]; then
        local backup_file
        backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"
        log_info "設定ファイルをバックアップしました: $backup_file"
    fi
    
    # 一括処理開始コメントを追加
    add_batch_start_comment "$config_file"
    
    local count=0
    local total_profiles=0
    
    # 一時ファイルを使用してアカウントデータを処理
    local temp_accounts_file
    temp_accounts_file=$(mktemp)
    echo "$accounts_data" > "$temp_accounts_file"
    
    while IFS= read -r line && [ "$count" -lt "$max_accounts" ]; do
        local account_id
        local account_name
        
        account_id=$(echo "$line" | grep -o '^[0-9]\+')
        account_name=$(echo "$line" | sed 's/^[0-9][0-9]* //')
        
        if [ -n "$account_id" ] && [ -n "$account_name" ]; then
            log_info "アカウント処理中: $account_name ($account_id)"
            
            local roles_data
            if roles_data=$(get_account_roles_data "$account_id"); then
                local role_count=0
                
                # 一時ファイルを使用してロールデータを処理
                local temp_roles_file
                temp_roles_file=$(mktemp)
                echo "$roles_data" > "$temp_roles_file"
                
                while IFS= read -r role_name; do
                    if [ -n "$role_name" ]; then
                        local profile_name
                        profile_name=$(generate_profile_name "$prefix" "$account_name" "$account_id" "$role_name" "$normalization_type")
                        
                        create_profile_config "$config_file" "$profile_name" "$account_id" "$role_name" "$region"
                        
                        log_success "プロファイル作成: $profile_name"
                        role_count=$((role_count + 1))
                        total_profiles=$((total_profiles + 1))
                    fi
                done < "$temp_roles_file"
                
                rm -f "$temp_roles_file"
                log_info "アカウント $account_name: $role_count 個のプロファイルを作成"
            else
                log_warning "アカウント $account_name のロール取得に失敗しました"
            fi
            
            count=$((count + 1))
        fi
    done < "$temp_accounts_file"
    
    rm -f "$temp_accounts_file"
    
    # 一括処理終了コメントを追加
    add_batch_end_comment "$config_file"
    
    log_success "合計 $total_profiles 個のプロファイルを作成しました"
}

# メイン実行
main() {
    echo "🔄 AWS SSO プロファイル自動生成"
    echo "==============================="
    echo
    
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
        exit 1
    fi
    
    echo
    
    # プロファイル自動生成の実行
    echo
    log_info "プロファイル自動生成を開始します..."
    
    # デフォルト設定
    local prefix="autogen"
    local max_accounts=5
    local region="$SSO_REGION"  # SSO設定から取得
    
    # ユーザー入力の取得
    echo
    read -r -p "プロファイル名のプレフィックス (デフォルト: $prefix): " user_prefix
    prefix=${user_prefix:-$prefix}
    
    # 利用可能なアカウント数を事前に取得・表示
    echo
    local available_accounts_data
    if available_accounts_data=$(run_with_spinner "利用可能なアカウント数を確認中" "get_accounts_data"); then
        local available_count
        available_count=$(echo "$available_accounts_data" | wc -l | tr -d ' ')
        log_success "利用可能なアカウント数: $available_count 個"
        
        # デフォルト値を利用可能数に調整
        if [ "$max_accounts" -gt "$available_count" ]; then
            max_accounts="$available_count"
        fi
    else
        log_warning "アカウント数の取得に失敗しました。デフォルト値を使用します。"
    fi
    
    echo
    read -r -p "処理するアカウント数 (デフォルト: $max_accounts): " user_max_accounts
    max_accounts=${user_max_accounts:-$max_accounts}
    
    read -r -p "デフォルトリージョン (デフォルト: $region): " user_region
    region=${user_region:-$region}
    
    echo
    echo "アカウント名の正規化方式を選択してください:"
    echo "  1. minimal - スペース→アンダースコアのみ（大文字・ハイフンはそのまま）"
    echo "  2. full    - 小文字変換 + ハイフン→アンダースコア + スペース→アンダースコア"
    read -r -p "正規化方式 (1 または 2, デフォルト: 1): " normalization_choice
    
    local normalization_type="minimal"
    if [ "$normalization_choice" = "2" ]; then
        normalization_type="full"
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
    
    read -r -p "この設定でプロファイルを生成しますか？ (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        generate_profiles_for_accounts "$config_file" "$prefix" "$max_accounts" "$region" "$normalization_type"
        echo
        log_success "プロファイル自動生成が完了しました！"
        log_info "生成されたプロファイルを確認するには: aws configure list-profiles"
    else
        log_info "プロファイル生成をキャンセルしました"
    fi
}

# グローバル変数の初期化
SSO_SESSION_NAME=""
SSO_REGION=""
SSO_START_URL=""
ACCESS_TOKEN=""

# スクリプト実行
main "$@"