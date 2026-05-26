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
            log_info "AWS CLI v2 インストール方法:"
            echo "  macOS:"
            echo "    curl \"https://awscli.amazonaws.com/AWSCLIV2.pkg\" -o \"AWSCLIV2.pkg\""
            echo "    sudo installer -pkg AWSCLIV2.pkg -target /"
            echo
            echo "  または Homebrew:"
            echo "    brew install awscli"
            ;;
        "jq")
            echo
            log_info "jq インストール方法:"
            echo "  macOS (Homebrew):"
            echo "    brew install jq"
            echo
            echo "  macOS (MacPorts):"
            echo "    sudo port install jq"
            echo
            echo "  直接ダウンロード:"
            echo "    https://github.com/jqlang/jq/releases"
            ;;
        "bash")
            echo
            log_info "Bash アップグレード方法:"
            echo "  macOS (Homebrew):"
            echo "    brew install bash"
            echo
            echo "  注意: macOS標準のbashは古いバージョンです"
            echo "  新しいbashを使用するには /etc/shells に追加が必要です"
            ;;
        "column")
            echo
            log_info "column インストール方法:"
            echo "  macOS: 通常は標準でインストールされています"
            echo "  Linux (util-linux パッケージに含まれる):"
            echo "    Ubuntu/Debian: sudo apt-get install util-linux"
            echo "    CentOS/RHEL: sudo yum install util-linux"
            ;;
    esac
}

# メインのツールチェック関数
check_tool() {
    local tool_name="$1"
    local display_name="$2"
    
    log_info "Step: ${display_name} の確認中..."
    
    if check_command_exists "$tool_name"; then
        log_success "${display_name} が見つかりました"
        
        local version
        if version=$(get_version "$tool_name") && [ -n "$version" ]; then
            log_success "バージョン: $version"
            
            # AWS CLI の場合、v2かどうかもチェック
            if [ "$tool_name" = "aws" ]; then
                if [[ $version == 2.* ]]; then
                    log_success "AWS CLI v2 が正しくインストールされています"
                else
                    log_warning "AWS CLI v1 が検出されました (v2 推奨)"
                    log_info "現在のバージョン: $version"
                fi
            fi
            
            # Bash の場合、バージョンをチェック
            if [ "$tool_name" = "bash" ]; then
                local major_version
                major_version=$(echo "$version" | cut -d'.' -f1)
                if [ "$major_version" -ge 4 ]; then
                    log_success "Bash v4以上が利用可能です"
                else
                    log_warning "Bash v3が検出されました (v4以上推奨)"
                    log_info "macOS標準のbashは古いバージョンです"
                fi
            fi
            
            # column の場合、特別な表示
            if [ "$tool_name" = "column" ]; then
                log_success "column コマンドが利用可能です（表示整形に使用）"
            fi
        else
            log_warning "バージョン情報の取得に失敗しました"
        fi
        
        return 0
    else
        log_error "${display_name} が見つかりません"
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
    echo "📋 ツールチェック結果サマリー"
    echo "=================================="
    
    if [ "$aws_status" -eq 0 ]; then
        log_success "AWS CLI: インストール済み"
    else
        log_error "AWS CLI: 未インストール"
    fi
    
    if [ "$jq_status" -eq 0 ]; then
        log_success "jq: インストール済み"
    else
        log_error "jq: 未インストール"
    fi
    
    if [ "$bash_status" -eq 0 ]; then
        log_success "Bash: 利用可能"
    else
        log_error "Bash: 問題あり"
    fi
    
    if [ "$column_status" -eq 0 ]; then
        log_success "column: 利用可能"
    else
        log_error "column: 未インストール"
    fi
    
    echo
    
    if [ "$aws_status" -eq 0 ] && [ "$jq_status" -eq 0 ] && [ "$bash_status" -eq 0 ] && [ "$column_status" -eq 0 ]; then
        log_success "すべてのツールが正常に利用可能です！"
        return 0
    else
        log_warning "一部のツールに問題があります"
        log_info "上記の情報を参考にしてください"
        return 1
    fi
}

# メイン実行部分
main() {
    echo "🔍 必要ツールの存在・バージョン確認"
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
    check_tool "column" "column (表示整形)"
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