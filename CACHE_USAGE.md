# AWS SSO Profile Generator - キャッシュ機能使用方法

## 概要

AWS SSO Profile Generatorは、AWS SSO API呼び出しの結果をキャッシュして処理速度を向上させる機能を提供します。

## キャッシュ機能の利点

- **処理速度向上**: 2回目以降の実行が大幅に高速化
- **API呼び出し削減**: AWS APIの呼び出し回数を削減してレート制限を回避
- **ネットワーク負荷軽減**: ローカルキャッシュによりネットワーク通信を削減

## キャッシュ対象データ

1. **アカウント一覧** (`aws sso list-accounts`)
2. **ロール一覧** (`aws sso list-account-roles`)
3. **セッションメタデータ** (キャッシュ管理情報)

## キャッシュファイル構造

```
.aws-sso-cache/
├── accounts-{session_name}-{hash}.json     # アカウント一覧
├── roles-{account_id}-{hash}.json          # ロール一覧
└── metadata.json                           # メタデータ
```

## 自動キャッシュ機能

### 有効期限

- **デフォルト**: 1時間
- **設定変更**: `common.sh`の`CACHE_EXPIRY_HOURS`変数で調整可能

### キャッシュ動作

1. **初回実行**: AWS APIを呼び出してデータを取得し、キャッシュに保存
2. **2回目以降**: キャッシュから高速読み込み
3. **期限切れ時**: 自動的にAWS APIを再呼び出し

## 手動キャッシュ管理

### キャッシュ統計の確認

```bash
./test/test-cache.sh show-stats
```

出力例:
```
ℹ️  キャッシュ統計:
  キャッシュディレクトリ: .aws-sso-cache
  総ファイル数: 3
  アカウントキャッシュ: 1
  ロールキャッシュ: 1
  メタデータファイル: 1
  有効期限: 1時間
  期限切れファイル: 0
```

### 全キャッシュの削除

```bash
./test/test-cache.sh clear-all
```

### 特定セッションのキャッシュ削除

```bash
./test/test-cache.sh clear-session
```

## 実際の使用例

### 1. 通常のプロファイル生成（キャッシュ利用）

```bash
# 1回目: AWS APIを呼び出し、キャッシュに保存
./generate-sso-profiles.sh

# 2回目以降: キャッシュから高速読み込み
./generate-sso-profiles.sh
```

### 2. キャッシュ機能のテスト

```bash
# デモンストレーション実行
./test/test-cache.sh demo

# アカウントキャッシュのテスト
./test/test-cache.sh test-accounts

# ロールキャッシュのテスト
./test/test-cache.sh test-roles
```

## パフォーマンス比較

### 初回実行（キャッシュなし）
- アカウント取得: ~2-3秒
- ロール取得: ~1-2秒 × アカウント数
- 合計: 大規模環境で数十秒

### 2回目以降（キャッシュ利用）
- アカウント取得: ~0.1秒
- ロール取得: ~0.1秒 × アカウント数
- 合計: 数秒以内

## トラブルシューティング

### キャッシュが効かない場合

1. **権限確認**: `.aws-sso-cache`ディレクトリの書き込み権限
2. **ディスク容量**: 十分な空き容量があるか確認
3. **セッション変更**: SSOセッションが変更された場合はキャッシュクリア

### 古いデータが表示される場合

```bash
# キャッシュを削除して最新データを取得
./test/test-cache.sh clear-all
./generate-sso-profiles.sh
```

### デバッグモード

```bash
# デバッグ情報を表示
DEBUG=1 ./generate-sso-profiles.sh
DEBUG=1 ./test/test-cache.sh demo
```

## 設定のカスタマイズ

### キャッシュ有効期限の変更

`common.sh`を編集:

```bash
# デフォルト: 1時間
CACHE_EXPIRY_HOURS=1

# 例: 30分に変更
CACHE_EXPIRY_HOURS=0.5

# 例: 6時間に変更
CACHE_EXPIRY_HOURS=6
```

### キャッシュディレクトリの変更

`common.sh`を編集:

```bash
# デフォルト
CACHE_DIR=".aws-sso-cache"

# 例: 別の場所に変更
CACHE_DIR="$HOME/.aws-sso-profile-cache"
```

## セキュリティ考慮事項

- **アクセストークン**: キャッシュファイルにはアクセストークンは保存されません
- **機密情報**: アカウントIDとロール名のみがキャッシュされます
- **ファイル権限**: キャッシュファイルは適切な権限で作成されます

## 注意事項

- キャッシュは**ローカルファイル**として保存されます
- **複数セッション**環境では、セッションごとに個別のキャッシュが作成されます
- **AWS設定変更**後は、キャッシュクリアを推奨します
- **CI/CD環境**では、キャッシュディレクトリを適切に管理してください

## 関連ファイル

- `lib/common.sh` - キャッシュ機能の実装
- `generate-sso-profiles.sh` - キャッシュ利用の実装
- `test/test-cache.sh` - キャッシュ機能のテストスクリプト
- `spec.md` - キャッシュ機能の仕様書