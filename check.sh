#!/usr/bin/env bash

# AWS SSO Profile Generator - 環境チェックスクリプト
# サブコマンドで各チェックを個別または一括実行できます

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo
    echo "Commands:"
    echo "  (none)                        Run all environment checks"
    echo "  tools                         Verify required tools"
    echo "  aws-config                    Check AWS config file"
    echo "  sso-config [SESSION_NAME]     Check SSO configuration"
    echo "  sso-profiles [SUBCOMMAND]     Analyze SSO profiles"
    echo "  cache [SUBCOMMAND]            Show / clear / validate cache"
    echo "  help, -h, --help              Show this help"
    echo
    echo "sso-profiles subcommands:"
    echo "  analyze               Analyze all profiles (default)"
    echo "  auto [--all]          Show auto-generated profile details"
    echo "  manual [--all]        Show manual profile details"
    echo "  duplicates            Inspect duplicate profiles"
    echo
    echo "cache subcommands:"
    echo "  stats                 Show cache statistics (default)"
    echo "  clear [SESSION]       Clear all cache or per-session cache"
    echo "  validate              List expired files"
    echo
    echo "Examples:"
    echo "  $0                          # Run all environment checks"
    echo "  $0 tools                    # Tools only"
    echo "  $0 aws-config               # AWS config only"
    echo "  $0 sso-config               # SSO config only"
    echo "  $0 sso-config my-session    # Check a specific session"
    echo "  $0 sso-profiles             # Profile analysis"
    echo "  $0 sso-profiles auto --all  # Show all auto-generated profiles"
    echo "  $0 cache                    # Cache statistics"
    echo "  $0 cache clear              # Clear all cache"
}

run_all() {
    echo "🔍 AWS SSO Profile Generator environment check"
    echo "================================================"
    echo

    echo "📋 Step 1: Verify required tools"
    "$SCRIPT_DIR/lib/check-tools.sh"
    echo

    echo "📋 Step 2: AWS config file"
    "$SCRIPT_DIR/lib/check-aws-config.sh"
    echo

    echo "📋 Step 3: SSO configuration"
    "$SCRIPT_DIR/lib/check-sso-config.sh"
    echo

    echo "✅ AWS SSO Profile Generator environment check complete!"
    echo
    echo "To run each check individually:"
    echo "  $0 tools          - Verify required tools"
    echo "  $0 aws-config     - Check AWS config file"
    echo "  $0 sso-config     - Check SSO configuration"
    echo "  $0 sso-profiles   - Profile analysis"
    echo "  ./generate-sso-profiles.sh - Generate profiles (main feature)"
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
    "cache")
        shift
        exec bash "$SCRIPT_DIR/lib/check-cache.sh" "$@"
        ;;
    "help" | "-h" | "--help")
        show_usage
        exit 0
        ;;
    *)
        echo "❌ Unknown command: $1"
        echo
        show_usage
        exit 1
        ;;
esac
