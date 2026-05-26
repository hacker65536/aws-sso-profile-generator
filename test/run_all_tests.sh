#!/usr/bin/env bash

# 全テストの実行スクリプト

echo "🧪 AWS SSO Profile Generator - 全テスト実行"
echo "=========================================="
echo

# テストディレクトリに移動
cd "$(dirname "$0")" || exit 1

# 実行権限を付与
chmod +x *.sh

# テスト結果を記録
total_tests=0
passed_tests=0
failed_tests=0

# テスト実行関数
run_test() {
    local test_file="$1"
    local test_name="$2"
    
    echo "🔍 $test_name を実行中..."
    echo "----------------------------------------"
    
    total_tests=$((total_tests + 1))
    
    if ./"$test_file"; then
        echo "✅ $test_name: 成功"
        passed_tests=$((passed_tests + 1))
    else
        echo "❌ $test_name: 失敗"
        failed_tests=$((failed_tests + 1))
    fi
    
    echo "----------------------------------------"
    echo
}

# 各テストを実行
run_test "test_colors.sh" "カラー表示テスト"
run_test "test_common.sh" "共通関数テスト"
run_test "test_spinner.sh" "スピナー関数テスト"
run_test "test_units.sh"  "純関数の単体テスト"
run_test "test-e2e.sh"    "E2E (mock aws によるフルパイプライン検証)"

# 結果サマリー
echo "📊 テスト結果サマリー"
echo "===================="
echo "総テスト数: $total_tests"
echo "成功: $passed_tests"
echo "失敗: $failed_tests"
echo

if [ $failed_tests -eq 0 ]; then
    echo "🎉 全てのテストが成功しました！"
    exit 0
else
    echo "⚠️  $failed_tests 個のテストが失敗しました。"
    exit 1
fi