#!/usr/bin/env bash

# スピナー関数のテストスクリプト

# 共通関数を読み込み
source "$(dirname "$0")/../common.sh"

echo "🧪 スピナー関数のテスト開始"
echo "=========================="
echo

# テスト1: 基本的なスピナー
echo "テスト1: 基本的なスピナー（3秒間）"
(sleep 3) &
show_spinner $! "データを処理中"
echo "✅ テスト1完了"
echo

# テスト2: 固定時間スピナー
echo "テスト2: 固定時間スピナー（2秒間）"
show_spinner_for_seconds 2 "設定を読み込み中"
echo "✅ テスト2完了"
echo

# テスト3: プログレスバー風スピナー
echo "テスト3: プログレスバー風スピナー（3秒間）"
(sleep 3) &
show_progress_spinner $! "アカウント情報を取得中"
echo "✅ テスト3完了"
echo

# テスト4: run_with_spinner関数
echo "テスト4: run_with_spinner関数"
run_with_spinner "ファイルを作成中" "sleep 2 && echo 'ファイル作成完了' > /tmp/test_file"
if [ -f "/tmp/test_file" ]; then
    echo "✅ テスト4完了: ファイルが正常に作成されました"
    rm -f /tmp/test_file
else
    echo "❌ テスト4失敗: ファイルが作成されませんでした"
fi
echo

# テスト5: プログレス表示機能
echo "テスト5: プログレス表示機能"
echo "プログレス表示のデモンストレーション:"

# カーソルを非表示にする
printf "%s" "$HIDE_CURSOR"

for i in {1..10}; do
    show_progress_with_counter "$i" "10" "アイテム処理中"
    sleep 0.3
done

show_progress_complete "10" "処理完了"
echo "✅ テスト5完了"
echo

echo "🎉 全てのスピナーテストが完了しました！"