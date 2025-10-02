#!/usr/bin/env bash

# カラー表示のテストスクリプト

# 共通関数を読み込み
source "$(dirname "$0")/../common.sh"

echo "🎨 カラー表示のテスト開始"
echo "========================"
echo

# テスト1: 基本カラー
echo "テスト1: 基本カラー"
echo -e "${RED}赤色テキスト${RESET}"
echo -e "${GREEN}緑色テキスト${RESET}"
echo -e "${YELLOW}黄色テキスト${RESET}"
echo -e "${BLUE}青色テキスト${RESET}"
echo -e "${GRAY}グレーテキスト${RESET}"
echo "✅ テスト1完了"
echo

# テスト2: 制御文字
echo "テスト2: 制御文字"
echo "カーソルを隠します..."
printf "%s" "$HIDE_CURSOR"
sleep 1
echo "カーソルを表示します..."
printf "%s" "$SHOW_CURSOR"
echo "行を消去します..."
printf "%s" "$ERASE_LINE"
echo "新しいテキスト"
echo "✅ テスト2完了"
echo

# テスト3: スピナー文字の表示
echo "テスト3: スピナー文字の表示"
spin='⠧⠏⠛⠹⠼⠶'
n=${#spin}
echo "スピナー文字:"
for ((i=0; i<n; i++)); do
    printf "%s " "${spin:i:1}"
done
echo
echo "✅ テスト3完了"
echo

# テスト4: プログレスバー文字の表示
echo "テスト4: プログレスバー文字の表示"
progress='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
n=${#progress}
echo "プログレスバー文字:"
for ((i=0; i<n; i++)); do
    printf "%s " "${progress:i:1}"
done
echo
echo "✅ テスト4完了"
echo

echo "🎉 全てのカラーテストが完了しました！"