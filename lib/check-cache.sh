#!/usr/bin/env bash

# AWS SSO Profile Generator - キャッシュ管理サブコマンド
# 使用方法: check.sh cache [stats|clear|validate|help]

set -euo pipefail

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

show_usage() {
    echo "使用方法: check.sh cache [SUBCOMMAND]"
    echo
    echo "サブコマンド:"
    echo "  (なし) | stats        キャッシュ統計を表示 (デフォルト)"
    echo "  clear [SESSION]       全キャッシュを削除 (SESSION 指定でセッション単位)"
    echo "  validate              キャッシュファイルの有効性をチェック"
    echo "  help                  このヘルプを表示"
    echo
    echo "例:"
    echo "  check.sh cache              # 統計表示"
    echo "  check.sh cache clear        # 全削除"
    echo "  check.sh cache clear my-session   # セッション単位削除"
    echo "  check.sh cache validate     # 期限切れファイルを一覧"
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
        log_warning "期限切れファイル (10 件まで表示):"
        find "$CACHE_DIR" -maxdepth 1 -type f \
            \( -name "accounts-*.json" -o -name "roles-*.json" \) \
            ! -mmin "-${max_mmin}" 2>/dev/null \
            | head -10 \
            | while IFS= read -r f; do
                echo "    - $(basename "$f")"
            done
        echo
        log_info "削除するには: check.sh cache clear"
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
            log_error "不明なサブコマンド: $cmd"
            echo
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
