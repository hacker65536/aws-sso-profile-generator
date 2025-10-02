# AWS SSO Profile Generator

AWS Single Sign-On (SSO) プロファイルの自動生成と管理を行う Bash スクリプト群です。

## 概要

AWS SSO 環境でのプロファイル管理を効率化するツール群で、以下の機能を提供します：

- **環境セットアップ** - AWS CLI v2、jq、bash、column コマンドの確認
- **設定ファイル確認** - AWS 設定ファイルの存在と内容の確認
- **SSO セッション管理** - SSO セッション設定とセッション状態の確認
- **プロファイル分析** - 自動生成・手動管理プロファイルの分析・一覧表示
- **プロファイル自動生成** - AWS CLI SSO API を使用した一括プロファイル生成（メイン機能）
- **プロファイル削除** - 自動生成されたプロファイルの安全な削除

## 必要な環境

- **AWS CLI v2** - AWS 操作の基盤ツール
- **Bash v4 以上** - スクリプト実行環境
- **jq** - JSON 処理ツール
- **column** - 表示整形ツール

## インストール

### AWS CLI v2
```bash
# macOS
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /

# または Homebrew
brew install awscli
```

### jq
```bash
# macOS (Homebrew)
brew install jq
```

### Bash (macOS の場合)
```bash
# macOS (Homebrew) - 新しいバージョンが必要な場合
brew install bash
```

## クイックスタート

1. **全体セットアップの実行**
   ```bash
   ./setup-aws-sso.sh
   ```

2. **SSO ログイン**
   ```bash
   aws sso login --profile your-profile
   ```

3. **プロファイル自動生成**
   ```bash
   ./generate-sso-profiles.sh
   ```

## スクリプト構成

### メインスクリプト

- **`setup-aws-sso.sh`** - 全ステップを順次実行するメインスクリプト

### 個別機能スクリプト

- **`check-tools.sh`** - 必要ツールの存在・バージョン確認
- **`check-aws-config.sh`** - AWS 設定ファイルの確認とサマリー表示
- **`check-awssso-config.sh`** - SSO 設定とセッション状態の確認
- **`check-sso-profiles.sh`** - SSO プロファイルの分析・一覧表示
- **`generate-sso-profiles.sh`** - SSO プロファイルの自動一括生成
- **`cleanup-generated-profiles.sh`** - 自動生成プロファイルの削除

### 共通ライブラリ

- **`common.sh`** - カラー定義、ログ関数、共通ユーティリティ関数

## 使用方法

### 1. 環境確認

```bash
# 必要ツールの確認
./check-tools.sh

# AWS設定ファイルの確認
./check-aws-config.sh

# SSO設定の確認
./check-awssso-config.sh
```

### 2. プロファイル分析

```bash
# 全プロファイルの分析
./check-sso-profiles.sh

# 自動生成プロファイルの詳細表示
./check-sso-profiles.sh auto

# 手動管理プロファイルの詳細表示
./check-sso-profiles.sh manual

# 全件表示（最大300件）
./check-sso-profiles.sh auto --all
```

### 3. プロファイル自動生成

```bash
# インタラクティブ自動生成
./generate-sso-profiles.sh
```

生成されるプロファイル形式：
```ini
# AWS_SSO_CONFIG_GENERATOR START 2024/12/10 15:30:45

[profile autogen-MyCompany-123456789012:PowerUserAccess]
sso_session = my-session
sso_account_id = 123456789012
sso_role_name = PowerUserAccess
region = ap-northeast-1
output = json
cli_pager = 

# AWS_SSO_CONFIG_GENERATOR END 2024/12/10 15:30:45
```

### 4. プロファイル削除

```bash
# 自動生成プロファイルの削除
./cleanup-generated-profiles.sh
```

## 機能詳細

### プロファイル命名規則

```
{prefix}-{normalized_account_name}-{account_id}:{role_name}
```

### アカウント名正規化オプション

- **minimal** (デフォルト): スペース → アンダースコアのみ
- **full**: 小文字変換 + ハイフン → アンダースコア + スペース → アンダースコア

正規化例：
```
元の名前: 'My Perfect-Web-Service Prod'
minimal:  'My_Perfect-Web-Service_Prod'  (デフォルト)
full:     'my_perfect_web_service_prod'
```

### 複数 SSO Session 対応

- 複数の SSO Session が設定されている場合、自動検出して表示
- 特定のセッションを指定可能
- 大量のセッションがある場合は表示を最適化

```bash
# 全セッション表示、最初のセッション使用
./check-awssso-config.sh

# 特定セッション確認
./check-awssso-config.sh session-name
```

### セキュリティ機能

- アクセストークンは表示せず存在確認のみ
- 設定ファイルの自動バックアップ作成
- セッション期限切れの自動検出
- 削除前のユーザー確認プロセス

## 設定例

### SSO Session 設定

```ini
[sso-session my-session]
sso_region = ap-northeast-1
sso_start_url = https://your-domain.awsapps.com/start/
sso_registration_scopes = sso:account:access
```

### 生成されるプロファイル例

```ini
[profile autogen-Production-123456789012:AdministratorAccess]
sso_session = my-session
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = ap-northeast-1
output = json
cli_pager = 
```

## トラブルシューティング

### よくある問題

1. **SSO セッションが期限切れ**
   ```bash
   aws sso login --profile your-profile
   ```

2. **jq コマンドが見つからない**
   ```bash
   brew install jq
   ```

3. **AWS CLI v1 が検出される**
   ```bash
   # AWS CLI v2 をインストールしてください
   brew install awscli
   ```

### ログレベル

- ✅ 成功メッセージ（緑色）
- ℹ️ 情報メッセージ（青色）
- ⚠️ 警告メッセージ（黄色）
- ❌ エラーメッセージ（赤色）

## 開発・カスタマイズ

### 共通関数の利用

```bash
# 各スクリプトの冒頭で読み込み
source "$(dirname "$0")/common.sh"

# ログ関数の使用
log_info "情報メッセージ"
log_success "成功メッセージ"
log_warning "警告メッセージ"
log_error "エラーメッセージ"
```

### 設定ファイルパスの取得

```bash
config_file=$(get_config_file)
```

### SSO 設定の取得

```bash
if get_sso_config "$config_file"; then
    echo "Session: $SSO_SESSION_NAME"
    echo "Region: $SSO_REGION"
    echo "Start URL: $SSO_START_URL"
fi
```

## ライセンス

このプロジェクトは MIT ライセンスの下で公開されています。

## 貢献

バグ報告や機能要望は Issue でお知らせください。プルリクエストも歓迎します。

## 更新履歴

- **v1.5** - ツール名変更とブランディング統一
- **v1.4** - プロファイル分析機能追加
- **v1.3** - 複数 SSO Session 対応
- **v1.2** - 管理機能強化
- **v1.1** - 自動生成機能追加
- **v1.0** - 基本機能実装