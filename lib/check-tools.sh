#!/usr/bin/env bash

# ツール存在・バージョン確認スクリプト
# jq と aws コマンドの存在とバージョンをチェックします

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

# コマンド存在確認関数
check_command_exists() {
    local cmd="$1"
    if command -v "$cmd" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# バージョン取得関数
get_version() {
    local cmd="$1"
    
    case "$cmd" in
        "aws")
            aws --version 2>&1 | head -n1 | cut -d' ' -f1 | cut -d'/' -f2
            ;;
        "jq")
            jq --version 2>&1 | sed 's/jq-//'
            ;;
        "bash")
            bash --version 2>&1 | head -n1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1
            ;;
        "column")
            # columnコマンドはバージョン情報を提供しないことが多いので、存在確認のみ
            echo "available"
            ;;
        *)
            echo "Unknown command: $cmd"
            return 1
            ;;
    esac
}

# インストール方法表示関数
show_install_instructions() {
    local cmd="$1"
    
    case "$cmd" in
        "aws")
            echo
            log_info "AWS CLI v2 installation:"
            echo "  macOS:"
            echo "    curl \"https://awscli.amazonaws.com/AWSCLIV2.pkg\" -o \"AWSCLIV2.pkg\""
            echo "    sudo installer -pkg AWSCLIV2.pkg -target /"
            echo
            echo "  or Homebrew:"
            echo "    brew install awscli"
            ;;
        "jq")
            echo
            log_info "jq installation:"
            echo "  macOS (Homebrew):"
            echo "    brew install jq"
            echo
            echo "  macOS (MacPorts):"
            echo "    sudo port install jq"
            echo
            echo "  Direct download:"
            echo "    https://github.com/jqlang/jq/releases"
            ;;
        "bash")
            echo
            log_info "Bash upgrade:"
            echo "  macOS (Homebrew):"
            echo "    brew install bash"
            echo
            echo "  Note: macOS ships an old bash by default"
            echo "  Add the new bash to /etc/shells to use it as login shell"
            ;;
        "column")
            echo
            log_info "column installation:"
            echo "  macOS: typically pre-installed"
            echo "  Linux (part of util-linux):"
            echo "    Ubuntu/Debian: sudo apt-get install util-linux"
            echo "    CentOS/RHEL: sudo yum install util-linux"
            ;;
    esac
}

# メインのツールチェック関数
check_tool() {
    local tool_name="$1"
    local display_name="$2"
    
    log_info "Step: checking ${display_name}..."

    if check_command_exists "$tool_name"; then
        log_success "${display_name} found"

        local version
        if version=$(get_version "$tool_name") && [ -n "$version" ]; then
            log_success "Version: $version"

            # AWS CLI の場合、v2かどうかもチェック
            if [ "$tool_name" = "aws" ]; then
                if [[ $version == 2.* ]]; then
                    log_success "AWS CLI v2 is installed correctly"
                else
                    log_warning "AWS CLI v1 detected (v2 recommended)"
                    log_info "Current version: $version"
                fi
            fi

            # Bash の場合、バージョンをチェック
            if [ "$tool_name" = "bash" ]; then
                local major_version
                major_version=$(echo "$version" | cut -d'.' -f1)
                if [ "$major_version" -ge 4 ]; then
                    log_success "Bash v4 or newer is available"
                else
                    log_warning "Bash v3 detected (v4+ recommended)"
                    log_info "macOS ships an old bash by default"
                fi
            fi

            # column の場合、特別な表示
            if [ "$tool_name" = "column" ]; then
                log_success "column command is available (used for output formatting)"
            fi
        else
            log_warning "Failed to get version info"
        fi

        return 0
    else
        log_error "${display_name} not found"
        show_install_instructions "$tool_name"
        return 1
    fi
}

# 全体の結果表示関数
show_summary() {
    local aws_status="$1"
    local jq_status="$2"
    local bash_status="$3"
    local column_status="$4"
    
    echo
    echo "=================================="
    echo "📋 Tool check summary"
    echo "=================================="

    if [ "$aws_status" -eq 0 ]; then
        log_success "AWS CLI: installed"
    else
        log_error "AWS CLI: not installed"
    fi

    if [ "$jq_status" -eq 0 ]; then
        log_success "jq: installed"
    else
        log_error "jq: not installed"
    fi

    if [ "$bash_status" -eq 0 ]; then
        log_success "Bash: available"
    else
        log_error "Bash: has issues"
    fi

    if [ "$column_status" -eq 0 ]; then
        log_success "column: available"
    else
        log_error "column: not installed"
    fi

    echo

    if [ "$aws_status" -eq 0 ] && [ "$jq_status" -eq 0 ] && [ "$bash_status" -eq 0 ] && [ "$column_status" -eq 0 ]; then
        log_success "All required tools are available!"
        return 0
    else
        log_warning "Some tools have issues"
        log_info "Refer to the install instructions above"
        return 1
    fi
}

# メイン実行部分
main() {
    echo "🔍 Checking required tools (existence + version)"
    echo "=================================="
    echo

    # Bash チェック
    check_tool "bash" "Bash"
    bash_result=$?
    echo

    # AWS CLI チェック
    check_tool "aws" "AWS CLI"
    aws_result=$?
    echo

    # jq チェック
    check_tool "jq" "jq (JSON processor)"
    jq_result=$?
    echo

    # column チェック
    check_tool "column" "column (output formatting)"
    column_result=$?
    echo
    
    # サマリー表示
    show_summary $aws_result $jq_result $bash_result $column_result
    
    # 全体の終了コード
    if [ $aws_result -eq 0 ] && [ $jq_result -eq 0 ] && [ $bash_result -eq 0 ] && [ $column_result -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# スクリプト実行
main "$@"