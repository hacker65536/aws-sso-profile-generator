# demo — terminal recording

README に埋め込む GIF の再生成用アセット一式です。

| GIF | 台本 | 内容 |
|---|---|---|
| `aws-sso-profiles.gif` | `demo.tape` | plan / apply のライフサイクル（README トップ） |
| `aws-profile-fzf.gif` | `profile-switch.tape` | 導入後の日常利用: fzf で `AWS_PROFILE` 切替（README Tips） |

## 再生成

```bash
make demo                                # = bash demo/record.sh（全 tape を録画）
bash demo/record.sh demo/demo.tape       # 片方だけ録画
```

必要ツール: [`vhs`](https://github.com/charmbracelet/vhs)（`brew install vhs`）、`ffmpeg`、`go`。
`profile-switch.tape` は追加で `fzf` と AWS CLI v2 が必要です（`aws configure list-profiles` を
オフラインで叩くだけで、実 AWS には接続しません。`AWS_SHARED_CREDENTIALS_FILE` も scratch に
向けるため、録画者の実 credentials が GIF に映り込むことはありません）。

## 仕組み

- **実 AWS もログインも不要・決定論的**。`demo/record.sh` が使い捨てバイナリをビルドし、
  `ASP_FAKE_INVENTORY`（`internal/app/app.go`）にフェイク inventory (`inv.json`) を渡して
  SSO API を一切叩かずに録画します。E2E テスト（`cmd/aws-sso-profiles/testdata/script/*.txtar`）
  と同じ仕組みです。
- フィクスチャは **immutable テンプレート**。`apply` / drift / `cleanup` はファイルを書き換えるため、
  録画のたびに scratch ディレクトリへコピーし直して常に同じ初期状態から始めます。

| ファイル | 役割 |
|---|---|
| `demo.tape` / `profile-switch.tape` | VHS スクリプト（録画の台本） |
| `record.sh` | ドライバ: build → tape ごとに scratch へフィクスチャ配置 → env export → `vhs` 実行 |
| `config.yaml` | 宣言的 config（録画時は `.aws-sso-profiles.yaml` として配置） |
| `aws_config` | `[sso-session]` seed + 手書きプロファイル（管理外の保全を見せる） |
| `inv.json` | `ASP_FAKE_INVENTORY` 用のフェイク accounts×roles |
| `aws_profile.sh` | fzf 切替ヘルパー（README Tips と同一内容。profile-switch で使用） |
| `aws-sso-profiles.gif` / `aws-profile-fzf.gif` | 生成物（コミット対象） |

## 見せているストーリー

**`demo.tape`（12 ステップ）**: `--help` → 宣言 config 提示 → `validate` → `plan`（差分, exit 2）→ `apply` →
`plan`（0 diff = 冪等）→ 生成プロファイル確認 → **drift 注入 → `plan` が検出 → `apply` が自己修復** →
`check analyze` → `cleanup`（手書きプロファイルは残る）。

**`profile-switch.tape`（4 ステップ）**: apply 済み状態から開始 → 生成プロファイル一覧 →
`aws_profile.sh`（fzf ヘルパー）提示 → fzf で絞り込み選択して `AWS_PROFILE` を切替 ×2 回
（staging ReadOnly → prod Administrator）。

## 調整ポイント

- 見た目: 各 tape 冒頭の `Set Theme` / `Set FontSize` / `Set Width` / `Set Height`。
- テンポ: 各ステップの `Sleep` と `Set TypingSpeed`。
- MP4 も出したい場合: tape に `Output demo/<name>.mp4` を 1 行足す。
