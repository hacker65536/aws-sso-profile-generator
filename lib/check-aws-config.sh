#!/usr/bin/env bash

# AWS 設定ファイル確認スクリプト

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

# リージョン設定の詳細確認
check_region_config() {
    log_info "Checking region configuration details..."
    log_info "AWS SSO commands (aws sso list-accounts etc.) require a region"
    echo

    # 1. 環境変数の確認
    echo "🌍 Region from environment variables:"
    local aws_region="${AWS_REGION:-unset}"
    local aws_default_region="${AWS_DEFAULT_REGION:-unset}"

    log_kv "AWS_REGION"          "$aws_region"
    log_kv "AWS_DEFAULT_REGION"  "$aws_default_region"

    # 2. AWS CLI設定の確認
    echo
    echo "⚙️ Region from AWS CLI configuration:"
    if command -v aws &> /dev/null; then
        local cli_region
        cli_region=$(unset AWS_PROFILE; aws configure get region 2>/dev/null || echo "unset")
        log_kv "aws configure get region" "$cli_region"

        # 3. aws configure list での確認
        echo
        echo "📋 AWS CLI configuration list:"
        local config_output
        if config_output=$(unset AWS_PROFILE; aws configure list 2>/dev/null); then
            echo "$config_output" | while IFS= read -r line; do
                echo "  $line"
            done
        else
            echo "  Failed to fetch configuration"
        fi

        # 4. 設定の一貫性チェック
        echo
        echo "🔍 Configuration consistency check:"

        # 有効なリージョン値を収集
        local regions=()
        [ "$aws_region" != "unset" ] && regions+=("$aws_region")
        [ "$aws_default_region" != "unset" ] && regions+=("$aws_default_region")
        [ "$cli_region" != "unset" ] && regions+=("$cli_region")

        if [ ${#regions[@]} -eq 0 ]; then
            log_error "No region is configured"
            echo
            log_warning "AWS SSO commands require a region setting"
            log_info "Set the region using one of the following:"
            echo "  Env var:  export AWS_REGION=ap-northeast-1"
            echo "  AWS CLI:  aws configure set region ap-northeast-1"
        elif [ ${#regions[@]} -eq 1 ]; then
            log_success "Region setting is consistent: ${regions[0]}"
            log_success "AWS SSO commands should work"
        else
            # 重複を除去して一意な値を確認
            local unique_regions
            mapfile -t unique_regions < <(printf '%s\n' "${regions[@]}" | sort -u)

            if [ ${#unique_regions[@]} -eq 1 ]; then
                log_success "Region is consistent across sources: ${unique_regions[0]}"
                log_success "AWS SSO commands should work"
            else
                log_warning "Region setting is inconsistent"
                log_warning "AWS SSO commands may behave unexpectedly"
                echo "  Configured regions:"
                for region in "${unique_regions[@]}"; do
                    echo "    - $region"
                done
                echo
                log_info "Recommended: unify on a single region"
                echo "  Priority: env vars > AWS CLI settings"
                echo "  Unifying the region keeps SSO commands stable"
            fi
        fi

        # 5. 実際に使用されるリージョンの表示
        echo
        echo "✅ Region used by AWS SSO commands:"
        local effective_region
        if [ -n "${AWS_REGION:-}" ]; then
            effective_region="$AWS_REGION (env var AWS_REGION)"
            log_success "Region is set via environment variable"
        elif [ -n "${AWS_DEFAULT_REGION:-}" ]; then
            effective_region="$AWS_DEFAULT_REGION (env var AWS_DEFAULT_REGION)"
            log_success "Region is set via environment variable"
        elif [ "$cli_region" != "unset" ]; then
            effective_region="$cli_region (AWS CLI settings)"
            log_success "Region is set via AWS CLI configuration"
        else
            effective_region="unset (AWS CLI default: us-east-1)"
            log_warning "No explicit region setting found"
            log_info "AWS SSO commands may fail"
        fi
        echo "  $effective_region"

    else
        log_error "AWS CLI not found"
        log_info "Please install the AWS CLI"
    fi
}

# AWS CLI 設定確認
check_aws_cli_config() {
    log_info "Checking AWS CLI base configuration..."

    # aws configure list の実行
    if command -v aws &> /dev/null; then
        local config_output
        if config_output=$(unset AWS_PROFILE; aws configure list 2>/dev/null); then
            log_success "Fetched AWS CLI configuration"
            echo
            echo "📋 AWS CLI configuration summary:"
            echo "$config_output" | while IFS= read -r line; do
                echo "  $line"
            done
        else
            log_warning "Failed to fetch AWS CLI configuration"
            log_info "AWS CLI may not be configured correctly"
        fi
    else
        log_error "AWS CLI not found"
        log_info "Please install the AWS CLI"
    fi
}

# プロファイル情報の解析
parse_profile_info() {
    local config_file="$1"
    
    # 通常のプロファイル情報を取得（カウント用）
    
    # 詳細なプロファイルサマリーを表示
    show_detailed_profile_summary "$config_file"
}

# メイン実行
main() {
    echo "🔍 AWS Config File Check"
    echo "========================"
    echo

    # Step 1: 環境変数 AWS_CONFIG_FILE の確認
    log_info "Checking AWS_CONFIG_FILE environment variable..."

    local config_file
    if [ -n "${AWS_CONFIG_FILE:-}" ]; then
        log_success "AWS_CONFIG_FILE is set: $AWS_CONFIG_FILE"
        config_file="$AWS_CONFIG_FILE"
    else
        log_info "AWS_CONFIG_FILE environment variable is not set"
        log_info "Using default config file: $HOME/.aws/config"
        config_file="$HOME/.aws/config"
    fi

    echo

    # Step 2: 設定ファイルの存在確認
    log_info "Checking existence of AWS config file..."
    log_info "Target: $config_file"

    if [ -f "$config_file" ]; then
        log_success "AWS config file found"
        echo

        # 簡易表示
        parse_profile_info "$config_file"

    else
        log_error "AWS config file not found"
        echo
        log_info "You need to create a config file"
        log_info "Creating directory: $(dirname "$config_file")"

        # .aws ディレクトリの作成
        mkdir -p "$(dirname "$config_file")"
        log_success "Directory created"
    fi

    echo

    # Step 3: AWS CLI 基本設定の確認
    check_aws_cli_config

    echo

    # Step 4: リージョン設定の詳細確認
    check_region_config

    echo
    log_info "Next step: run ./lib/check-sso-config.sh to verify SSO configuration"
    log_info "Note: AWS SSO commands require a region setting"
}

# スクリプト実行
main "$@"