#!/usr/bin/env bash

# AWS 設定ファイル確認スクリプト

set -e

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

# リージョン設定の詳細確認
check_region_config() {
    log_info "リージョン設定の詳細確認中..."
    log_info "AWS SSO コマンド（aws sso list-accounts等）にはリージョン設定が必須です"
    echo
    
    # 1. 環境変数の確認
    echo "🌍 環境変数によるリージョン設定:"
    local aws_region="${AWS_REGION:-未設定}"
    local aws_default_region="${AWS_DEFAULT_REGION:-未設定}"
    
    echo "  AWS_REGION: $aws_region"
    echo "  AWS_DEFAULT_REGION: $aws_default_region"
    
    # 2. AWS CLI設定の確認
    echo
    echo "⚙️  AWS CLI設定によるリージョン:"
    if command -v aws &> /dev/null; then
        local cli_region
        cli_region=$(aws configure get region 2>/dev/null || echo "未設定")
        echo "  aws configure get region: $cli_region"
        
        # 3. aws configure list での確認
        echo
        echo "📋 AWS CLI 設定一覧:"
        local config_output
        if config_output=$(aws configure list 2>/dev/null); then
            echo "$config_output" | while IFS= read -r line; do
                echo "  $line"
            done
        else
            echo "  設定情報の取得に失敗しました"
        fi
        
        # 4. 設定の一貫性チェック
        echo
        echo "🔍 設定の一貫性チェック:"
        
        # 有効なリージョン値を収集
        local regions=()
        [ "$aws_region" != "未設定" ] && regions+=("$aws_region")
        [ "$aws_default_region" != "未設定" ] && regions+=("$aws_default_region")
        [ "$cli_region" != "未設定" ] && regions+=("$cli_region")
        
        if [ ${#regions[@]} -eq 0 ]; then
            log_error "リージョンが設定されていません"
            echo
            log_warning "AWS SSO コマンドの実行にはリージョン設定が必須です"
            log_info "以下のいずれかの方法でリージョンを設定してください:"
            echo "  環境変数: export AWS_REGION=ap-northeast-1"
            echo "  AWS CLI:  aws configure set region ap-northeast-1"
        elif [ ${#regions[@]} -eq 1 ]; then
            log_success "リージョン設定が一貫しています: ${regions[0]}"
            log_success "AWS SSO コマンドが正常に実行できます"
        else
            # 重複を除去して一意な値を確認
            local unique_regions=($(printf '%s\n' "${regions[@]}" | sort -u))
            
            if [ ${#unique_regions[@]} -eq 1 ]; then
                log_success "複数の設定方法でリージョンが一貫しています: ${unique_regions[0]}"
                log_success "AWS SSO コマンドが正常に実行できます"
            else
                log_warning "リージョン設定に不整合があります"
                log_warning "AWS SSO コマンドで予期しない動作が発生する可能性があります"
                echo "  設定されているリージョン:"
                for region in "${unique_regions[@]}"; do
                    echo "    - $region"
                done
                echo
                log_info "推奨: 一つのリージョンに統一してください"
                echo "  優先順位: 環境変数 > AWS CLI設定"
                echo "  AWS SSO コマンドの安定動作のため設定統一が重要です"
            fi
        fi
        
        # 5. 実際に使用されるリージョンの表示
        echo
        echo "✅ AWS SSO コマンドで使用されるリージョン:"
        local effective_region
        if [ -n "$AWS_REGION" ]; then
            effective_region="$AWS_REGION (環境変数 AWS_REGION)"
            log_success "環境変数によりリージョンが設定されています"
        elif [ -n "$AWS_DEFAULT_REGION" ]; then
            effective_region="$AWS_DEFAULT_REGION (環境変数 AWS_DEFAULT_REGION)"
            log_success "環境変数によりリージョンが設定されています"
        elif [ "$cli_region" != "未設定" ]; then
            effective_region="$cli_region (AWS CLI設定)"
            log_success "AWS CLI設定によりリージョンが設定されています"
        else
            effective_region="未設定 (AWS CLI デフォルト: us-east-1)"
            log_warning "明示的なリージョン設定がありません"
            log_info "AWS SSO コマンドでエラーが発生する可能性があります"
        fi
        echo "  $effective_region"
        
    else
        log_error "AWS CLI が見つかりません"
        log_info "AWS CLI をインストールしてください"
    fi
}

# AWS CLI 設定確認
check_aws_cli_config() {
    log_info "AWS CLI 基本設定の確認中..."
    
    # aws configure list の実行
    if command -v aws &> /dev/null; then
        local config_output
        if config_output=$(aws configure list 2>/dev/null); then
            log_success "AWS CLI 設定情報を取得しました"
            echo
            echo "📋 AWS CLI 設定概要:"
            echo "$config_output" | while IFS= read -r line; do
                echo "  $line"
            done
        else
            log_warning "AWS CLI 設定の取得に失敗しました"
            log_info "AWS CLI が正しく設定されていない可能性があります"
        fi
    else
        log_error "AWS CLI が見つかりません"
        log_info "AWS CLI をインストールしてください"
    fi
}

# プロファイル情報の解析
parse_profile_info() {
    local config_file="$1"
    
    # SSO セッション情報を取得
    local sso_sessions
    sso_sessions=$(grep -n "^\[sso-session " "$config_file" 2>/dev/null | head -5 || true)
    
    # 通常のプロファイル情報を取得（カウント用）
    
    # 詳細なプロファイルサマリーを表示
    show_detailed_profile_summary "$config_file"
}

# メイン実行
main() {
    echo "🔍 AWS 設定ファイルの確認"
    echo "========================"
    echo
    
    # Step 1: 環境変数 AWS_CONFIG_FILE の確認
    log_info "AWS_CONFIG_FILE 環境変数の確認中..."
    
    local config_file
    if [ -n "$AWS_CONFIG_FILE" ]; then
        log_success "AWS_CONFIG_FILE が設定されています: $AWS_CONFIG_FILE"
        config_file="$AWS_CONFIG_FILE"
    else
        log_info "AWS_CONFIG_FILE 環境変数は設定されていません"
        log_info "デフォルトの設定ファイルを使用します: $HOME/.aws/config"
        config_file="$HOME/.aws/config"
    fi
    
    echo
    
    # Step 2: 設定ファイルの存在確認
    log_info "AWS設定ファイルの存在確認中..."
    log_info "確認対象: $config_file"
    
    if [ -f "$config_file" ]; then
        log_success "AWS設定ファイルが見つかりました"
        echo
        
        # 簡易表示
        parse_profile_info "$config_file"
        
    else
        log_error "AWS設定ファイルが見つかりません"
        echo
        log_info "設定ファイルを作成する必要があります"
        log_info "ディレクトリを作成します: $(dirname "$config_file")"
        
        # .aws ディレクトリの作成
        mkdir -p "$(dirname "$config_file")"
        log_success "ディレクトリを作成しました"
    fi
    
    echo
    
    # Step 3: AWS CLI 基本設定の確認
    check_aws_cli_config
    
    echo
    
    # Step 4: リージョン設定の詳細確認
    check_region_config
    
    echo
    log_info "次のステップ: ./check-awssso-config.sh を実行してSSO設定を確認してください"
    log_info "注意: AWS SSO コマンドにはリージョン設定が必須です"
}

# スクリプト実行
main "$@"