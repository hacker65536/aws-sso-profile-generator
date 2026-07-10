# 導入シナリオ別ガイド

`aws-sso-profiles` を導入するときの手順を、**いま手元の `~/.aws/config` がどういう状態か**に応じたシナリオ別にまとめたガイドです。インストール（Homebrew / ソースビルド）は [README](../README.md#インストール--ビルド) を参照してください。

## あなたの状況はどれ？

| いまの状況 | 該当シナリオ |
|---|---|
| `~/.aws/config` がそもそも存在しない | [シナリオ 1](#シナリオ-1-まっさらな状態から使う) |
| `~/.aws/config` はあるが SSO は未使用（static credentials・assume role 等） | [シナリオ 2](#シナリオ-2-既存の-awsconfig-があるsso-未使用) |
| `~/.aws/config` に手書きの `[sso-session]` / SSO profile がある | [シナリオ 3](#シナリオ-3-手書きの-sso-設定を既に使っている) |
| 既存の `~/.aws/config` には触らせず、生成先を別ファイルにしたい | [シナリオ 4](#シナリオ-4-生成先ファイルを分けたいaws_config_file-の分離) |
| 2 つ以上の org を扱い、config も生成先ファイルも org ごとに分けたい | [シナリオ 5](#シナリオ-5-複数-org-で-config-も生成先も分ける) |

シナリオは排他ではなく積み上げです。シナリオ 2〜3 にはシナリオ 1 の基本手順が、シナリオ 5 にはシナリオ 4 の仕組みがそのまま含まれます。

導入後、AWS アカウントやロールが増減したときの再実行手順は[導入後の定常運用（アカウント / ロールが増減したとき）](#導入後の定常運用アカウント--ロールが増減したとき)を参照してください。生成した profile を Claude などの AI エージェントに使わせる場合は[生成した profile を AI エージェントから使う（CLAUDE.md への組み込み）](#生成した-profile-を-ai-エージェントから使うclaudemd-への組み込み)も参照してください。

## 共通の前提と流れ

各シナリオで繰り返さないため、共通事項をここにまとめます。

### 前提

- IAM Identity Center の **organization instance** を対象とし、管理者提供の seed（start URL / SSO region）が手元にあること。
- ログインは `aws sso login` に委譲するため **AWS CLI v2** が必要。

詳細は README の[前提](../README.md#前提)を参照。

### 基本パイプライン

すべてのシナリオは次の一本道の部分集合です。前提が揃っている分だけ先頭をスキップして途中から合流できます（[requirements.md §9](requirements.md#9-ユーザーフロー)）。

```bash
aws-sso-profiles init ...                # 設定ウィザード（config + [sso-session] seed）
aws sso login --sso-session <name>       # ログイン（AWS CLI に委譲）
aws-sso-profiles plan                    # 差分確認（非破壊。exit 2 なら差分あり）
aws-sso-profiles apply                   # 冪等適用（管理ブロックのみ書換）
```

### 安全性の保証（全シナリオ共通）

既存の config がある状態で導入しても、手書きの内容が壊れることはありません。

- 書き換わるのは **管理ブロック**（`# AWS_SSO_CONFIG_GENERATOR:<prefix> START/END` で囲まれた範囲）だけ。ブロック外の手書き profile・コメント・空行・並び順は**バイト単位で保持**されます。
- 書き込みの前に必ず `<対象ファイル>.backup.YYYYMMDD_HHMMSS` を作成します（新しい 10 個を保持、atomic write）。
- `plan` は読み取り専用です。exit code は `0`=差分なし / `2`=差分あり or drift / `1`=エラー。

### パス解決の 2 系統

本ツールが扱うファイルは 2 つあり、それぞれ独立に解決されます。

| ファイル | 解決順（左が優先） |
|---|---|
| config YAML（desired state） | `-c/--config` > 環境変数 `AWS_SSO_PROFILES_CONFIG` > `./.aws-sso-profiles.yaml` |
| 対象 AWS config（生成先） | YAML の `aws_config_file:` > 環境変数 `AWS_CONFIG_FILE` > `~/.aws/config` |

いずれも `~` は展開されます。

### `init` を使うか、YAML を手書きするか

本ガイドは全シナリオで **`init` + 明示フラグ**（`--session --start-url --region --prefix`、必要に応じ `--aws-config`）を正とします。コピペで再現でき、`[sso-session]` seed の冪等スキップ（既に同名ブロックがあれば書かない）を内蔵しているためです。config YAML が既にある場所への `init` は `--force` を付けない限り拒否されます。

YAML を直接書きたい場合は README の [config スキーマ](../README.md#config-スキーマaws-sso-profilesyaml)を参照して作成し、`aws-sso-profiles validate` で検証してください。以降の `plan → apply` は同じです。

---

## シナリオ 1: まっさらな状態から使う

`~/.aws/config` が存在しない、または空の状態から始めるケースです。

**前提条件**

```bash
ls ~/.aws/config   # No such file → このシナリオ
```

**設定と操作**

`~/.aws/config` が無くても `init` が作成します（`[sso-session]` の seed 書き込み時に生成）。

```bash
aws-sso-profiles init \
  --session my-sso --start-url https://my.awsapps.com/start --region us-east-1 --prefix awssso
aws sso login --sso-session my-sso
aws-sso-profiles plan
aws-sso-profiles apply
```

**確認**

```bash
aws configure list-profiles | grep '^awssso-'   # 生成された profile を確認
aws-sso-profiles plan                           # exit 0（差分なし）になること
```

**注意点**

- `--prefix` は org 識別子としてすべての profile 名に焼き込まれます（既定 `awssso`）。後から変えると全 profile のリネームに相当する（cleanup → apply）ため、最初に決めてください。

## シナリオ 2: 既存の `~/.aws/config` がある（SSO 未使用）

static credentials への参照や assume role 用の profile を手書き運用しているが、SSO はまだ、というケースです。

**前提条件**

```bash
grep -c '\[profile' ~/.aws/config        # 既存 profile がある
grep '\[sso-session' ~/.aws/config       # 何も出ない → このシナリオ
```

**設定と操作**

シナリオ 1 とまったく同じです。`init` は既存ファイルの末尾に `[sso-session]` を追記し、`apply` は管理ブロックを末尾に追加するだけです。

**確認**

既存の手書き profile が無傷であることを差分で確かめられます。

```bash
diff ~/.aws/config ~/.aws/config.backup.*   # 差分が管理ブロック（と [sso-session]）の追加だけであること
aws sts get-caller-identity --profile <既存のprofile名>   # 既存 profile が従来どおり動くこと
```

**注意点**

- 既存 profile 名との衝突は、生成名が `{prefix}-...` 形式のため実質起きませんが、万一衝突すれば `validate` / `plan` が拒否します。

## シナリオ 3: 手書きの SSO 設定を既に使っている

`~/.aws/config` に手書きの `[sso-session]` と SSO profile（`sso_session` / `sso_account_id` / `sso_role_name` を持つ profile）が既にあるケースです。本ツールへの移行で最も多いパターンです。

**前提条件**

既存のセッション名を確認しておきます。

```bash
grep '\[sso-session' ~/.aws/config
# 例: [sso-session my-sso]
```

**設定**

`--session` に**既存のセッション名**を渡します。同名の `[sso-session]` ブロックが既にあるため seed 書き込みは冪等にスキップされ、既存ブロックがそのまま権威になります。

```bash
aws-sso-profiles init \
  --session my-sso --start-url https://my.awsapps.com/start --region us-east-1 --prefix awssso
```

**操作**

そのセッションでログイン済み（トークンが有効）なら `aws sso login` も省略できます。

```bash
aws-sso-profiles plan
aws-sso-profiles apply
```

**手書き SSO profile との共存と移行**

既存 profile の取り込み（import / migrate）コマンドは**ありません**。desired state を YAML に宣言し、生成 profile に乗り換える方式です。

- 生成 profile は `{prefix}-...` の別名なので、apply 直後は「同じ account/role を指す手書き profile と生成 profile」が併存します。**両方動き、害はありません**。
- 現状の棚卸しには `check` を使います:

```bash
aws-sso-profiles check analyze      # Total / Auto (managed) / Manual の件数
aws-sso-profiles check manual       # 管理ブロック外（手書き）の profile 一覧 = 整理候補
aws-sso-profiles check duplicates   # 同名 profile の重複検出
```

- 推奨は「利用を生成 profile（`awssso-...`）へ移行し、不要になった手書き SSO profile を各自のタイミングで手動削除」。本ツールは管理ブロック外を消さないため、削除はユーザー自身がエディタで行います（直前バックアップは apply 時に自動作成済み）。

**注意点**

- YAML の `sso.session` と既存 `[sso-session]` の名前を一致させてください（`init --session <既存名>` を使えば自然に一致します）。
- `sso.start_url` を YAML に書いておくと、org 取り違え（別 org のセッションで apply してしまう事故）を `validate` / `plan` が照合・検出できます。

## シナリオ 4: 生成先ファイルを分けたい（`AWS_CONFIG_FILE` の分離）

既存の `~/.aws/config` には一切触らせず、生成 profile を別ファイル（例: `~/.aws/sso.config`）に置きたいケースです。

**設定**

生成先の固定には環境変数ではなく **YAML の `aws_config_file:` キーを推奨**します。config に宣言的に焼き込まれるためシェル環境に依存せず、環境変数 `AWS_CONFIG_FILE` は aws CLI 本体の挙動まで変えてしまうため「apply のときだけ設定する」運用は事故のもとです。

`init --aws-config` で YAML に焼き込まれます。

```bash
aws-sso-profiles init \
  --session my-sso --start-url https://my.awsapps.com/start --region us-east-1 \
  --prefix awssso \
  --aws-config ~/.aws/sso.config
```

生成される YAML（抜粋）:

```yaml
aws_config_file: ~/.aws/sso.config
sso:
  session: my-sso
  ...
```

**操作**

シナリオ 1 と同じく `login → plan → apply`。`[sso-session]` の seed も管理ブロックも `~/.aws/sso.config` に書かれ、`~/.aws/config` は読み書きされません。

**利用時の非対称に注意（重要）**

生成（`plan` / `apply`）には環境変数は不要ですが、生成された profile を **aws CLI が使う**には `AWS_CONFIG_FILE` の指定が必要です。

```bash
# 一時利用
AWS_CONFIG_FILE=~/.aws/sso.config aws sts get-caller-identity --profile awssso-myapp-prod-123456789012:AdminRole

# 常用するなら shell rc で
export AWS_CONFIG_FILE=~/.aws/sso.config
```

`AWS_CONFIG_FILE` を export すると aws CLI からは既存 `~/.aws/config` の profile が見えなくなる点に注意してください（両方使い分けたい場合はシナリオ 5 の切り替え機構を参照）。

**注意点**

- SSO トークンキャッシュ（`~/.aws/sso/cache/`）はファイルを分けても共有されます。分離前にログイン済みなら再ログインは不要です。

## シナリオ 5: 複数 org で config も生成先も分ける

業務用と検証用など 2 つ以上の org を扱い、`AWS_SSO_PROFILES_CONFIG`（desired state）も `AWS_CONFIG_FILE`（生成先）も org ごとに分けるケースです。

**ファイルまで分けるべきか**

profile 名は `{prefix}-...` で org ごとに一意なので、prefix を分けるだけで同一ファイル同居も可能です（README の[マルチ組織](../README.md#マルチ組織org)参照）。それでもファイルを分ける動機は:

- **org 取り違え防止**: 業務用を見ているつもりで検証用の profile を叩く事故を、そもそも「見えない」ことで防ぐ。
- `aws configure list-profiles` などのツーリングが全 profile を平坦に列挙するため、org 境界をファイルで切りたい。

**設定**

シナリオ 4 の応用です。org ごとに「YAML + 生成先 + prefix」を 1 セット用意し、各 YAML に `aws_config_file:` を書きます（`init --aws-config` で焼き込み）。

```bash
# 業務用 org（prefix: awssso）
aws-sso-profiles init -c ~/.aws-sso-profiles.work.yaml \
  --session work-sso --start-url https://work.awsapps.com/start --region us-east-1 \
  --prefix awssso --aws-config ~/.aws/work.config

# 検証用 org（prefix: awspoc）
aws-sso-profiles init -c ~/.aws-sso-profiles.poc.yaml \
  --session poc-sso --start-url https://poc.awsapps.com/start --region us-east-1 \
  --prefix awspoc --aws-config ~/.aws/poc.config
```

**切り替え機構**

`AWS_SSO_PROFILES_CONFIG`（ツールがどの desired state を読むか）と `AWS_CONFIG_FILE`（aws CLI がどの profile 群を見るか）は**必ずペアで切り替える**のがルールです。片方だけ切り替わると「poc の YAML を見ながら work の profile を叩く」ような取り違えが起きます。

shell 関数の例（`~/.bashrc` / `~/.zshrc`）:

```bash
awsorg() {
    case "$1" in
        work)
            export AWS_SSO_PROFILES_CONFIG=~/.aws-sso-profiles.work.yaml
            export AWS_CONFIG_FILE=~/.aws/work.config
            ;;
        poc)
            export AWS_SSO_PROFILES_CONFIG=~/.aws-sso-profiles.poc.yaml
            export AWS_CONFIG_FILE=~/.aws/poc.config
            ;;
        *)  echo "usage: awsorg work|poc" >&2; return 1 ;;
    esac
    echo "org=$1 AWS_CONFIG_FILE=$AWS_CONFIG_FILE"
}
```

[direnv](https://direnv.net/) の例（org ごとの作業ディレクトリに `.envrc`）:

```bash
# ~/work/aws/.envrc
export AWS_SSO_PROFILES_CONFIG=~/.aws-sso-profiles.work.yaml
export AWS_CONFIG_FILE=~/.aws/work.config
```

**操作**

切り替え後は通常どおりです。

```bash
awsorg work
aws sso login --sso-session work-sso   # 初回のみ
aws-sso-profiles plan && aws-sso-profiles apply

awsorg poc
aws sso login --sso-session poc-sso
aws-sso-profiles plan && aws-sso-profiles apply
```

**注意点**

- SSO トークンキャッシュは org 間でも共有ディレクトリ（`~/.aws/sso/cache/`）ですが、セッション単位で管理されるため干渉しません。
- 各 YAML に `sso.start_url` を書いておくと、org と YAML の組み合わせ違いを `validate` / `plan` が検出できます。

---

## 導入後の定常運用（アカウント / ロールが増減したとき）

導入はシナリオ 1〜5 で一度きりですが、**AWS Organizations にアカウントが増えた・ロール（permission set）の割り当てが増減した**ときの運用がここです。結論から言うと、**インベントリ（accounts × roles）が変わったら `plan` → `apply` を再実行するだけ**。config YAML は基本触りません。冪等なので何度でも安全です。

新アカウント/ロールは「YAML の変更」ではなく「SSO インベントリ側の変化」なので、`init` は不要で `plan`/`apply` に直接合流します（[requirements.md §9](requirements.md#9-ユーザーフロー)）。

**操作**

```bash
aws sso login --sso-session <name>   # トークン失効時のみ。新アカウントが SSO に見えないときも実行
aws-sso-profiles plan                # 新規は added、消えたものは removed（差分あれば exit 2）
aws-sso-profiles apply               # 管理ブロックを冪等更新（apply 前に自動バックアップ）
aws-sso-profiles plan                # exit 0（差分なし）になることを確認
```

**差分の読み方**

`plan` の出力カテゴリで何が起きたか分かります。

- **added**: 新しいアカウント、または既存アカウントに増えたロールの profile。
- **removed**: Organizations から消えたアカウント、または剥奪されたロールの profile（`apply` で管理ブロックから除去）。
- **changed**: `settings` / template など、既存 profile の中身が変わったもの。
- **drift**: 管理ブロックを手編集した痕跡。`plan` が可視化し、`apply` が desired state に自己修復します。

**注意点**

- **`--cache` を常用している場合のみ** `--refresh-cache` を付けてインベントリを最新化してください。キャッシュ TTL（既定 24 時間、`CACHE_EXPIRY_HOURS`）内は古いアカウント一覧が返り、増えた分が反映されないためです。`--cache` を使っていなければ毎回ライブ取得なので何もしなくて構いません。

  ```bash
  aws-sso-profiles plan --refresh-cache     # キャッシュを捨ててライブ再取得
  ```

- **`select` で絞り込んでいる場合のみ** YAML の編集が要ります。`select.include` を全件（`{ account: "*", role: "*" }`）にしていれば新アカウントは自動で候補に入りますが、`include` を限定している、または `select.exclude`（例 `*sandbox*`）に新アカウントがマッチする場合は、先に YAML を直してから `validate` → `plan` → `apply` します。

- **マルチ org（シナリオ 5）では org ごとに**再実行します。`AWS_CONFIG_FILE` と `AWS_SSO_PROFILES_CONFIG` のペア切替を守ってください。

  ```bash
  awsorg work && aws-sso-profiles plan && aws-sso-profiles apply
  awsorg poc  && aws-sso-profiles plan && aws-sso-profiles apply
  ```

- **定期実行したい場合**: `apply` は非対話・冪等・exit code が明確なので cron 等に載せられます。ただしトークン失効時の `aws sso login` はブラウザ操作を伴うため、無人実行では有効なトークンが前提になる点に留意してください。

---

## 生成した profile を AI エージェントから使う（CLAUDE.md への組み込み）

生成される profile 名には org（prefix）・アカウント名・アカウント ID・role がすべて焼き込まれているため（`{prefix}-{account_name}-{account_id}:{role}`）、AI エージェントは**名前を見るだけで「どの org の・どのアカウントに・どの権限で」入るのかを判別**できます。この規約を CLAUDE.md（Claude Code の指示ファイル。他エージェントの AGENTS.md 等でも同様）に宣言しておくと、AI に AWS 操作を任せるときの profile 選択が安全かつ確実になります。

### テンプレート（単一 org）

そのまま CLAUDE.md に貼り付け、`awssso` / `my-sso` を自分の値に置き換えてください。

```markdown
## AWS CLI / profile の使い方

AWS の profile は [aws-sso-profiles](https://github.com/hacker65536/aws-sso-profiles) で生成・管理している。

- profile 名の形式: `awssso-{アカウント名}-{アカウントID}:{ロール名}`。
  prefix `awssso-` が付いた profile がツール管理下のもので、名前だけで
  アカウントと権限が判別できる。
- profile の列挙: `aws configure list-profiles | grep '^awssso-'`
- aws コマンドは必ず `--profile <profile名>` を明示する（暗黙の default や
  環境変数 `AWS_PROFILE` の設定状態に依存しない）。
- トークン失効エラー（`Error when retrieving token from sso` /
  `The SSO session has expired` 等）が出たら、`aws sso login --sso-session my-sso`
  の実行をユーザーに促してから再試行する。
```

### テンプレート（マルチ org — シナリオ 5 の構成）

複数 org を扱う場合は、**どの prefix がどの org で、破壊的操作をどこまで許すか**を宣言するのが最重要です。

```markdown
## AWS CLI / profile の使い方

AWS Organizations は 2 つあり、profile の prefix で判別する
（[aws-sso-profiles](https://github.com/hacker65536/aws-sso-profiles) で生成・管理）。

| prefix | org | 権限 | 破壊的操作 |
|--------|-----|------|-----------|
| `awssso-` | 業務用 | ReadOnly 中心 | ❌ 禁止（読み取りのみ） |
| `awspoc-` | 検証用 | Administrator | ✅ 可 |

- コマンド提示・実行時は必ずどちらの org かを明示する。
- 作成・変更・削除は検証用（`awspoc-`）でのみ行う。
- org ごとに config ファイルが分かれているため、`AWS_CONFIG_FILE` と
  `AWS_SSO_PROFILES_CONFIG` は必ずペアで切り替える（`awsorg work|poc`）。
- profile の列挙: `AWS_CONFIG_FILE=~/.aws/work.config aws configure list-profiles`
```

### 機械可読な列挙

エージェントにアカウント×ロールの全体像を渡したい場合は、profile 名の grep より構造化出力が確実です。

```bash
aws-sso-profiles list --output json    # 到達可能な accounts×roles（SSO ログイン要）
aws-sso-profiles check auto            # 管理下の profile 名一覧（オフライン）
```

---

関連: config スキーマとサブコマンドの一覧は [README](../README.md)、設計上の不変条件とユーザーフローは [requirements.md](requirements.md) を参照。
