# AWS SSO Profile Generator

AWS Single Sign-On (SSO) プロファイルの自動生成と管理を行う Bash スクリプト群です。

## 概要

AWS SSO 環境でのプロファイル管理を効率化するツール群で、以下の機能を提供します：

1. **環境セットアップ** - AWS CLI v2、jq、bash、column コマンドの確認
2. **設定ファイル確認** - AWS 設定ファイルの存在と内容の確認
3. **SSO セッション管理** - SSO セッション設定とセッション状態の確認
4. **プロファイル分析** - 自動生成・手動管理プロファイルの分析・一覧表示
5. **プロファイル自動生成** - AWS CLI SSO API を使用した一括プロファイル生成（メイン機能）
6. **プロファイル削除** - 自動生成されたプロファイルの安全な削除

## スクリプト構成

### メインスクリプト

- **setup-aws-sso.sh** - 全ステップを順次実行するメインスクリプト

### 個別機能スクリプト

- **check-tools.sh** - 必要ツールの存在・バージョン確認
- **check-aws-config.sh** - AWS 設定ファイルの確認とサマリー表示
- **check-sso-config.sh** - SSO 設定とセッション状態の確認
- **check-sso-profiles.sh** - SSO プロファイルの分析・一覧表示・重複チェック
- **generate-sso-profiles.sh** - SSO プロファイルの自動一括生成
- **cleanup-generated-profiles.sh** - 自動生成プロファイルの削除

### 共通ライブラリ

- **common.sh** - カラー定義、ログ関数、共通ユーティリティ関数

### 設計原則

- **プロファイル生成特化**: SSO プロファイルの効率的な生成・管理に最適化
- **統一性**: 全スクリプトで統一された UI・ログ出力・エラーハンドリング
- **簡潔性**: 重要な情報のみを抽出した見やすい表示
- **モジュール性**: 各スクリプトが独立して実行可能
- **拡張性**: 新機能追加時の一貫した実装パターン

## 機能詳細

### 1. 必要ツールの確認

#### 対象ツール

- **AWS CLI v2** - AWS 操作の基盤ツール
- **Bash v4 以上** - スクリプト実行環境
- **jq** - JSON 処理ツール
- **column** - 表示整形ツール

#### 確認内容

- コマンドの存在確認
- バージョン情報の表示
- 不足している場合のインストール方法案内

#### 実装ファイル

- `check-tools.sh` - 統合ツールチェック

### 2. AWS 設定ファイルとリージョン設定の確認

#### 確認項目

- 環境変数 `AWS_CONFIG_FILE` の設定状況
- 設定ファイルの存在確認（デフォルト: `$HOME/.aws/config`）
- 設定ファイルのサマリー表示
- **リージョン設定の詳細確認**（AWS SSO コマンドに必須）

#### 表示内容

設定ファイルが見つかった場合、以下の情報を簡潔に表示：

- SSO セッション数
- プロファイル数
- 管理対象プロファイル数
- 各 SSO セッション名の一覧
- 管理対象プロファイル名の一覧

#### 表示例

```
設定サマリー:
  SSO セッション数: 1
  プロファイル数: 123
  管理対象プロファイル数: 2

SSO セッション:
  - go

管理対象プロファイル:
  - another-company
  - test-company
```

#### リージョン設定確認機能

AWS SSO 関連コマンド（`aws sso list-accounts`、`aws sso list-account-roles` 等）の実行には**リージョン設定が必須**のため、詳細な確認を実施：

##### 確認内容

1. **環境変数確認**
   - `AWS_REGION`
   - `AWS_DEFAULT_REGION`

2. **AWS CLI 設定確認**
   - `aws configure get region`
   - `aws configure list`

3. **設定一貫性チェック**
   - 複数設定方法間の整合性確認
   - 不整合時の警告表示
   - 優先順位の説明（環境変数 > AWS CLI設定）

4. **実効リージョン表示**
   - 実際に AWS CLI コマンドで使用されるリージョン
   - 設定ソースの特定

##### 表示例

```
🌍 環境変数によるリージョン設定:
  AWS_REGION: 未設定
  AWS_DEFAULT_REGION: 未設定

⚙️  AWS CLI設定によるリージョン:
  aws configure get region: ap-northeast-1

🔍 設定の一貫性チェック:
✅ リージョン設定が一貫しています: ap-northeast-1
✅ AWS SSO コマンドが正常に実行できます

✅ AWS SSO コマンドで使用されるリージョン:
✅ AWS CLI設定によりリージョンが設定されています
  ap-northeast-1 (AWS CLI設定)
```

#### 実装ファイル

- `check-aws-config.sh`

### 3. SSO 設定の確認

#### 設定項目チェック

以下の必須設定項目の存在を確認：

```ini
[sso-session {session-name}]
sso_region = {region}
sso_start_url = {url}
sso_registration_scopes = sso:account:access
```

#### セッション状態チェック

- `~/.aws/sso/cache/` 内のキャッシュファイル検索
- SSO Start URL を含む JSON ファイルの特定
- 最新ファイルからのアクセストークンと有効期限取得
- 有効期限のローカルタイムゾーン変換と表示
- セッション有効性の判定

#### 複数 SSO Session 対応

- **自動検出** - 設定ファイル内の全 SSO Session を自動検出
- **詳細表示制限** - 5 個を超える場合は最初の 5 個のみ詳細表示
- **省略表示** - 6 個以上の場合「... 他 X 個のセッション（詳細は省略）」を表示
- **特定セッション指定** - コマンドライン引数でセッション名を指定可能
- **デフォルト選択** - 複数セッションがある場合、最初のセッションを自動選択
- **エラーハンドリング** - 存在しないセッション名指定時の適切なエラー表示

#### 使用方法

```bash
# 全セッションを表示し、最初のセッションを使用
./check-sso-config.sh

# 特定のセッションを確認
./check-sso-config.sh session-name

# ヘルプ表示
./check-sso-config.sh --help
```

#### 表示例（複数セッション）

```
利用可能なSSO Sessions:
  1. session1
     Region: ap-northeast-1
     Start URL: https://example1.awsapps.com/start/

  2. session2
     Region: us-east-1
     Start URL: https://example2.awsapps.com/start/

  ... 他 3 個のセッション（詳細は省略）

複数のSSO Sessionが設定されています（合計: 5 個）
デフォルトで使用するセッション: session1
```

#### 実装ファイル

- `check-sso-config.sh`

### 4. SSO プロファイルの分析・重複チェック

#### 機能概要

AWS 設定ファイル内のプロファイルを自動生成・手動管理に分類し、詳細な分析・一覧表示・重複チェックを行います。

#### 分析機能

- **プロファイル統計** - 全プロファイル、自動生成、手動管理の数を表示
- **重複プロファイル検出** - 重複するプロファイル名の自動検出と警告表示
- **自動生成プロファイル詳細** - 生成日時、プロファイル例の表示
- **手動管理プロファイル詳細** - 手動で作成されたプロファイルの一覧表示
- **表示制限** - デフォルト 10 件、--all オプションで最大 300 件表示

#### 分析結果表示例

```
📊 プロファイル統計:
  全プロファイル数: 123
  自動生成プロファイル: 120
  手動管理プロファイル: 3

🤖 自動生成プロファイル詳細:
  生成日時: 2024/12/10 15:30:45
  プロファイル例（最初の5個）:
    - autogen-MyCompany-123456789012:PowerUserAccess
    - autogen-MyCompany-123456789012:ReadOnlyAccess
    ... 他 115 個

✋ 手動管理プロファイル詳細:
  プロファイル例（最初の5個）:
    - custom-profile-1
    - custom-profile-2
    - custom-profile-3
```

#### 詳細表示機能

- **自動生成プロファイル詳細** - 生成情報とプロファイル名一覧
- **手動管理プロファイル詳細** - プロファイル名、セッション、アカウント、ロール、リージョンの表形式表示
- **表示制限オプション** - --all フラグで全件表示（最大 300 件）

#### 重複プロファイル検出機能

**自動検出**
- 全プロファイル分析時に重複を自動チェック
- 重複プロファイル数と名前を表示
- 各重複プロファイルの定義回数を表示

**詳細分析**
- 専用の `duplicates` コマンドで詳細分析
- 重複箇所の行番号を特定
- 各定義の設定内容を表示
- 重複解消の推奨事項を提示

**表示例**
```
⚠️  重複プロファイル検出:
  重複プロファイル数: 1 個
  重複しているプロファイル名:
    - test-profile-1 (2回定義)

🔍 プロファイル名: test-profile-1
  定義 1: 行 1
    [profile test-profile-1]
    sso_session = session1
    sso_account_id = 123456789012
    ...
  定義 2: 行 13
    [profile test-profile-1]
    sso_session = session2
    sso_account_id = 987654321098
    ...
```

#### 使用方法

```bash
./check-sso-profiles.sh                    # 全プロファイルの分析（重複チェック含む）
./check-sso-profiles.sh analyze            # 全プロファイルの分析（重複チェック含む）
./check-sso-profiles.sh auto               # 自動生成プロファイル詳細（10件）
./check-sso-profiles.sh auto --all         # 自動生成プロファイル詳細（全件）
./check-sso-profiles.sh manual             # 手動管理プロファイル詳細（10件）
./check-sso-profiles.sh manual --all       # 手動管理プロファイル詳細（全件）
./check-sso-profiles.sh duplicates         # 重複プロファイルの詳細チェック
```

#### 実装ファイル

- `check-sso-profiles.sh`

### 5. SSO プロファイルの自動生成

#### 機能概要

AWS CLI SSO API を使用して、利用可能なアカウントとロールを自動検出し、プロファイルを一括生成します。

#### 自動生成プロファイル形式

一括処理の開始と終了時にコメントマーカーを配置：

```ini
# AWS_SSO_CONFIG_GENERATOR START YYYY/MM/DD HH:MM:SS

[profile {prefix}-{normalized_account_name}-{account_id}:{role_name}]
sso_session = {session_name}
sso_account_id = {account_id}
sso_role_name = {role_name}
region = {region}
output = json
cli_pager =

[profile {prefix}-{normalized_account_name}-{account_id}:{role_name}]
sso_session = {session_name}
sso_account_id = {account_id}
sso_role_name = {role_name}
region = {region}
output = json
cli_pager =

# AWS_SSO_CONFIG_GENERATOR END YYYY/MM/DD HH:MM:SS
```

#### プロファイル命名規則

```
{prefix}-{normalized_account_name}-{account_id}:{role_name}
```

#### アカウント名正規化オプション

- **minimal** (デフォルト): スペース → アンダースコアのみ（大文字・ハイフンはそのまま）
- **full**: 小文字変換 + ハイフン → アンダースコア + スペース → アンダースコア + 特殊文字除去

#### 正規化例

```
元の名前: 'My Perfect-Web-Service Prod'
minimal:  'My_Perfect-Web-Service_Prod'  (デフォルト)
full:     'my_perfect_web_service_prod'
```

#### インタラクティブ選択

```
アカウント名の正規化方式を選択してください:
  1. minimal - スペース→アンダースコアのみ（大文字・ハイフンはそのまま）
  2. full    - 小文字変換 + ハイフン→アンダースコア + スペース→アンダースコア
正規化方式 (1 または 2, デフォルト: 1):
```

#### 生成機能

- **アカウント検出** - AWS CLI SSO list-accounts API を使用
- **アカウント数事前表示** - 利用可能なアカウント数を事前に表示
- **ロール検出** - AWS CLI SSO list-account-roles API を使用
- **バックアップ作成** - 設定ファイル変更前の自動バックアップ
- **プレフィックス設定** - プロファイル名のカスタマイズ可能
- **処理数制限** - 処理するアカウント数の制限設定（動的調整）
- **リージョン設定** - SSO 設定からのデフォルトリージョン自動取得

#### セキュリティ機能

- アクセストークンの自動取得と有効性確認
- セッション期限切れの自動検出
- 設定ファイルの安全な更新（バックアップ付き）

#### 実装ファイル

- `generate-sso-profiles.sh`

### 6. 自動生成プロファイルの削除

#### 機能概要

`AWS_SSO_CONFIG_GENERATOR` コメントで管理された自動生成プロファイルを安全に削除します。

#### 削除機能

- **自動検出** - 自動生成プロファイルブロックの自動検出
- **削除予定表示** - 削除対象プロファイルの事前表示
- **安全な削除** - 設定ファイルのバックアップ作成後に削除実行
- **確認プロセス** - 削除前にユーザー確認を要求
- **結果検証** - 削除後に残存プロファイルがないか確認
- **統計表示** - 削除前後のプロファイル数を表示
- **diff 表示** - Git 風の変更内容表示

#### 削除対象

```ini
# AWS_SSO_CONFIG_GENERATOR START YYYY/MM/DD HH:MM:SS
[profile example-profile]
...
# AWS_SSO_CONFIG_GENERATOR END YYYY/MM/DD HH:MM:SS
```

#### セキュリティ機能

- 設定ファイルの自動バックアップ（タイムスタンプ付き）
- ユーザーの明示的な確認が必要
- 削除結果の検証と報告

#### 実装ファイル

- `cleanup-generated-profiles.sh`

### 7. 共通ライブラリ

#### 機能概要

全スクリプトで共通利用される関数とカラー定義を提供します。

#### 提供機能

- **カラー定義** - 統一されたカラーコード（RED, GREEN, YELLOW, BLUE, NC）
- **ログ関数** - 統一されたログ出力（info, success, warning, error）
- **ユーティリティ関数** - 共通処理（設定ファイルパス取得、日時取得）
- **プロファイル統計** - 統一されたプロファイル情報表示
- **スピナー表示** - 長時間処理中の視覚的フィードバック
- **SSO 処理** - SSO 設定取得、アクセストークン管理、セッション状態確認

#### カラー定義

```bash
RED='\033[0;31m'      # エラーメッセージ
GREEN='\033[0;32m'    # 成功メッセージ
YELLOW='\033[1;33m'   # 警告メッセージ
BLUE='\033[0;34m'     # 情報メッセージ
NC='\033[0m'          # カラーリセット
```

#### ログ関数

```bash
log_info "情報メッセージ"      # 青色で表示
log_success "成功メッセージ"   # 緑色で表示
log_warning "警告メッセージ"   # 黄色で表示
log_error "エラーメッセージ"   # 赤色で表示
```

#### プロファイル統計関数

```bash
show_profile_stats()              # 基本的なプロファイル統計を表示
show_detailed_profile_summary()   # 詳細なプロファイルサマリーを表示
get_profile_stats_data()          # プロファイル統計データを取得（diff用）
show_profile_diff()               # プロファイル統計のdiff表示
```

#### スピナー表示関数

```bash
show_spinner()                    # プロセス監視型スピナー
run_with_spinner()                # コマンド実行時のスピナー表示
show_spinner_for_seconds()        # 固定時間スピナー
show_progress_spinner()           # Unicode文字使用のモダンスピナー
```

#### SSO 処理関数

```bash
get_sso_config()                  # SSO設定情報の取得（複数セッション対応）
get_access_token()                # アクセストークンの取得と有効性確認
check_sso_session_status()        # SSOセッション状態の確認と表示
```

#### 複数 SSO Session 対応機能

- **複数セッション検出** - 設定ファイル内の全 SSO Session を自動検出
- **セッション選択** - 特定セッション名の指定または最初のセッションの自動選択
- **詳細表示制限** - 大量のセッションがある場合の表示最適化
- **文字エンコーディング対応** - 日本語文字と変数の組み合わせ時の文字化け修正

#### ユーティリティ関数

```bash
get_config_file()        # AWS設定ファイルパスを取得
get_current_datetime()   # 現在日時を取得（YYYY/MM/DD HH:MM:SS）
get_current_date()       # 現在日付を取得（YYYY/MM/DD）
```

#### 使用方法

```bash
# 各スクリプトの冒頭で読み込み
source "$(dirname "$0")/common.sh"
```

#### 実装ファイル

- `common.sh`

## 使用方法

### 全体セットアップ

```bash
./setup-aws-sso.sh
```

### 個別実行

```bash
# ツール確認
./check-tools.sh

# AWS設定確認
./check-aws-config.sh

# SSO設定確認
./check-sso-config.sh                    # 全セッション表示、最初のセッション使用
./check-sso-config.sh session-name       # 特定セッション確認
./check-sso-config.sh --help             # ヘルプ表示

# プロファイル分析
./check-sso-profiles.sh                     # 全プロファイルの分析
./check-sso-profiles.sh analyze             # 全プロファイルの分析
./check-sso-profiles.sh auto                # 自動生成プロファイル詳細（10件）
./check-sso-profiles.sh auto --all          # 自動生成プロファイル詳細（全件）
./check-sso-profiles.sh manual              # 手動管理プロファイル詳細（10件）
./check-sso-profiles.sh manual --all        # 手動管理プロファイル詳細（全件）

# プロファイル自動生成
./generate-sso-profiles.sh                  # インタラクティブ自動生成

# 自動生成プロファイル削除
./cleanup-generated-profiles.sh             # 自動生成プロファイルの削除
```

## 重要な前提条件

### AWS SSO コマンドのリージョン要件

AWS SSO 関連の全てのコマンドは**リージョン設定が必須**です：

- `aws sso list-accounts`
- `aws sso list-account-roles`
- その他の AWS SSO API 呼び出し

#### 設定方法

```bash
# 環境変数による設定（推奨）
export AWS_REGION=ap-northeast-1

# AWS CLI 設定による設定
aws configure set region ap-northeast-1
```

#### 確認方法

```bash
# 詳細なリージョン設定確認
./check-aws-config.sh

# 現在の設定値確認
aws configure get region
```

## 技術仕様

### 共通仕様

- **Shebang**: `#!/usr/bin/env bash` - ポータビリティ重視
- **エラーハンドリング**: `set -e` - エラー時即座終了
- **共通ライブラリ**: `source common.sh` - 統一された UI/UX 機能
- **カラー出力**: ANSI エスケープシーケンス使用
- **ログレベル**: info、success、warning、error
- **統一 UI**: 全スクリプトで統一されたログ関数とカラー表示
- **簡潔表示**: 長大な設定内容の代わりにサマリー情報を表示

### 複数 SSO Session 対応

- **正規表現パターン**: `^\[sso-session[[:space:]]*([^]]+)\]` - スペース有無に対応
- **セッション検出**: 設定ファイル全体をスキャンして全セッションを検出
- **表示制限**: 5 個を超える場合の省略表示で可読性を確保
- **セッション選択**: コマンドライン引数または自動選択による柔軟な運用

### 文字エンコーディング対応

- **問題**: 日本語文字と変数を含む文字列の直接渡しで文字化け発生
- **解決策**: 変数に文字列を格納してからログ関数に渡すことで回避
- **実装例**:

  ```bash
  # 問題のあったコード
  log_info "AWS SSO設定の確認中（セッション: $session_name）..."

  # 修正後のコード
  local message="AWS SSO設定の確認中（セッション: ${session_name}）..."
  log_info "$message"
  ```

### セキュリティ考慮

- アクセストークンは表示せず存在確認のみ
- 設定ファイルのバックアップ作成
- 一時ファイルの安全な処理
- 複数セッション環境での適切な権限分離

### 互換性

- macOS 標準 date コマンド対応
- GNU date (gdate) 対応
- 異なる Unix 系システムでの動作保証
- 複数 SSO Session 環境での動作保証

## 開発履歴

### v1.0 - 基本機能実装

- 必要ツール確認機能
- AWS 設定ファイル確認機能
- SSO 設定確認機能
- 手動プロファイル管理機能

### v1.1 - 自動生成機能追加

- AWS CLI SSO API を使用した自動プロファイル生成機能
- アカウント名正規化オプション（full/minimal）
- 一括処理コメントマーカー（AWS_SSO_CONFIG_GENERATOR）
- 日時情報の詳細化（YYYY/MM/DD HH:MM:SS 形式）
- 文字数制限の撤廃（アカウント名の完全保持）

### v1.2 - 管理機能強化

- 自動生成プロファイル削除機能（cleanup-generated-profiles.sh）
- 共通ライブラリの導入（common.sh）
- コード重複の削除（約 150 行以上の削減）
- 手動管理と自動生成の分離（フィルタ機能改善）
- デフォルトリージョンの SSO 設定連携

### v1.3 - 複数 SSO Session 対応

- 複数 SSO Session 環境での動作改善
- SSO Session 詳細表示の制限機能（最初の 5 個まで表示）
- 特定 SSO Session 指定機能の追加
- 文字エンコーディング問題の修正
- 共通ライブラリの SSO 処理機能強化

### v1.4 - プロファイル分析機能追加

- プロファイル分析スクリプト（check-sso-profiles.sh）の追加
- 自動生成・手動管理プロファイルの分類・統計表示
- 詳細表示機能（デフォルト 10 件、--all オプションで最大 300 件）
- 表形式でのプロファイル情報表示（column 使用）
- 手動プロファイル管理機能の廃止（分析機能に統合）

### v1.5 - ツール名変更とブランディング統一

- ツール名を「AWS SSO Profile Generator」に変更
- プロファイル生成機能を中心とした説明に調整
- 各スクリプトのヘッダーコメント統一
- メインセットアップスクリプトの表示メッセージ更新

### v1.6 - リージョン設定確認機能強化

- AWS SSO コマンド要件に対応したリージョン設定確認機能追加
- 環境変数（AWS_REGION、AWS_DEFAULT_REGION）とAWS CLI設定の包括的確認
- 設定一貫性チェックと不整合時の警告機能
- 実効リージョン表示とエラー予防機能
- スピナー表示問題の修正（psコマンド依存の解消）
- バックグラウンド実行時の変数継承問題の解決

### v1.7 - プロファイル品質チェック機能追加

- 重複プロファイル自動検出機能の追加
- 重複プロファイルの詳細分析機能（`duplicates`コマンド）
- BSD/GNU grep互換性問題の解決
- 安全な数値処理とエラーハンドリングの強化
- SSO ログインメッセージの改善（セッション名・デバイスコード対応）
- ファイル名の簡素化（`check-awssso-config.sh` → `check-sso-config.sh`）
- タイムゾーン処理の改善（GNU date検出の最適化）

### 設計変更履歴

1. **コメントマーカーの統一**: `auto-generated` → `aws-sso-config-generator` → `AWS_SSO_CONFIG_GENERATOR`
2. **コメント配置の最適化**: 個別プロファイル毎 → 一括処理の開始・終了時のみ
3. **日時形式の拡張**: `YYYY/MM/DD` → `YYYY/MM/DD HH:MM:SS`
4. **アカウント名処理の改善**: 20 文字制限撤廃、完全な名前を保持
5. **コード共通化**: カラー設定・ログ関数を`common.sh`に集約
6. **管理対象の分離**: 手動管理プロファイルと自動生成プロファイルの独立管理
7. **複数 SSO Session 対応**: 単一セッション前提 → 複数セッション環境での動作改善
8. **表示最適化**: 全セッション詳細表示 → 最初の 5 個まで詳細表示（6 個以上は省略）
9. **文字エンコーディング修正**: 日本語文字と変数組み合わせ時の文字化け解決
10. **プロファイル管理の再設計**: 手動プロファイル管理 → 分析・一覧表示機能に統合
11. **機能統合**: 個別管理機能 → 包括的な分析・表示機能への統合
12. **ツール名統一**: 「AWS SSO 設定管理ツール」→「AWS SSO Profile Generator」
13. **ブランディング統一**: プロファイル生成を中心とした一貫したメッセージング
14. **リージョン設定確認強化**: AWS SSO コマンド要件に対応した包括的確認機能
15. **互換性問題解決**: psコマンド依存とバックグラウンド実行の問題修正
16. **重複プロファイル検出**: 設定品質向上のための重複チェック機能追加
17. **BSD/GNU grep対応**: クロスプラットフォーム互換性の向上
18. **ユーザビリティ改善**: ファイル名簡素化とメッセージ品質向上

### アーキテクチャ改善

- **保守性向上**: 共通機能の一元管理により変更コストを削減
- **一貫性確保**: 全スクリプトで統一された UI/UX
- **拡張性向上**: 新スクリプト追加時の開発効率向上
- **コード品質**: 重複コード削除による可読性とメンテナンス性の向上
- **スケーラビリティ**: 複数 SSO Session 環境での効率的な動作
- **ユーザビリティ**: 大量のセッション情報の見やすい表示
- **国際化対応**: 文字エンコーディング問題の解決による多言語対応
- **機能統合**: プロファイル管理から分析・表示への機能統合による使いやすさの向上
- **情報可視化**: 自動生成・手動管理プロファイルの明確な分類と統計表示
- **ブランディング統一**: 「Profile Generator」として一貫したツール名とメッセージング
- **目的明確化**: プロファイル生成機能を中心とした明確な価値提案
- **要件対応**: AWS SSO コマンドのリージョン要件に対応した事前確認機能
- **エラー予防**: 設定不備による実行時エラーの事前検出と解決ガイダンス
- **互換性向上**: 異なる環境での安定動作を実現する技術的改善
- **品質保証**: 重複プロファイル検出による設定品質の向上
- **クロスプラットフォーム**: BSD/GNU grep差異の解決による安定性向上
- **ユーザー体験**: 直感的なファイル名とメッセージによる使いやすさの向上
