#!/usr/bin/env bash

# AWS SSO Profile Generator - 環境チェックスクリプト
# サブコマンドで各チェックを個別または一括実行できます

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

show_usage() {
    echo "使用方法: $0 [COMMAND] [OPTIONS]"
    echo
    echo "コマンド:"
    echo "  (なし)                        全ての環境チェックを実行"
    echo "  tools                         必要ツールの確認"
    echo "  aws-config                    AWS設定ファイルの確認"
    echo "  sso-config [SESSION_NAME]     SSO設定の確認"
    echo "  sso-profiles [SUBCOMMAND]     SSOプロファイルの分析"
    echo "  help, -h, --help              このヘルプを表示"
    echo
    echo "sso-profiles のサブコマンド:"
    echo "  analyze               全プロファイルの分析（デフォルト）"
    echo "  auto [--all]          自動生成プロファイルの詳細表示"
    echo "  manual [--all]        手動管理プロファイルの詳細表示"
    echo "  duplicates            重複プロファイルの詳細チェック"
    echo
    echo "例:"
    echo "  $0                          # 全ての環境チェック"
    echo "  $0 tools                    # ツール確認のみ"
    echo "  $0 aws-config               # AWS設定確認のみ"
    echo "  $0 sso-config               # SSO設定確認のみ"
    echo "  $0 sso-config my-session    # 特定セッションの確認"
    echo "  $0 sso-profiles             # プロファイル分析"
    echo "  $0 sso-profiles auto --all  # 自動生成プロファイルを全件表示"
}

run_all() {
    echo "🔍 AWS SSO Profile Generator 環境チェックを開始します"
    echo "================================================"
    echo

    echo "📋 Step 1: 必要ツールの確認"
    "$SCRIPT_DIR/lib/check-tools.sh"
    echo

    echo "📋 Step 2: AWS設定ファイルの確認"
    "$SCRIPT_DIR/lib/check-aws-config.sh"
    echo

    echo "📋 Step 3: SSO設定の確認"
    "$SCRIPT_DIR/lib/check-sso-config.sh"
    echo

    echo "✅ AWS SSO Profile Generator 環境チェックが完了しました！"
    echo
    echo "各チェックを個別に実行したい場合:"
    echo "  $0 tools          - 必要ツール確認"
    echo "  $0 aws-config     - AWS設定ファイル確認"
    echo "  $0 sso-config     - SSO設定確認"
    echo "  $0 sso-profiles   - プロファイル分析"
    echo "  ./generate-sso-profiles.sh - プロファイル自動生成（メイン機能）"
}

case "${1:-}" in
    "" )
        run_all
        ;;
    "tools")
        exec "$SCRIPT_DIR/lib/check-tools.sh"
        ;;
    "aws-config")
        exec "$SCRIPT_DIR/lib/check-aws-config.sh"
        ;;
    "sso-config")
        shift
        exec "$SCRIPT_DIR/lib/check-sso-config.sh" "$@"
        ;;
    "sso-profiles")
        shift
        exec "$SCRIPT_DIR/lib/check-sso-profiles.sh" "$@"
        ;;
    "help" | "-h" | "--help")
        show_usage
        exit 0
        ;;
    *)
        echo "❌ 不明なコマンド: $1"
        echo
        show_usage
        exit 1
        ;;
esac
