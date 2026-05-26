#!/usr/bin/env bash

# AWS SSO Profile Generator - キャッシュ管理サブコマンド
# 使用方法: check.sh cache [stats|clear|validate|help]

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

show_usage() {
    echo "Usage: check.sh cache [SUBCOMMAND]"
    echo
    echo "Subcommands:"
    echo "  (none) | stats        Show cache statistics (default)"
    echo "  clear [SESSION]       Clear all cache (or only for SESSION)"
    echo "  validate              Validate cache files"
    echo "  help                  Show this help"
    echo
    echo "Examples:"
    echo "  check.sh cache              # Show statistics"
    echo "  check.sh cache clear        # Clear all"
    echo "  check.sh cache clear my-session   # Clear per-session"
    echo "  check.sh cache validate     # List expired files"
}

cmd_validate() {
    log_info "Cache validation:"
    log_kv "Cache directory" "$CACHE_DIR"

    if [ ! -d "$CACHE_DIR" ]; then
        echo "  (directory not created yet)"
        return 0
    fi

    local max_mmin
    max_mmin=$(awk -v h="${CACHE_EXPIRY_HOURS:-24}" 'BEGIN{ printf "%.0f", h * 60 }')

    local valid_count expired_count
    valid_count=$(find "$CACHE_DIR" -maxdepth 1 -type f \
        \( -name "accounts-*.json" -o -name "roles-*.json" \) \
        -mmin "-${max_mmin}" 2>/dev/null | wc -l | tr -d ' ')
    expired_count=$(find "$CACHE_DIR" -maxdepth 1 -type f \
        \( -name "accounts-*.json" -o -name "roles-*.json" \) \
        ! -mmin "-${max_mmin}" 2>/dev/null | wc -l | tr -d ' ')

    log_kv "Valid (within TTL)" "${valid_count}  (TTL: ${CACHE_EXPIRY_HOURS:-24} hours)"
    log_kv "Expired"            "${expired_count}"

    if [ "$expired_count" -gt 0 ]; then
        echo
        log_warning "Expired files (showing up to 10):"
        find "$CACHE_DIR" -maxdepth 1 -type f \
            \( -name "accounts-*.json" -o -name "roles-*.json" \) \
            ! -mmin "-${max_mmin}" 2>/dev/null \
            | head -10 \
            | while IFS= read -r f; do
                echo "    - $(basename "$f")"
            done
        echo
        log_info "To clear them: check.sh cache clear"
    fi
}

main() {
    local cmd="${1:-stats}"
    shift || true

    case "$cmd" in
        ""|stats)
            show_cache_stats
            ;;
        clear)
            clear_cache "${1:-}"
            ;;
        validate)
            cmd_validate
            ;;
        help|-h|--help)
            show_usage
            ;;
        *)
            log_error "Unknown subcommand: $cmd"
            echo
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
