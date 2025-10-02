# AWS SSO Profile Generator

AWS Single Sign-On (SSO) プロファイルの自動生成と管理を行う Bash スクリプト群です。

## 概要

AWS SSO 環境でのプロファイル管理を効率化するツール群で、以下の機能を提供します：

- **環境チェック** - AWS CLI v2、jq、bash、column コマンドの確認
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

### 前提条件

プロファイル自動生成を実行する前に、`~/.aws/config` ファイル（または `AWS_CONFIG_FILE` 環境変数で指定したファイル）に以下の設定が必要です：

```ini
# AWS SSO の API を実行するために IAM Identity Center の region の明記
# 設定がなければ AWS_REGION の環境変数で設定しても可
[default]
region = ap-northeast-1

# SSO セッション設定セクション
[sso-session my-session]
sso_region = ap-northeast-1
sso_start_url = https://your-domain.awsapps.com/start/
sso_registration_scopes = sso:account:access
```

### 実行手順

1. **環境チェックの実行**

   ```bash
   ./check-environment.sh
   ```

2. **SSO ログイン**

   ```bash
   # 基本的なログイン
   aws sso login --sso-session your-session-name

   # ブラウザが利用できない環境の場合
   aws sso login --sso-session your-session-name --use-device-code
   ```

3. **プロファイル自動生成**
   ```bash
   ./generate-sso-profiles.sh
   ```

## スクリプト構成

### メインスクリプト

- **`check-environment.sh`** - 全ステップを順次実行する環境チェックスクリプト

### 個別機能スクリプト

- **`check-tools.sh`** - 必要ツールの存在・バージョン確認
- **`check-aws-config.sh`** - AWS 設定ファイルとリージョン設定の確認
- **`check-sso-config.sh`** - SSO 設定とセッション状態の確認
- **`check-sso-profiles.sh`** - SSO プロファイルの分析・一覧表示・重複チェック
- **`generate-sso-profiles.sh`** - SSO プロファイルの自動一括生成
- **`cleanup-generated-profiles.sh`** - 自動生成プロファイルの削除

### 共通ライブラリ

- **`common.sh`** - ESC シーケンス定義、カラー定義、ログ関数、スピナー表示、共通ユーティリティ関数

### テスト環境

- **`test/`** - 開発・デバッグ用テストスクリプト群
  - `test_spinner.sh` - スピナー関数のテスト
  - `test_common.sh` - 共通関数のテスト
  - `test_colors.sh` - カラー表示のテスト
  - `run_all_tests.sh` - 全テスト実行スクリプト

## 使用方法

### 1. 環境確認

```bash
# 必要ツールの確認
./check-tools.sh

# AWS設定ファイルとリージョン設定の確認
./check-aws-config.sh

# SSO設定の確認
./check-sso-config.sh
```

### 2. プロファイル分析

```bash
# 全プロファイルの分析（重複チェック含む）
./check-sso-profiles.sh

# 自動生成プロファイルの詳細表示
./check-sso-profiles.sh auto

# 手動管理プロファイルの詳細表示
./check-sso-profiles.sh manual

# 重複プロファイルの詳細チェック
./check-sso-profiles.sh duplicates

# 全件表示（最大300件）
./check-sso-profiles.sh auto --all
```

### 3. プロファイル自動生成

```bash
# インタラクティブ自動生成
./generate-sso-profiles.sh

# デフォルト値で自動実行（対話なし）
./generate-sso-profiles.sh --force

# ヘルプ表示
./generate-sso-profiles.sh --help
```

#### オプション

- `--help`, `-h`: 詳細なヘルプメッセージを表示
- `--force`, `-f`: デフォルト値で自動実行（対話なし）

#### デフォルト設定（--force モード）

- **プレフィックス**: `autogen`
- **処理アカウント数**: 利用可能な全アカウント
- **リージョン**: SSO 設定から取得
- **正規化方式**: `minimal`（スペース → アンダースコアのみ）
- **重複処理**: 自動上書き

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

## 重要な前提条件

### リージョン設定の必要性

AWS SSO 関連のコマンド（`aws sso list-accounts`、`aws sso list-account-roles`等）を実行するには、**リージョン設定が必須**です。

#### 設定方法

```bash
# 環境変数による設定
export AWS_REGION=ap-northeast-1

# AWS CLI設定による設定
aws configure set region ap-northeast-1
```

#### 確認方法

```bash
# リージョン設定の詳細確認
./check-aws-config.sh

# 現在の設定確認
aws configure get region
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
./check-sso-config.sh

# 特定セッション確認
./check-sso-config.sh session-name
```

### プロファイル品質チェック

#### 重複プロファイル検出

- **自動検出** - 分析時に重複プロファイルを自動チェック
- **詳細分析** - 重複箇所の行番号と設定内容を表示
- **解決ガイダンス** - 重複解消の推奨事項を提示

```bash
# 重複プロファイルの詳細チェック
./check-sso-profiles.sh duplicates
```

#### 表示例

```
⚠️  重複プロファイル検出:
  重複プロファイル数: 1 個
  重複しているプロファイル名:
    - test-profile-1 (2回定義)

🔍 プロファイル名: test-profile-1
  定義 1: 行 1
    [profile test-profile-1]
    sso_session = session1
    ...
  定義 2: 行 13
    [profile test-profile-1]
    sso_session = session2
    ...
```

### セキュリティ機能

- アクセストークンは表示せず存在確認のみ
- 設定ファイルの自動バックアップ作成
- セッション期限切れの自動検出
- 削除前のユーザー確認プロセス

## 設定例

### 完全な AWS 設定ファイル例

```ini
# デフォルトリージョン設定（AWS SSO API 実行に必須）
[default]
region = ap-northeast-1

# SSO Session 設定
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

1. **リージョンが設定されていない**

   ```bash
   # エラー: Region not specified
   aws configure set region ap-northeast-1
   # または
   export AWS_REGION=ap-northeast-1
   ```

2. **SSO セッションが期限切れ**

   ```bash
   # 基本的なログイン
   aws sso login --sso-session your-session-name

   # ブラウザが利用できない環境の場合
   aws sso login --sso-session your-session-name --use-device-code
   ```

3. **jq コマンドが見つからない**

   ```bash
   brew install jq
   ```

4. **重複プロファイルが検出される**

   ```bash
   # 重複プロファイルの詳細確認
   ./check-sso-profiles.sh duplicates

   # 設定ファイルを手動で編集して重複を削除
   # または自動生成プロファイルの場合は再生成
   ./cleanup-generated-profiles.sh
   ./generate-sso-profiles.sh
   ```

5. **AWS CLI v1 が検出される**
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

# スピナー表示の使用
(sleep 3) &
show_spinner $! "処理中"

# 固定時間スピナー
show_spinner_for_seconds 2 "読み込み中"

# スピナー付きコマンド実行
run_with_spinner "ファイル作成中" "sleep 2 && touch /tmp/test"

# プログレス表示機能
show_progress_with_counter 5 10 "処理中"  # 5/10 (50%)
show_progress_complete 10 "完了"          # 100%完了表示
```

### テスト実行

```bash
# 個別テスト実行
./test/test_spinner.sh
./test/test_common.sh
./test/test_colors.sh

# 全テスト実行
./test/run_all_tests.sh
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

## 便利な組み合わせ

### fzf との組み合わせ

このツールで生成したプロファイルは、[fzf](https://github.com/junegunn/fzf)（fuzzy finder）と組み合わせることで、より便利に使用できます。

#### プロファイル選択の簡単化

```bash
# fzfを使ったプロファイル選択
export AWS_PROFILE=$(aws configure list-profiles | grep -v "^$" | fzf --prompt="AWS Profile > ")

# 自動生成プロファイルのみを選択
export AWS_PROFILE=$(aws configure list-profiles | grep "^autogen-" | fzf --prompt="Auto-generated Profile > ")

# 特定のアカウントのプロファイルを選択
export AWS_PROFILE=$(aws configure list-profiles | grep "123456789012" | fzf --prompt="Account 123456789012 > ")
```

#### シェル関数として登録

```bash
# ~/.bashrc または ~/.zshrc に追加
aws_profile() {
    local profile
    profile=$(aws configure list-profiles | grep -v "^$" | fzf --prompt="AWS Profile > ")
    if [ -n "$profile" ]; then
        export AWS_PROFILE="$profile"
        echo "✅ AWS_PROFILE set to: $profile"
    fi
}

# 自動生成プロファイル専用の関数
aws_autogen_profile() {
    local profile
    profile=$(aws configure list-profiles | grep "^autogen-" | fzf --prompt="Auto-generated Profile > ")
    if [ -n "$profile" ]; then
        export AWS_PROFILE="$profile"
        echo "✅ AWS_PROFILE set to: $profile"
    fi
}
```

#### 使用例

```bash
# プロファイル選択
aws_profile

# 選択されたプロファイルで AWS コマンド実行
aws sts get-caller-identity
aws s3 ls
```

#### fzf のインストール

```bash
# macOS (Homebrew)
brew install fzf

# Ubuntu/Debian
sudo apt install fzf

# その他の環境
# https://github.com/junegunn/fzf#installation を参照
```

#### 高度な使用例

```bash
# プレビュー機能付きプロファイル選択
aws_profile_with_preview() {
    local profile
    profile=$(aws configure list-profiles | grep -v "^$" | fzf \
        --prompt="AWS Profile > " \
        --preview="aws configure get region --profile {} 2>/dev/null || echo 'No region configured'" \
        --preview-window=right:30%)
    if [ -n "$profile" ]; then
        export AWS_PROFILE="$profile"
        echo "✅ AWS_PROFILE set to: $profile"
        echo "📍 Region: $(aws configure get region --profile "$profile" 2>/dev/null || echo 'Not configured')"
    fi
}
```

## ライセンス

このプロジェクトは MIT ライセンスの下で公開されています。

## 貢献

バグ報告や機能要望は Issue でお知らせください。プルリクエストも歓迎します。

## 更新履歴

- **v1.9.2** - コマンドラインオプションとデフォルト動作の改善
  - `--help`/`-h` オプション追加（詳細なヘルプ表示）
  - `--force`/`-f` オプション追加（デフォルト値で自動実行）
  - デフォルト処理アカウント数を全アカウントに変更
  - 自動化・CI/CD 対応の強化
- **v1.9.1** - プログレス表示形式の改善
- **v1.9** - プログレス表示機能と複数ブロック対応
  - プロファイル生成時のプログレス表示機能追加
  - 重複チェック処理のプログレス表示対応
  - 複数自動生成ブロック対応（分析機能修正）
  - ユーザー体験の大幅改善
- **v1.8** - コード品質向上とテスト環境整備
  - shellcheck 完全対応（全警告解決）
  - スピナー関数の改良（Unicode スピナー、ESC シーケンス統一）
  - テストディレクトリ作成（test/）
  - 開発・デバッグ用テストスクリプト追加
- **v1.7** - プロファイル品質チェック機能追加
- **v1.6** - リージョン設定確認機能強化
- **v1.5** - ツール名変更とブランディング統一
- **v1.4** - プロファイル分析機能追加
- **v1.3** - 複数 SSO Session 対応
- **v1.2** - 管理機能強化
- **v1.1** - 自動生成機能追加
- **v1.0** - 基本機能実装
