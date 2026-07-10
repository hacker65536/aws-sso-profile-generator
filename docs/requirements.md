# 要件ドキュメント — aws-sso-profiles（Go 版 / desired-state CLI）

> このドキュメントは **何を・なぜ**（what / why）を扱う要件仕様です。
> **どう作られているか**（how / アーキテクチャ）は [implementation.md](implementation.md) を参照してください。
> ユーザー向けの使い方・config スキーマの実例は [../README.md](../README.md) にあります。

## 1. 目的 / 背景

`aws-sso-profiles` は、宣言的な `.aws-sso-profiles.yaml` を single source of truth として、
`~/.aws/config` の AWS SSO プロファイル群を **plan / apply**（Terraform 流・冪等・構造化出力・
exit code）で管理する CLI です。

旧来の Bash 版（`generate-sso-profiles.sh` ほか。本リポジトリからは撤去済み）は成熟していましたが、本質的な弱点がありました:

- **判断がファイルに残らない**: 対話 5 問（prefix / アカウント数 / region / 正規化 / y-n）＋
  2 つのフィルタで運用しており、「なぜこの構成なのか」が実行のたびに揮発する。
- **CHANGED を検知しない**: diff がプロファイル名の add / remove のみで、既存プロファイルの
  region / role が変わっても気づけない。
- **脆い層を抱える**: `aws` CLI をサブプロセスで叩き → 自前キャッシュ管理 → jq、という一番厚くて
  壊れやすい層に依存していた（キャッシュ TTL のドキュメント/実装乖離という staleness bug も抱えていた）。

**到達目標** = 人間の判断を `config.yaml` に圧縮し、速度・変更耐性・AI/自動化フレンドリを得ること。
具体的には:

- **宣言的**: 対話とフィルタを config に圧縮し、判断がファイルに残る。
- **desired-state**: `plan` が差分（added / removed / **changed** / unchanged）と **drift**（管理ブロック内の
  手編集）を可視化し、`apply` は**冪等**（同一 config + 同一インベントリなら no-op・バイト不変）。
- **AI/自動化フレンドリ**: `--output json`、Terraform 流 exit code、埋め込み JSON Schema（`schema` コマンド）。
- **依存レス**: AWS SDK for Go v2 を直接呼び、`aws` CLI / jq を不要にした単一バイナリ。

## 2. スコープ / 非スコープ

### 対象（前提）

- **IAM Identity Center の organization instance（組織インスタンス）を前提とする。**
  1 Organization = 1 インスタンス = 1 `sso_start_url` / 1 `sso_region`（1 リージョンにデプロイ）。
  permission set で組織内の複数アカウントへ横断アクセスを提供する構成が対象。
- ユーザーは複数の Organization にログインしうる（マルチ org）。分離境界は `AWS_CONFIG_FILE` を
  分けること（[§7 マルチ組織](#7-マルチ組織org)）。

### 非スコープ

- **account instance（アカウントインスタンス, 2023/11〜）は非対応と明言する。**
  単一アカウント用で、複数アカウント横断の permission set 割当ができず、本ツールの
  `ListAccounts × ListAccountRoles` の fan-out を生まないため。
- **login / OIDC は行わない**: トークン取得は `aws sso login` に委譲し、本ツールは cache 済みトークンを
  読むだけ（[§6 非機能要件](#6-非機能要件)）。

## 3. 機能要件

### 3.1 サブコマンド

| コマンド | 役割 |
|---|---|
| `init` | 対話ウィザード（**対話はここだけ**）。`.aws-sso-profiles.yaml` 生成 + `[sso-session]` seed 書込 |
| `list` | 到達可能な accounts × roles を列挙（profile は書かない。`--output json` でガバナンス成果物） |
| `plan` | desired と現状の差分 + drift を表示（非破壊）。差分 or drift があれば exit 2 |
| `apply` | 冪等適用。管理ブロックのみ書換（バックアップ後） |
| `validate` | config を JSON Schema + 意味検証 + org 照合（session が解決できるか等） |
| `schema` | 埋め込み JSON Schema を出力（editor / AI 用） |
| `cleanup` | 管理ブロック除去（`--session <name>` で特定セッションのみ、`--yes` で確認スキップ） |
| `check` | `analyze` / `auto` / `manual` / `duplicates`（managed vs manual の集計） |
| `completion` | bash / zsh / fish 補完スクリプト生成（cobra 標準提供） |

共通フラグ: `-c/--config`（既定 `./.aws-sso-profiles.yaml`）、`-o/--output human|json`、
`-p/--parallel N`（既定 8、adaptive retry 併用）、`--login`（失効時に `aws sso login` を代行）、
`--cache`（opt-in ディスクキャッシュ）、`--refresh-cache`。

### 3.2 config スキーマ（`.aws-sso-profiles.yaml`）

1 org = 1 config = 1 `AWS_CONFIG_FILE` = 1 prefix を基本単位とする。主なキー:

- `aws_config_file`（任意）: この org の書込先。env `AWS_CONFIG_FILE` 相当。org 分離境界。
- `sso.session`: `[sso-session <name>]` の参照。省略時はファイル先頭順の最初を採用。
- `sso.start_url` / `sso.region`（任意）: 管理者提供の seed。org 取り違え防止の照合に使う。
- `defaults.prefix`: **org 識別子**（org ごとに一意）。マーカーもこの prefix でスコープ。
- `defaults.normalize`: `minimal`（既定） / `full`。
- `defaults.template`: 命名テンプレ（既定 `{prefix}-{account_name}-{account_id}:{role}`）。
- `defaults.settings`: 各 profile に注入する既定 key/value（`region` / `output` / `cli_pager` や任意の AWS CLI キー）。
- `select.include` / `select.exclude`: account / role の glob フィルタ。
- `overrides[]`: `match` にマッチした profile の `settings` を上書き/追加マージ。

実際の YAML 例とフィールド説明は [../README.md](../README.md#config-スキーマaws-sso-profilesyaml) を参照。

### 3.3 命名テンプレと正規化

- テンプレ変数: `{prefix}` / `{account_name}`（正規化後） / `{account_id}` / `{role}`（生・非正規化）。
  未知変数は `validate` / `plan` が拒否。
- 既定テンプレ: `{prefix}-{account_name}-{account_id}:{role}`。
- **正規化 2 モード（ASCII 前提）**:
  - `minimal`: ASCII 空白 → `_`、大文字/ハイフンは保持、`[A-Za-z0-9_-]` 以外を除去。
  - `full`: ASCII を小文字化 +（空白 | `-`）→ `_`、`[a-z0-9_]` 以外を除去。
  - Go の Unicode `ToLower` と差が出るため **ASCII 限定**で実装（Bash 版とのバイト互換のため）。

### 3.4 select（絞り込み）

- `include` / `exclude` は account / role の glob（`*` / `?`）。`include` が空なら全件、
  `exclude` にマッチしたものは除外。
- `overrides[].match` にマッチした profile へ `settings` を上書き/追加マージ（後勝ち）。

### 3.5 profile settings

- `defaults.settings` は各 profile に書く key/value。値は文字列（数値も `"43200"` のようにクォート）。
- `overrides[].settings` はマッチする profile に上書きマージ。
- 識別子キー（`sso_session` / `sso_account_id` / `sso_role_name`）はツール占有で、settings に書くと
  `validate` エラー。レンダリング時は識別子キー（固定順）→ settings（キー名ソート）の順で決定論的に出力。

### 3.6 provenance と drift

- **provenance**: 管理ブロックの先頭行に、どの config・どのバージョンから生成したかを刻む
  （[§5 保存すべき不変条件](#5-保存すべき不変条件) 11、[implementation.md](implementation.md) の該当節）。
- **drift**: 管理ブロック内の手編集を `plan` が検知し、exit 2 で報告する。

### 3.7 opt-in ディスクキャッシュ

- 既定は OFF（ライブ取得）。`--cache`（+ env `CACHE_DIR` / `CACHE_EXPIRY_HOURS`）で opt-in。
  理由: Bash 版はキャッシュ TTL の staleness bug を抱えており、キャッシュは事故要因。既定を単純化する。

## 4. 非機能要件

- **冪等性 / byte 安定 / 決定論**: 同一 config + 同一インベントリなら `apply` は no-op（バイト不変）。
  仕組みは [§5-10](#5-保存すべき不変条件) と [implementation.md の §0](implementation.md#0-冪等性の仕組み)。
- **Terraform 流 exit code**: `0` = 差分なし / `2` = 差分あり or drift / `1` = エラー。
- **構造化出力**: `--output json` で `{added, removed, changed, unchanged, changes, drift}` を出力。
- **変更前バックアップ**: 書込前に `.backup.YYYYMMDD_HHMMSS` を作成し、新しい 10 個を保持。
- **保護**: 手書き profile・他 prefix の管理ブロックは絶対に触らない。
- **token は read-only 消費**: `~/.aws/sso/cache/*.json` の `accessToken` / `expiresAt` を読むだけ。
  sso-oidc / login は呼ばない。期限切れは `aws sso login --sso-session <name>` を案内（`--login` で代行可）。
- **SSO API region の pin**: portal API（ListAccounts / ListAccountRoles）は `[sso-session].sso_region` を
  明示 pin し、ambient env / default region には流されない。
- **adaptive retry**: ~190 アカウント規模の SSO Portal throttling に耐えるため adaptive retry + backoff を使う。

## 5. 保存すべき不変条件

Bash 版から引き継ぐ、破ってはならない不変条件:

1. **マーカーブロック（prefix スコープ）**:
   `# AWS_SSO_CONFIG_GENERATOR:<prefix> START <datetime>` … `:<prefix> END <datetime>`。
   この外側の手書き内容・他 prefix のブロックは絶対に触らない。各 prefix ブロックの START / END は
   必ず均衡（不均衡なら中断）。apply / cleanup は自分の prefix のブロックのみ操作。
2. **プロファイル ini 形式**（識別子キーは固定順・先頭）:
   ```
   [profile <name>]
   sso_session = <session>
   sso_account_id = <accountId>
   sso_role_name = <roleName>
   ```
   以降に settings（`region` / `output` / `cli_pager` 等）をキー名ソートで続ける。空値キーは
   `cli_pager =` のように末尾スペースなし。
3. **命名**: `{prefix}-{normalized_account_name}-{account_id}:{role_name}`（role は非正規化・生）。既定 prefix `awssso`。
4. **正規化 2 モード**: `minimal` / `full`（[§3.3](#33-命名テンプレと正規化)）。**ASCII 前提**。
5. **トークン**: `~/.aws/sso/cache/*.json`（`aws sso login` 済み前提）の `accessToken` / `expiresAt` を
   読むだけ。**sso-oidc / login は絶対に呼ばない**。期限切れは案内。
6. **AWS API**: `service/sso` の **ListAccounts / ListAccountRoles のみ**（GetRoleCredentials なし）。paginate 必須。
7. **セッション設定**: `[sso-session NAME]` から `sso_region` と `sso_start_url` のみ使用。未指定かつ複数なら
   ファイル先頭順の最初を採用、名前指定も可。
8. **config パス**: env `AWS_CONFIG_FILE` 優先、なければ `~/.aws/config`。
9. **変更前バックアップ**: `.backup.YYYYMMDD_HHMMSS`（新しい 10 個保持）。
10. **冪等性の要**: 同一 config + 同一インベントリ → apply は no-op。判定は **plan ベース**（差分が無ければ
    書き込まない）。揮発する datetime は START / END マーカー行にのみ置き、provenance ヘッダは build + config が
    同じなら安定するため冪等を壊さない。
11. **provenance ヘッダ**: 管理ブロックの先頭行に
    `# managed by aws-sso-profiles <version> — do not edit; config-sha256=<hash>` を 1 行。
    「どの config から生成されたか」を監査で追える。冪等判定には影響しない（build + config で安定）。

## 6. region の 2 概念

region は 2 系統を明確に分離する:

| 概念 | 用途 | 出所 |
|---|---|---|
| **SSO API region** | portal API（ListAccounts / ListAccountRoles）を叩く先。必須・固定 pin | `[sso-session].sso_region` **専管** |
| **profile region** | 各プロファイルに書く `region =` の値 | `defaults.settings.region` → 無ければ ambient（`AWS_REGION` > `AWS_DEFAULT_REGION` > `[default].region`）に fallback、`overrides` で上書き可 |

AWS のドキュメント上も `sso_region` は「default CLI region とは別物で、異なってよい」とされる。単体の
`aws sso list-accounts` は `--region` 無しだと ambient に流れるため、本ツールは `sso_region` を明示 pin する。

## 7. マルチ組織（org）

- 前提: organization instance は 1 Organization に 1 つ（[§2](#2-スコープ--非スコープ)）。ユーザーは複数 org に
  ログインしうる。
- **分離境界 = `AWS_CONFIG_FILE` を分けること**。org ごとに config を用意し `-c` で切り替える。
- **prefix は org 同一性を profile 名に刻む load-bearing な識別子**（`aws configure list-profiles` や横断
  スクリプトで org を判別する鍵）。org ごとに一意。
- 管理ブロックは **prefix スコープ**なので、同一ファイルに複数 org を同居させても互いのブロック・手書き
  profile を侵さない。prefix 変更 = 旧 prefix cleanup → 新 prefix apply（rename 相当）。

## 8. 情報の出所（provenance 階層）

「既知の入力」と「発見される状態」を分離する:

| 層 | 情報 | 出所 | 我々の関与 |
|---|---|---|---|
| 0 seed | `sso_start_url` / `sso_region`(API) / session 名 / scopes | **管理者提供（事前既知の入力）** | `init` で受取り `[sso-session]` + config に落とす |
| 1 token | `accessToken` / `expiresAt` | login（browser） | `aws sso login` 委譲、**読むだけ** |
| 2 inventory | accounts × roles | SSO API | 取得（決定論） |
| 3 policy | prefix / template / normalize / select / settings + overrides | ユーザ方針 | `config.yaml` |

層0 は **given（既知入力）であって discovered ではない** → start_url / region を脆く自動検出しない。
`[sso-session]` ブロックが start_url / region の**唯一の権威**（`aws sso login` も生成後 profile の
`sso_session=` 解決もこの block を要する）。`config.yaml` の `sso.start_url` / `sso.region` は任意
（init seed 兼整合チェック）。

## 9. ユーザーフロー

冪等パイプラインは `init → login → plan → apply` の一本道で、前提が揃っている分だけ先頭をスキップして
途中から合流できる:

- **まっさら**: `init`（seed 入力 → config + `[sso-session]` 生成）→ `aws sso login --sso-session <name>`
  → `plan`（差分確認、exit 2 なら差分あり）→ `apply`（冪等適用）。
- **途中から**: すでに `[sso-session]` とログイン済みなら `init` / `login` を飛ばして `plan` / `apply` に
  直接合流。config を書き換えたら再び `plan` → `apply`。

既存 config の有無・手書き SSO からの移行・マルチ org 構成など、導入時の状況別の実践手順は
[setup-guide.md](setup-guide.md) を参照。

---

関連: 実装の詳細（Phase A–E・パッケージ責務・§0 冪等性の仕組み・テスト戦略）は
[implementation.md](implementation.md) を参照。
