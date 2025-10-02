#!/usr/bin/env bash

# 共通関数のテストスクリプト

# 共通関数を読み込み
source "$(dirname "$0")/../common.sh"

echo "🧪 共通関数のテスト開始"
echo "======================"
echo

# テスト1: ログ関数
echo "テスト1: ログ関数"
log_info "これは情報メッセージです"
log_success "これは成功メッセージです"
log_warning "これは警告メッセージです"
log_error "これはエラーメッセージです"
DEBUG=1 log_debug "これはデバッグメッセージです（DEBUG=1の時のみ表示）"
echo "✅ テスト1完了"
echo

# テスト2: 設定ファイルパス取得
echo "テスト2: 設定ファイルパス取得"
config_file=$(get_config_file)
echo "デフォルト設定ファイル: $config_file"
AWS_CONFIG_FILE="/tmp/test_config" get_config_file_result=$(AWS_CONFIG_FILE="/tmp/test_config" get_config_file)
echo "カスタム設定ファイル: $get_config_file_result"
echo "✅ テスト2完了"
echo

# テスト3: 日時関数
echo "テスト3: 日時関数"
current_datetime=$(get_current_datetime)
echo "現在の日時: $current_datetime"
current_date=$(get_current_date)
echo "現在の日付: $current_date"
timezone=$(get_current_timezone)
echo "タイムゾーン: $timezone"
echo "✅ テスト3完了"
echo

# テスト4: GNU dateの検出
echo "テスト4: GNU dateの検出"
if is_gnu_date; then
    echo "GNU dateが検出されました"
else
    echo "BSD dateまたはその他のdateコマンドが検出されました"
fi
echo "✅ テスト4完了"
echo

# テスト5: UTC時刻変換（サンプル）
echo "テスト5: UTC時刻変換"
sample_utc="2024-01-01T12:00:00Z"
local_time=$(convert_utc_to_local "$sample_utc")
echo "UTC時刻: $sample_utc"
echo "ローカル時刻: $local_time"
echo "✅ テスト5完了"
echo

echo "🎉 全ての共通関数テストが完了しました！"