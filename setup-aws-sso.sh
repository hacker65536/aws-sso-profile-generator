#!/usr/bin/env bash

# AWS SSO Profile Generator - メインセットアップスクリプト
# 段階的に AWS CLI v2 と SSO 設定をセットアップし、プロファイル生成の準備を行います

set -e

echo "🚀 AWS SSO Profile Generator セットアップを開始します"
echo "================================================"
echo

# Step 1: 必要ツールの確認
echo "📋 Step 1: 必要ツールの確認"
./check-tools.sh
echo

# Step 2: AWS設定ファイルの確認
echo "📋 Step 2: AWS設定ファイルの確認"
./check-aws-config.sh
echo

# Step 3: SSO設定の確認・作成
echo "📋 Step 3: SSO設定の確認・作成"
./check-sso-config.sh
echo

echo "🎉 AWS SSO Profile Generator セットアップが完了しました！"
echo
echo "各ステップを個別に実行したい場合:"
echo "  ./check-tools.sh           - 必要ツール確認"
echo "  ./check-aws-config.sh      - AWS設定ファイル確認"
echo "  ./check-sso-config.sh   - SSO設定確認・作成"
echo "  ./generate-sso-profiles.sh - プロファイル自動生成（メイン機能）"