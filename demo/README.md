# demo — terminal recording

`aws-sso-profiles.gif` の再生成用アセット一式です。README トップの GIF はここから作られます。

## 再生成

```bash
make demo          # = bash demo/record.sh  ->  demo/aws-sso-profiles.gif
```

必要ツール: [`vhs`](https://github.com/charmbracelet/vhs)（`brew install vhs`）、`ffmpeg`、`go`。

## 仕組み

- **実 AWS もログインも不要・決定論的**。`demo/record.sh` が使い捨てバイナリをビルドし、
  `ASP_FAKE_INVENTORY`（`internal/app/app.go`）にフェイク inventory (`inv.json`) を渡して
  SSO API を一切叩かずに録画します。E2E テスト（`cmd/aws-sso-profiles/testdata/script/*.txtar`）
  と同じ仕組みです。
- フィクスチャは **immutable テンプレート**。`apply` / drift / `cleanup` はファイルを書き換えるため、
  録画のたびに scratch ディレクトリへコピーし直して常に同じ初期状態から始めます。

| ファイル | 役割 |
|---|---|
| `demo.tape` | VHS スクリプト（録画の台本） |
| `record.sh` | ドライバ: build → scratch にフィクスチャ配置 → env export → `vhs` 実行 |
| `config.yaml` | 宣言的 config（録画時は `.aws-sso-profiles.yaml` として配置） |
| `aws_config` | `[sso-session]` seed + 手書きプロファイル（管理外の保全を見せる） |
| `inv.json` | `ASP_FAKE_INVENTORY` 用のフェイク accounts×roles |
| `aws-sso-profiles.gif` | 生成物（コミット対象） |

## 見せているストーリー（12 ステップ）

`--help` → 宣言 config 提示 → `validate` → `plan`（差分, exit 2）→ `apply` →
`plan`（0 diff = 冪等）→ 生成プロファイル確認 → **drift 注入 → `plan` が検出 → `apply` が自己修復** →
`check analyze` → `cleanup`（手書きプロファイルは残る）。

## 調整ポイント

- 見た目: `demo.tape` 冒頭の `Set Theme` / `Set FontSize` / `Set Width` / `Set Height`。
- テンポ: 各ステップの `Sleep` と `Set TypingSpeed`。
- MP4 も出したい場合: `demo.tape` に `Output demo/aws-sso-profiles.mp4` を 1 行足す。
