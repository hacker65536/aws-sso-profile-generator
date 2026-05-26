#!/usr/bin/env bash

# AWS SSO Profile Generator - キャッシュ機能テストスクリプト
# キャッシュ機能の動作確認とサンプル実装

set -euo pipefail

# 共通関数の読み込み（test/ から見て lib/common.sh）
source "$(dirname "$0")/../lib/common.sh"

# テスト用の設定
TEST_SESSION_NAME="test-session"
TEST_START_URL="https://example.awsapps.com/start/"
TEST_ACCOUNT_ID="123456789012"

# ヘルプ表示
show_help() {
    echo "AWS SSO Profile Generator - キャッシュ機能テスト"
    echo
    echo "使用方法:"
    echo "  $0 [コマンド]"
    echo
    echo "コマンド:"
    echo "  test-accounts    アカウント一覧キャッシュのテスト"
    echo "  test-roles       ロール一覧キャッシュのテスト"
    echo "  show-stats       キャッシュ統計の表示"
    echo "  clear-all        全キャッシュの削除"
    echo "  clear-session    特定セッションキャッシュの削除"
    echo "  demo             デモンストレーション実行"
    echo "  help             このヘルプを表示"
    echo
    echo "注意:"
    echo "  このスクリプトはテスト用です。実際のAWS APIは呼び出しません。"
}

# モックアカウントデータの生成
generate_mock_accounts() {
    cat << 'EOF'
{
  "accountList": [
    {
      "accountId": "123456789012",
      "accountName": "Production Account",
      "emailAddress": "admin@example.com"
    },
    {
      "accountId": "987654321098",
      "accountName": "Development Account",
      "emailAddress": "dev@example.com"
    },
    {
      "accountId": "555666777888",
      "accountName": "Staging Account",
      "emailAddress": "staging@example.com"
    }
  ]
}
EOF
}

# モックロールデータの生成
generate_mock_roles() {
    local account_id="$1"
    cat << EOF
{
  "roleList": [
    {
      "roleName": "PowerUserAccess",
      "accountId": "$account_id"
    },
    {
      "roleName": "ReadOnlyAccess",
      "accountId": "$account_id"
    },
    {
      "roleName": "AdministratorAccess",
      "accountId": "$account_id"
    }
  ]
}
EOF
}

# アカウント一覧キャッシュのテスト
test_accounts_cache() {
    log_info "アカウント一覧キャッシュのテスト開始"
    
    # モック関数でaws sso list-accountsを置き換え
    aws() {
        if [ "$1" = "sso" ] && [ "$2" = "list-accounts" ]; then
            # ログ出力は標準エラーに出力してJSONに混入しないようにする
            echo "ℹ️  モックAWS API呼び出し: aws sso list-accounts" >&2
            generate_mock_accounts
            return 0
        else
            # 他のawsコマンドは元のコマンドを実行
            command aws "$@"
        fi
    }
    export -f aws
    
    # 1回目の呼び出し（API呼び出し）
    log_info "1回目の呼び出し（API呼び出し）"
    local result1
    {
        result1=$(get_cached_accounts "$TEST_SESSION_NAME" "$TEST_START_URL" "mock-token")
    } 2>/dev/null
    
    if [ $? -eq 0 ] && [ -n "$result1" ]; then
        log_success "アカウント一覧を取得しました"
        log_debug "結果1の内容: $result1"
        if echo "$result1" | jq . >/dev/null 2>&1; then
            echo "$result1" | jq -r '.accountList[].accountName' | head -3
        else
            log_error "結果1が有効なJSONではありません"
            echo "生データ: $result1"
        fi
    else
        log_error "アカウント一覧の取得に失敗しました"
        return 1
    fi
    
    echo
    
    # 2回目の呼び出し（キャッシュから）
    log_info "2回目の呼び出し（キャッシュから）"
    local result2
    {
        result2=$(get_cached_accounts "$TEST_SESSION_NAME" "$TEST_START_URL" "mock-token")
    } 2>/dev/null
    
    if [ $? -eq 0 ] && [ -n "$result2" ]; then
        log_success "アカウント一覧をキャッシュから取得しました"
        echo "$result2" | jq -r '.accountList[].accountName' | head -3
    else
        log_error "キャッシュからの取得に失敗しました"
        return 1
    fi
    
    # 結果の比較（JSONとして比較）
    # pipefail 下で jq が失敗してもテスト本体の比較ロジックを通すため || true で吸収
    local json1_normalized
    local json2_normalized
    json1_normalized=$(echo "$result1" | jq -c . 2>/dev/null || true)
    json2_normalized=$(echo "$result2" | jq -c . 2>/dev/null || true)

    if [ "$json1_normalized" = "$json2_normalized" ]; then
        log_success "キャッシュが正常に動作しています"
    else
        log_error "キャッシュの結果が一致しません"
        log_debug "結果1: $json1_normalized"
        log_debug "結果2: $json2_normalized"
        return 1
    fi
}

# ロール一覧キャッシュのテスト
test_roles_cache() {
    log_info "ロール一覧キャッシュのテスト開始"
    
    # モック関数でaws sso list-account-rolesを置き換え
    aws() {
        if [ "$1" = "sso" ] && [ "$2" = "list-account-roles" ]; then
            # ログ出力は標準エラーに出力してJSONに混入しないようにする
            echo "ℹ️  モックAWS API呼び出し: aws sso list-account-roles" >&2
            generate_mock_roles "$TEST_ACCOUNT_ID"
            return 0
        else
            # 他のawsコマンドは元のコマンドを実行
            command aws "$@"
        fi
    }
    export -f aws
    
    # 1回目の呼び出し（API呼び出し）
    log_info "1回目の呼び出し（API呼び出し）"
    local result1
    {
        result1=$(get_cached_roles "$TEST_ACCOUNT_ID" "mock-token" "$TEST_SESSION_NAME" "$TEST_START_URL")
    } 2>/dev/null
    
    if [ $? -eq 0 ] && [ -n "$result1" ]; then
        log_success "ロール一覧を取得しました"
        echo "$result1" | jq -r '.roleList[].roleName'
    else
        log_error "ロール一覧の取得に失敗しました"
        return 1
    fi
    
    echo
    
    # 2回目の呼び出し（キャッシュから）
    log_info "2回目の呼び出し（キャッシュから）"
    local result2
    {
        result2=$(get_cached_roles "$TEST_ACCOUNT_ID" "mock-token" "$TEST_SESSION_NAME" "$TEST_START_URL")
    } 2>/dev/null
    
    if [ $? -eq 0 ] && [ -n "$result2" ]; then
        log_success "ロール一覧をキャッシュから取得しました"
        echo "$result2" | jq -r '.roleList[].roleName'
    else
        log_error "キャッシュからの取得に失敗しました"
        return 1
    fi
    
    # 結果の比較（JSONとして比較）
    # pipefail 下で jq が失敗してもテスト本体の比較ロジックを通すため || true で吸収
    local json1_normalized
    local json2_normalized
    json1_normalized=$(echo "$result1" | jq -c . 2>/dev/null || true)
    json2_normalized=$(echo "$result2" | jq -c . 2>/dev/null || true)

    if [ "$json1_normalized" = "$json2_normalized" ]; then
        log_success "キャッシュが正常に動作しています"
    else
        log_error "キャッシュの結果が一致しません"
        log_debug "結果1: $json1_normalized"
        log_debug "結果2: $json2_normalized"
        return 1
    fi
}

# デモンストレーション
run_demo() {
    log_info "キャッシュ機能デモンストレーション開始"
    echo
    
    # 初期状態の確認
    log_info "=== 初期状態 ==="
    show_cache_stats
    echo
    
    # アカウントキャッシュのテスト
    log_info "=== アカウントキャッシュテスト ==="
    test_accounts_cache
    echo
    
    # ロールキャッシュのテスト
    log_info "=== ロールキャッシュテスト ==="
    test_roles_cache
    echo
    
    # キャッシュ統計の表示
    log_info "=== キャッシュ統計 ==="
    show_cache_stats
    echo
    
    # メタデータの更新
    log_info "=== メタデータ更新 ==="
    update_cache_metadata "$TEST_SESSION_NAME" "$TEST_START_URL"
    
    if [ -f "${CACHE_DIR}/metadata.json" ]; then
        log_success "メタデータファイルを確認:"
        cat "${CACHE_DIR}/metadata.json" | jq .
    fi
    echo
    
    log_success "デモンストレーション完了"
}

# メイン処理
main() {
    local command="${1:-demo}"
    
    case "$command" in
        "test-accounts")
            test_accounts_cache
            ;;
        "test-roles")
            test_roles_cache
            ;;
        "show-stats")
            show_cache_stats
            ;;
        "clear-all")
            clear_cache
            ;;
        "clear-session")
            clear_cache "$TEST_SESSION_NAME"
            ;;
        "demo")
            run_demo
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            log_error "不明なコマンド: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

# スクリプト実行
main "$@"