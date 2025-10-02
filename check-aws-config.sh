#!/usr/bin/env bash

# AWS 設定ファイル確認スクリプト

set -e

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

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
    log_info "次のステップ: ./check-awssso-config.sh を実行してSSO設定を確認してください"
}

# スクリプト実行
main "$@"