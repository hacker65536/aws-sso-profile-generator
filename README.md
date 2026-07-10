# aws-sso-profiles — desired-state CLI

`~/.aws/config` の AWS SSO プロファイルを、宣言的な `.aws-sso-profiles.yaml` を single source of truth として **plan / apply**（Terraform 流・冪等・構造化出力・exit code）で管理する Go 製 CLI です。

![aws-sso-profiles demo](demo/aws-sso-profiles.gif)

> `--help` → `validate` → `plan` → `apply`（冪等）→ drift 検出と自己修復 → `cleanup` を通しで録画したデモです（再生成: [`make demo`](demo/README.md)）。

> ℹ️ かつて存在した Bash 版（`generate-sso-profiles.sh` ほか）は本 Go 実装に全面移行し、**撤去済み**です（履歴は git と [CHANGELOG.md](CHANGELOG.md) を参照）。

> 📖 詳細な**要件**（目的・スコープ・不変条件・region 2 概念・ユーザーフロー）は [docs/requirements.md](docs/requirements.md)、**アーキテクチャ / 実装**（Phase A–E・パッケージ責務・§0 冪等性・テスト戦略）は [docs/implementation.md](docs/implementation.md) を参照してください。

## 特徴

- **宣言的**: 対話 5 問＋フィルタを `config.yaml` に圧縮。判断がファイルに残る。
- **desired-state**: `plan` で差分（added / removed / **changed** / unchanged）と **drift**（手編集）を可視化、`apply` は**冪等**（同一 config + 同一インベントリなら no-op・バイト不変）。
- **AI/自動化フレンドリ**: `--output json`、Terraform 流 exit code（`0`=差分なし / `2`=差分あり or drift / `1`=エラー）、埋め込み JSON Schema（`schema` コマンド）。
- **依存レス**: AWS SDK for Go v2 直呼び（`aws` CLI / jq 不要）、単一バイナリ。

## 前提

- 対象は IAM Identity Center の **organization instance**（1 Organization = 1 インスタンス。account instance は非対応）。
- `[sso-session <name>]` を `~/.aws/config` に用意し、**`aws sso login --sso-session <name>` 済み**であること（本ツールは cache 済みトークンを読むだけで、OIDC/login は行わない）。
  - ⚠ ログイン自体には **AWS CLI v2** が必要（本ツールは AWS SDK for Go v2 直呼びだが、トークン取得の `aws sso login` は AWS CLI に委譲するため）。
- SSO API リージョンは `[sso-session].sso_region` を権威として使用（ambient env/default には流されない）。

## インストール / ビルド

### Homebrew

```bash
brew install hacker65536/tap/aws-sso-profiles
# もしくは
brew tap hacker65536/tap
brew install aws-sso-profiles
```

### ソースからビルド

```bash
make build          # ./aws-sso-profiles を生成 (version は git describe 由来)
# もしくは
go build -o aws-sso-profiles ./cmd/aws-sso-profiles
```

## クイックスタート

```bash
# 1) 設定ウィザード（管理者提供の seed を入力 → config と [sso-session] を用意）
aws-sso-profiles init \
  --session my-sso --start-url https://my.awsapps.com/start --region us-east-1 --prefix awssso

# 2) ログイン（ブラウザ・委譲）
aws sso login --sso-session my-sso

# 3) 差分確認 → 適用
aws-sso-profiles plan          # exit 2 なら差分あり
aws-sso-profiles apply         # 冪等。管理ブロックのみ書換
```

## サブコマンド

| コマンド | 役割 |
|---|---|
| `init` | 対話ウィザード（**対話はここだけ**）。`.aws-sso-profiles.yaml` 生成 + `[sso-session]` seed 書込 |
| `list` | 到達可能な accounts×roles を列挙（`--output json` でガバナンス成果物） |
| `plan` | desired と現状の差分 + drift を表示（非破壊、差分/drift で exit 2） |
| `apply` | 冪等適用。管理ブロックのみ書換（バックアップ後） |
| `validate` | config を JSON Schema + 意味検証 + org 照合 |
| `schema` | 埋め込み JSON Schema を出力（editor / AI 用） |
| `cleanup` | 管理ブロック除去（`--session <name>` で特定セッションのみ、`--yes` で確認スキップ） |
| `check` | `analyze` / `auto` / `manual` / `duplicates`（managed vs manual の集計） |
| `completion` | bash / zsh / fish 補完スクリプト生成（cobra 標準） |

共通フラグ: `-c/--config`（既定 `./.aws-sso-profiles.yaml`）、`-o/--output human|json`、`-p/--parallel N`（既定 8, adaptive retry 併用）、`--login`（失効時に `aws sso login` を代行）、`--cache`（opt-in ディスクキャッシュ）、`--refresh-cache`。

## config スキーマ（`.aws-sso-profiles.yaml`）

```yaml
# 1 org = 1 config = 1 AWS_CONFIG_FILE = 1 prefix（org 分離境界）
aws_config_file: ~/.aws/config        # 任意（env AWS_CONFIG_FILE 相当）
sso:
  session: my-sso                     # [sso-session my-sso]; 省略時はファイル先頭順の最初
  start_url: https://my.awsapps.com/start  # 任意・org 取り違え防止の照合に使用
  region: us-east-1                   # 任意（SSO API region の seed）
defaults:
  prefix: awssso                      # ★org 識別子。org ごとに一意
  normalize: minimal                  # minimal | full
  template: "{prefix}-{account_name}-{account_id}:{role}"
  settings:                           # 各 profile に注入する既定値（任意キー可）
    region: us-east-1                 # 未指定なら ambient(env/[default]) に fallback
    output: json
    cli_pager: ""
    # duration_seconds: "43200"       # AWS CLI の任意キーも設定可（値は文字列で）
select:
  include:
    - { account: "*", role: "*" }     # 空 = 全件
  exclude:
    - { account: "*sandbox*", role: "*" }
overrides:
  - match: { account: "prod-*", role: "*" }
    settings:                         # マッチした profile に上書き/追加マージ
      region: ap-northeast-1
```

テンプレ変数: `{prefix}` `{account_name}`（正規化後） `{account_id}` `{role}`（生）。未知変数や、名前が衝突するテンプレは `validate`/`plan` が拒否します。

**profile settings**: `defaults.settings` は各 profile に書く key/value（`region` / `output` / `cli_pager` や任意の AWS CLI キー）。値は文字列（数値は `"43200"` のようにクォート）。`overrides[].settings` がマッチする profile に上書きマージ（後勝ち）。識別子キー（`sso_session` / `sso_account_id` / `sso_role_name`）はツール占有で、settings に書くと `validate` エラー。レンダリングは識別子キー→settings をキー名ソートの順（決定論）。

## マルチ組織（org）

分離境界は **`AWS_CONFIG_FILE` を分けること**。org ごとに config を用意し `-c` で切り替えます。管理ブロックは **prefix スコープ**（`# AWS_SSO_CONFIG_GENERATOR:<prefix> START/END`）なので、同一ファイルに複数 org を同居させても互いのブロック・手書きプロファイルを侵しません。

```bash
aws-sso-profiles apply -c work.yaml   # prefix: awssso（業務用）
aws-sso-profiles apply -c poc.yaml    # prefix: awspoc（検証用）
```

## 冪等性と provenance

- apply の no-op 判定は **plan ベース**（desired の profile 集合が一致すれば書き込まない）。バージョンや provenance の差では書き換わりません。
- 管理ブロック先頭に `# managed by aws-sso-profiles <version> — do not edit; config-sha256=<hash>` を刻み、監査で由来を追えます（冪等判定からは除外）。
- 揮発する日時は START/END マーカー行にのみ置きます。

## Tips: fzf でプロファイル選択

生成したプロファイルは [fzf](https://github.com/junegunn/fzf) と組み合わせると選択が快適です。prefix（既定 `awssso`）で本ツール由来のプロファイルだけ絞り込めます。

```bash
# ~/.bashrc / ~/.zshrc に追加
aws_profile() {
    local p
    p=$(aws configure list-profiles | grep '^awssso-' | fzf --prompt='AWS Profile > ') || return
    [ -n "$p" ] && export AWS_PROFILE="$p" && echo "AWS_PROFILE=$p"
}
```

## 開発

```bash
make check     # gofmt -l / go vet / go test -race（CI 相当のローカルゲート）
make vuln      # govulncheck
go test ./... -run TestScripts ./cmd/...   # testscript E2E
```
