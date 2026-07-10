# 実装ドキュメント — aws-sso-profiles（Go 版 / desired-state CLI）

> このドキュメントは **どう作られているか**（how / アーキテクチャ）を扱います。
> **何を・なぜ**（要件）は [requirements.md](requirements.md) を参照してください。
> ここに書く事実はすべて実コード（`cmd/` / `internal/*`）に整合させています。

## 1. アーキテクチャ全体像（Phase A–E）

処理は 5 フェーズに分かれ、**決定論的コア = Phase D（インベントリ取得）+ E（plan / apply）**、
それ以外（A / B / C）は環境由来 or 人間 + `aws` CLI に委譲する「境界」です。柔軟性は
**① `config.yaml` ② 委譲された bootstrap** の 2 か所だけに集約します。

```
Phase A  Region 確定（2 系統を分離）
   ① SSO API region = [sso-session].sso_region 専管（portal API を叩く先。必須・固定 pin）
   ② profile region = 各プロファイルに書く region = defaults.settings.region → 無ければ ambient に fallback
       ambient region = AWS_REGION > AWS_DEFAULT_REGION > [default].region
Phase B  sso-session 設定（bootstrap・人間委譲）
   aws configure sso-session or init → ~/.aws/config に [sso-session NAME]
Phase C  Login（人間・ブラウザ・委譲）
   aws sso login --sso-session NAME → ~/.aws/sso/cache に accessToken + expiresAt
Phase D  Inventory 取得（自動・決定論的コア）
   [sso-session] 読取 → token 読取（期限チェック、失効なら案内 exit1）
   → ListAccounts(paginate) → 各 account で ListAccountRoles(paginate, errgroup 並列)
Phase E  desired-state → plan / apply（決定論的コア）
   desired = accounts × roles ∩ selector, 命名(template) + settings
   current = 管理ブロック → diff(added / removed / changed / unchanged) + drift
   apply かつ差分あり → backup → 管理ブロック splice 書換 → 構造化出力 + exit(0/2/1)
```

### 柔軟性マップ

| Phase | 部分 | 区分 | 決めるもの |
|---|---|---|---|
| A | ambient region 決定 | 固定ロジック / 値は環境依存 | `AWS_REGION` > `AWS_DEFAULT_REGION` > `[default].region` |
| A | profile に書く `region =` | 柔軟(config) | `defaults.settings.region`（無ければ ambient）+ overrides |
| B | `[sso-session]` 作成 | 人間・wizard（委譲） | `aws configure sso-session` / `init` |
| B | どの session を使うか | 柔軟(config) | `sso.session`、未指定はファイル先頭順 |
| C | login / token 取得 | 人間・ブラウザ（委譲、read-only 消費） | `aws sso login` |
| C | 失効時 | 固定 / opt-in で委譲 | 既定 = 案内のみ。`--login` opt-in で代行 |
| D | ListAccounts / ListAccountRoles | 固定・決定論 | token（＝自分の IDC 権限） |
| E | 対象の絞り込み | 柔軟(config) | `select.include/exclude` |
| E | 命名 / settings | 柔軟(config) | `template` + `normalize` + `prefix` + `settings` |
| E | diff / splice / backup / marker | 固定・byte 安定 | plan / render エンジン |

**設計原則**: 「コア = 決定論（token + config → profiles の純関数）」「境界(A/B/C) = 委譲、既定は
read-only / 案内のみ、能動介入は明示 opt-in」。

## 2. パッケージ構成と責務

実際の構成は `cmd/aws-sso-profiles/` の単一 `main.go` と `internal/*` です
（accounts × roles モデルは独立パッケージではなく `internal/ssoapi` に同居。`internal/inventory` は存在しません）。

| パッケージ | 責務 |
|---|---|
| `cmd/aws-sso-profiles/main.go` | cobra 配線・全サブコマンドを**関数で定義**（`initCmd` / `listCmd` / `planCmd` / `applyCmd` / `validateCmd` / `schemaCmd` / `cleanupCmd` / `checkCmd`）し `rootCmd()` に登録。persistent flag `--config` / `--output`。`plan` は `NeedsApply()` で `exitCode = 2`。`completion` は cobra 自動提供 |
| `internal/config` | `.aws-sso-profiles.yaml` を `sigs.k8s.io/yaml` で load、`//go:embed schema.json` を `santhosh-tekuri/jsonschema/v6` で検証、defaults 適用 + 意味検証。`Parse` / `Schema` / `ResolvedDefaultSettings` / `CrossCheck`（org 照合） / `checkSettings`（識別子キー拒否） |
| `internal/plan` | desired-state エンジン。`BuildDesired`（inventory → selector → overrides → naming, 名衝突検出） / `Diff`（`Added` / `Removed` / `Changed` / `Unchanged`） / `detectDrift`（管理ブロック内の手編集） / `Counts` / `HasDiff` / `HasDrift` / `NeedsApply` / `IdentityKeys` |
| `internal/awsconfig` | `~/.aws/config` を手書き行スキャナで読み書き。prefix スコープ・マーカー splice（`SpliceBlock` / `RemoveBlock` / `ExtractBlockBody` / `findBlockRange` 均衡チェック） / `[sso-session]` パース（`ParseSSOSessions` / `SelectSSOSession`） / `AmbientRegion` / `EnsureSSOSession` / `ParseProfiles` / `AllProfileNames` / `ManagedProfileNames` / `Backup` + `rotateBackups` / `WriteAtomic` / `NowStamp` |
| `internal/render` | 管理ブロック本文の決定論バイト列生成（§0）。`Body`（profile 名ソート → provenance ヘッダ → 識別子キー固定順 → settings キーソート） / `Header` / `Provenance{Version, ConfigSHA}` |
| `internal/ssoapi` | 匿名 `sso.New(sso.Options{Region, Retryer})`（region pin + `retry.NewAdaptiveMode`）。`ListAccounts` / `ListAccountRoles` paginator、`FetchInventory` は errgroup + `SetLimit` で fan-out（アカウント順・role 名順にソート）。`SSOLister` interface で fake 可能。accounts × roles モデル `Account` / `AccountRoles` もここ |
| `internal/ssotoken` | token cache の read-only 消費。`Load`（`ssocreds.StandardCachedTokenFilepath` → startUrl 走査 + 最新 mtime fallback） / `Expired` / `LoginHint`。login / OIDC は呼ばない |
| `internal/selector` | include / exclude glob（`*` / `?` を regexp にコンパイル）+ per-match override。`Selected` / `Settings` / `globToRegexp` |
| `internal/naming` | ASCII 正規化（`Minimal` / `Full`, byte 反復）+ テンプレ展開。`Normalize` / `ValidateTemplate` / `Expand` / `ProfileName` / `DefaultTemplate` |
| `internal/diskcache` | opt-in TTL キャッシュ（既定 OFF）。key = `md5(start_url)[:8]`、TTL = env `CACHE_EXPIRY_HOURS`（既定 24）、dir = env `CACHE_DIR`（既定 `.aws-sso-cache`）。`Load` / `Save`（atomic） / `Clear` |
| `internal/app` | オーケストレーション。`Load`（config + awsconfig + session 解決、`configSHA` = sha256[:12]） / `Inventory`（`ASP_FAKE_INVENTORY` テスト hook / diskcache / expired-token login） / `Plan` / `Apply` / `Cleanup` / `CleanupSession` |

`apply` = `plan` + `render` + `awsconfig` splice。`cleanup` = 空ブロック splice（`--session` フィルタ）。
plan / apply / list は同一エンジンで JSON 出力・exit code を共有します。

## 3. 主要ライブラリ決定と理由

- **`~/.aws/config` 書換 = ini ライブラリ不使用の手書き行 splice**: head + block + tail を verbatim 保持。
  ini 系ライブラリは空白 / コメント / 順序を正規化してしまい、不変条件（マーカー・キー順）と byte 安定
  冪等性を壊すため使わない。
- **トークン = SDK のパス解決 + 自前デコード**: `ssocreds.StandardCachedTokenFilepath(session)`（session 名の
  SHA1）でパスを算出し、JSON を自前デコード。`NewSSOTokenProvider` は refresh 目的の network 呼び出しを
  するため使わない。見つからなければ startUrl 走査 + 最新 mtime の fallback。
- **SSO Client**: `sso.New(sso.Options{Region: ssoRegion, Retryer: ...})` を匿名生成し、`AccessToken` を毎回
  パラメータで渡す。`config.LoadDefaultConfig` の region 解決（env / default）には頼らない（ambient に流れる罠を
  回避）。`ssooidc` は import しない。
- **YAML / 検証**: `sigs.k8s.io/yaml`（YAML → JSON → struct、`json:` タグを decode / validate / `--output json` で
  共用）+ `go:embed` の JSON Schema を `santhosh-tekuri/jsonschema/v6` で検証。加えて薄い Go 意味検証
  （session 解決可否・テンプレ変数・glob コンパイル・識別子キー拒否・org 照合）。
- **CLI**: `spf13/cobra`。
- **並列**: `golang.org/x/sync/errgroup` + `SetLimit(8)`。結果はアカウント順スロットに書き、join 後にソートして byte 安定。

## 4. desired-state エンジンの流れ

`internal/plan` が中核です:

- **current** = 既存管理ブロックのパース。同名プロファイルの region / role / session を比較して **CHANGED** を、
  および管理ブロック内の**手編集 drift** を検知。
- **desired** = `inventory` を `selector` で絞り、`naming` で命名し、`settings` を解決したもの。
- **diff** = `{added, removed, changed, unchanged}` に分類 + `drift`。`NeedsApply()`（差分 or drift）で exit code を決める。
- **名衝突検出**: desired の rendered 名が重複（テンプレに一意トークンが欠けている等）すれば `BuildDesired` が error。
- **org 取り違え防止**: `internal/config` の `CrossCheck` が config.yaml の `sso.start_url` / `region` と実
  `[sso-session]` を照合し、不一致なら plan を中断。

## 5. §0 冪等性の仕組み

**no-op 判定は plan ベース**です（レンダリング結果のバイト比較ではありません）。`app.Apply()` は
`plan.NeedsApply()` / `HasDiff` が false なら書き込まず no-op を返します。

決定論の担保:

- `render.Body()` は profiles を名前でソートし、キー順を固定（識別子キー固定順 → settings キー名ソート）、
  LF 改行で Bash 版と同一レイアウトを再現。
- **揮発する datetime は管理ブロック本文に含めない** — START / END マーカー行（`awsconfig` が所有）にのみ置く。
  マーカー datetime 形式は `2006/01/02 15:04:05`。
- **provenance ヘッダは本文の先頭行**だが、`Version` と `ConfigSHA` は build + config が同じなら安定するため
  冪等を壊さない。

実際のマーカー / provenance 文字列（コード準拠）:

```
# AWS_SSO_CONFIG_GENERATOR:<prefix> START <datetime>
# managed by aws-sso-profiles <version> — do not edit; config-sha256=<sha>

[profile <name>]
sso_session = <session>
sso_account_id = <accountId>
sso_role_name = <roleName>
<settings ... キー名ソート>
# AWS_SSO_CONFIG_GENERATOR:<prefix> END <datetime>
```

（`<version>` 未設定時は `(dev)`、`<sha>` 未設定時は `-` にフォールバック。マーカー行の `<prefix>` に空白は入らない。）

## 6. prefix スコープ・マーカーの splice アルゴリズム

`internal/awsconfig` は `~/.aws/config` を行単位でスキャンし、
`^# AWS_SSO_CONFIG_GENERATOR:(\S+) (START|END)\b` にマッチする行で自分の prefix のブロック範囲を特定します。

- **head + block + tail を verbatim 保持**: 管理ブロックの外側（他 prefix のブロック・手書き profile・コメント・
  空白・順序）は 1 バイトも変更しない。
- **START / END の均衡チェック**（`findBlockRange`）: 対象 prefix の START / END が不均衡なら中断。
- **自分の prefix のブロックのみ**を splice（`SpliceBlock`）/ 除去（`RemoveBlock`）。
- 書込は `Backup`（`.backup.YYYYMMDD_HHMMSS`、rotate で 10 個保持）→ `WriteAtomic`（一時ファイル + rename）。

これにより (a) file-per-org でも (b) 1 ファイルに複数 org 同居でも、同一ロジックで安全・冪等になります。

## 7. profile settings の解決

settings は識別子キーとは**別物**として扱います:

- 識別子キー（`sso_session` / `sso_account_id` / `sso_role_name`）は settings マップに含めず、`render.Body()` が
  固定順で stanza 先頭に出力。settings に書くと `config.checkSettings()` が `plan.IdentityKeys` と照合して
  validate エラー（`defaults.settings` / 全 `overrides[].settings` の双方をチェック）。
- settings 本体の解決順（後勝ち）:
  1. builtins（`output = json` / `cli_pager =`）
  2. ambient region fallback（非空のときのみ `region` を注入）
  3. `defaults.settings`
  4. `overrides[].settings`（マッチした profile に上書きマージ）
  → `config.ResolvedDefaultSettings()` が 1–3 を、`plan.BuildDesired()` が 4 を重ねる。
- 出力はキー名ソート（決定論）。空値キーは末尾スペースなし（`cli_pager =`）。

## 8. テスト戦略

| 層 | 手段 | カバー |
|---|---|---|
| table | stdlib testing | normalize（minimal / full エッジ・非 ASCII） / テンプレ展開 / glob select / plan 差分分類（added / removed / changed / unchanged） |
| golden | `testdata/*.golden` + `-update` | 管理ブロックのバイト一致。例: `internal/render/testdata/basic.golden`（キー順・`output = json`・`cli_pager =`・provenance ヘッダ） |
| fake SSO | interface `SSOLister` | accounts × roles 注入で paginator・errgroup fan-out を検証 |
| cache | table + tempdir | hit / miss + TTL（md5[:8]、既定 24h） |
| CLI / E2E | `rogpeppe/go-internal/testscript` | `cmd/aws-sso-profiles/testdata/script/*.txtar` で実バイナリ駆動: `lifecycle` / `drift` / `guards` / `settings` / `init` / `check_cleanup` |

**最重要は apply 二連発で 2 回目 exit 0 + 差分ゼロ（byte 一致）**（§0 の datetime 罠を捕捉）。E2E は
fake creds（`ASP_FAKE_INVENTORY`）と一時 `AWS_CONFIG_FILE` を使い、plan exit 2/0・dry-run 非書込・冪等・
名衝突 error・org 照合中断・drift 検知・`cleanup --session` parity を確認します。

## 9. CI / 配布

- **`.github/workflows/go.yml`**: push / PR to main。`test`（ubuntu + macos matrix: gofmt チェック / `go vet` /
  `go test -race`）、`govulncheck`、`golangci-lint`。
- **`.github/workflows/shellcheck.yml`**: 旧 Bash スクリプト用の lint。
- **`.goreleaser.yaml`**: `project_name: aws-sso-profiles`、`main: ./cmd/aws-sso-profiles`、`binary: aws-sso-profiles`。
- **`Makefile`**: `build` / `test` / `race` / `vet` / `fmt` / `fmt-check` / `lint`（golangci-lint） /
  `vuln`（govulncheck） / `check`（= `fmt-check vet race`、CI 相当のローカルゲート） / `completions` / `clean`。

---

関連: 要件（目的・スコープ・不変条件・region 2 概念・ユーザーフロー）は [requirements.md](requirements.md) を参照。
