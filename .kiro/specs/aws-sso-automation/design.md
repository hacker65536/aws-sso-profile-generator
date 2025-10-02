# Design Document

## Overview

AWS SSO設定管理ツールは、AWS Single Sign-On (SSO) の設定を段階的に確認・作成・管理するためのBashスクリプト群です。このツールは、モジュール性と統一性を重視した設計により、各機能を独立して実行可能でありながら、統一されたユーザーエクスペリエンスを提供します。

## Architecture

### Script Architecture

```
setup-aws-sso.sh (Main Orchestrator)
├── check-tools.sh (Tool Verification)
├── check-aws-config.sh (Config File Analysis)
├── check-awssso-config.sh (SSO Configuration Check)
├── manage-sso-profiles.sh (Interactive Profile Management)
└── generate-sso-profiles.sh (Automated Profile Generation)
```

### Design Principles

1. **統一性 (Consistency)**: 全スクリプトで統一されたUI・ログ出力・エラーハンドリング
2. **簡潔性 (Simplicity)**: 重要な情報のみを抽出した見やすい表示
3. **モジュール性 (Modularity)**: 各スクリプトが独立して実行可能
4. **拡張性 (Extensibility)**: 新機能追加時の一貫した実装パターン

## Components and Interfaces

### 1. Main Orchestrator (setup-aws-sso.sh)

**Purpose**: 全ステップを順次実行するメインスクリプト

**Interface**:
```bash
./setup-aws-sso.sh
```

**Responsibilities**:
- 各個別スクリプトの順次実行
- エラーハンドリングと実行フロー制御
- 統一されたログ出力

### 2. Tool Verification (check-tools.sh)

**Purpose**: 必要ツールの存在・バージョン確認

**Interface**:
```bash
./check-tools.sh
```

**Checked Tools**:
- Bash v4以上 (連想配列機能のため)
- AWS CLI v2
- jq (JSON処理)
- column (表示整形)

**Output Format**:
- ツール名、バージョン、ステータスの表形式表示
- 不足ツールのインストール方法案内

### 3. AWS Configuration Analysis (check-aws-config.sh)

**Purpose**: AWS設定ファイルの確認とサマリー表示

**Interface**:
```bash
./check-aws-config.sh
```

**Configuration Sources**:
- 環境変数 `AWS_CONFIG_FILE`
- デフォルトパス `$HOME/.aws/config`

**Summary Information**:
- SSO セッション数
- プロファイル数
- 管理対象プロファイル数
- SSO セッション名一覧
- 管理対象プロファイル名一覧

### 4. SSO Configuration Check (check-awssso-config.sh)

**Purpose**: SSO設定とセッション状態の確認

**Interface**:
```bash
./check-awssso-config.sh
```

**Configuration Validation**:
```ini
[sso-session {session-name}]
sso_region = {region}
sso_start_url = {url}
sso_registration_scopes = sso:account:access
```

**Session Status Check**:
- `~/.aws/sso/cache/` 内のキャッシュファイル検索
- SSO Start URLを含むJSONファイルの特定
- アクセストークンと有効期限の取得
- 有効期限のローカルタイムゾーン変換

### 5. Interactive Profile Management (manage-sso-profiles.sh)

**Purpose**: SSOプロファイルの対話的管理

**Interface**:
```bash
./manage-sso-profiles.sh [create|check <name>|list|update <name>]
```

**Profile Format**:
```ini
# AWS SSO CONFIG {customization_name} START YYYY/MM/DD
[profile {profile_name}]
sso_session = {session_name}
sso_account_id = {account_id}
sso_role_name = {role_name}
region = {region}
output = {output_format}
cli_pager = 
# AWS SSO CONFIG {customization_name} END YYYY/MM/DD
```

**Operations**:
- **create**: インタラクティブな新規プロファイル作成
- **check**: 個別プロファイルの表示
- **list**: 全管理対象プロファイルの一覧表示
- **update**: 既存プロファイルの安全な更新

### 6. Automated Profile Generation (generate-sso-profiles.sh)

**Purpose**: AWS CLI SSO APIを使用した自動プロファイル生成

**Interface**:
```bash
./generate-sso-profiles.sh [--prefix PREFIX] [--normalization full|minimal]
```

**Profile Naming Convention**:
```
{prefix}-{account-name}-{account-id}-{role-name}
```

**Account Name Normalization Options**:
- **full**: アカウント名をそのまま使用
- **minimal**: アカウント名を短縮形に変換

## Data Models

### Profile Configuration

```bash
# Profile structure
declare -A profile=(
    ["name"]="profile-name"
    ["sso_session"]="session-name"
    ["sso_account_id"]="123456789012"
    ["sso_role_name"]="RoleName"
    ["region"]="us-east-1"
    ["output"]="json"
)
```

### SSO Session Configuration

```bash
# SSO Session structure
declare -A sso_session=(
    ["name"]="session-name"
    ["sso_region"]="us-east-1"
    ["sso_start_url"]="https://example.awsapps.com/start"
    ["sso_registration_scopes"]="sso:account:access"
)
```

### Tool Information

```bash
# Tool check result
declare -A tool_info=(
    ["name"]="tool-name"
    ["version"]="version-string"
    ["status"]="OK|MISSING|VERSION_ERROR"
    ["path"]="/path/to/tool"
)
```

## Error Handling

### Error Handling Strategy

1. **Fail Fast**: `set -euo pipefail` を使用してエラー時即座終了
2. **Clear Messages**: 明確で実行可能なエラーメッセージ
3. **Resource Cleanup**: `trap` を使用した確実なクリーンアップ
4. **Backup Creation**: 設定ファイル変更前のバックアップ作成

### Error Categories

```bash
# Error levels
ERROR_TOOL_MISSING=1
ERROR_CONFIG_NOT_FOUND=2
ERROR_SSO_CONFIG_INVALID=3
ERROR_SESSION_EXPIRED=4
ERROR_PROFILE_EXISTS=5
ERROR_AWS_API_FAILURE=6
```

### Error Message Format

```bash
log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    if [[ $# -gt 1 ]]; then
        echo -e "${YELLOW}[SUGGESTION]${NC} $2" >&2
    fi
}
```

## Testing Strategy

### Unit Testing Approach

各スクリプトは独立してテスト可能な設計とし、以下の観点でテストを実施：

1. **Tool Detection**: 各ツールの存在確認とバージョン検証
2. **Config Parsing**: AWS設定ファイルの正しい解析
3. **Profile Management**: プロファイルの作成・更新・削除操作
4. **Error Handling**: 各種エラー条件での適切な動作
5. **Output Format**: 出力形式の一貫性

### Integration Testing

1. **End-to-End Flow**: メインスクリプトによる全体フロー
2. **Cross-Platform**: macOS、Linux環境での動作確認
3. **AWS CLI Integration**: 実際のAWS CLI コマンドとの連携

### Test Environment Setup

```bash
# Test environment variables
export AWS_CONFIG_FILE="./test/fixtures/config"
export AWS_SHARED_CREDENTIALS_FILE="./test/fixtures/credentials"

# Mock AWS CLI responses
export AWS_CLI_MOCK_MODE=true
```

## Security Considerations

### Sensitive Information Handling

1. **No Token Display**: アクセストークンは表示せず存在確認のみ
2. **Secure File Operations**: 設定ファイルの適切な権限管理
3. **Temporary File Cleanup**: 一時ファイルの確実な削除

### Configuration File Security

```bash
# Secure backup creation
backup_config() {
    local config_file="$1"
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$config_file" "$backup_file"
    chmod 600 "$backup_file"
}
```

## Platform Compatibility

### macOS Compatibility

- macOS標準の`date`コマンド対応
- BSD系コマンドとの互換性確保

### Linux Compatibility

- GNU coreutils対応
- 各種ディストリビューション（Ubuntu、CentOS、RHEL）での動作確認

### Cross-Platform Date Handling

```bash
# Cross-platform date conversion
convert_timestamp() {
    local timestamp="$1"
    if command -v gdate >/dev/null 2>&1; then
        gdate -d "@$timestamp" '+%Y-%m-%d %H:%M:%S %Z'
    else
        date -r "$timestamp" '+%Y-%m-%d %H:%M:%S %Z'
    fi
}
```