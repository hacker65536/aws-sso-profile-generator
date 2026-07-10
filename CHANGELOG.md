# Changelog

すべての特記すべき変更点をここに記録します。フォーマットは [Keep a Changelog](https://keepachangelog.com/) を参考にしています。

> **v2.0.0 以降は Go 実装（`aws-sso-profiles`）が本体です。** v1.x は Bash 版の履歴で、Bash 版は撤去済みです（コードは git 履歴を参照）。

## [v2.1.0] - config パスの環境変数指定と導入ガイド

### Added
- **環境変数 `AWS_SSO_PROFILES_CONFIG` で config パスを指定可能に。** 解決順は `-c/--config` 明示指定 > env > 既定 `./.aws-sso-profiles.yaml`（`~` は展開）。マルチ org で `AWS_CONFIG_FILE` とペア切替する運用の土台。
- **導入シナリオ別ガイド** [docs/setup-guide.md](docs/setup-guide.md)。まっさら / 既存 config あり / 手書き SSO からの移行 / 生成先ファイル分離 / マルチ org の 5 シナリオ別に設定と操作を解説。生成 profile を AI エージェントに使わせる CLAUDE.md テンプレート（単一 org / マルチ org）も同梱。
- **fzf で `AWS_PROFILE` を切り替える日常利用デモ**（`demo/profile-switch.tape` → `demo/aws-profile-fzf.gif`、README Tips に埋め込み）。`demo/record.sh` は複数 tape 対応になり、録画時に `AWS_SHARED_CREDENTIALS_FILE` を scratch へ隔離。
- VHS 製ターミナルデモ GIF（plan / apply ライフサイクル）を README トップに埋め込み。

### Changed
- Go module path を `github.com/hacker65536/aws-sso-profiles` に統一し、リポジトリ名との乖離を解消（`go install` の import path が変わる。バイナリ利用者への影響なし）。

## [v2.0.0] - Go 実装への全面移行

### Changed
- **実装を Go 製の desired-state CLI (`aws-sso-profiles`) に全面移行。** 宣言的 `.aws-sso-profiles.yaml` を single source of truth とし、`plan` / `apply`（Terraform 流・冪等・構造化出力・exit code）で管理する。
- AWS SDK for Go v2 直呼びにより `aws` CLI / jq / column への依存を排し、単一バイナリ化（トークン取得の `aws sso login` のみ AWS CLI v2 に委譲）。

### Added
- `plan` の差分に **changed** と **drift**（管理ブロック内の手編集）検知を追加。
- `--output json` と Terraform 流 exit code（`0`=差分なし / `2`=差分あり or drift / `1`=エラー）。
- 埋め込み JSON Schema（`schema` コマンド）、`init` ウィザード、prefix スコープの管理ブロックによるマルチ org 対応。
- `version` サブコマンド（version / commit / build date / go / os-arch を human・json 出力）と build メタ情報の埋め込み。

### Removed
- Bash 実装一式（`generate-sso-profiles.sh` / `check.sh` / `cleanup-generated-profiles.sh` / `lib/` / `test/` / `completions/`）、`CACHE_USAGE.md`、shellcheck CI を撤去。

## [v1.21.0] - 出力の英語化・整形

### Changed
- スクリプトの全ユーザー向け出力を英語化（コードコメントは日本語のまま）
- `rotate_files_by_pattern` の出力をコロン形式に変更（`Backups removed: 1 (kept: 10)` / `Log files removed: 3 (kept: 30)`）
- Phase 2/3 の出力を 1 ブロックにまとめ、Phase 境界のみ空行で区切る

### Fixed
- "Expires at" 後と "Normalization examples" 後の二重空行を除去
- Phase 2 ヘッダと中身を分断していた空行を除去（ブロック感を改善）

## [v1.20.0] - UX 大量改善・コード品質向上・並行実行ガード

### Added
- `--account-filter PATTERN` / `--role-filter PATTERN` フラグで対象アカウント/ロールを絞り込み
- `cleanup-generated-profiles.sh` に `--session NAME` フラグで特定セッションのみ削除
- `check.sh cache` サブコマンド（stats / clear / validate）
- 並行実行ガード（mkdir ベース advisory lock、stale lock 自動回収）
- Ctrl+C / SIGTERM のクリーンハンドリング
- Bash/Zsh シェル補完スクリプト (`completions/`)
- 純関数の単体テスト (`test/test_units.sh`, 20 アサーション)
- README に処理フロー図 (ASCII)

### Changed
- SSO セッション期限切れエラーをコピペ可能な actionable 形式に
- `extract_profile_names` ヘルパーで重複 sed 7 箇所を集約

### Fixed
- 再生成のたびに空行が累積するバグ（`trim_trailing_empty_lines` 導入で解消）

## [v1.19.0] - UX 改善: --dry-run / Diff 表示 / ログローテーション

### Added
- `--dry-run` フラグ: 設定ファイルを変更せず生成予定をプレビュー（generate / cleanup 両対応）
- 再生成時の Diff 表示 (`+ 追加 / - 削除 / = 変更なし`)
- 実行ログのローテーション（デフォルト 30 件、`LOG_KEEP_COUNT` で上書き可能）
- `extract_auto_profiles` / `rotate_files_by_pattern` ヘルパー

### Changed
- E2E テストを 11 → 15 アサーションに拡張

## [v1.18.0] - Phase 2 大幅高速化 + フェーズ別 timing + portability 改善

### Added
- フェーズ別 timing 計測 (`[TIMING] Phase 1/2/3/TOTAL` ログ + 終了時サマリ)
- `perf_now` / `perf_diff` ヘルパー (bash 5+ `EPOCHREALTIME` 活用)
- `parse_utc_to_epoch` 共通関数

### Changed
- Phase 2 を 10x 高速化 (warm cache 18.5s → 2.4s)
  - Pre-flight 分類を単一 batch stat 化
  - キャッシュヒット時は worker spawn せず軽量 `bash -c` で並列
- BSD/GNU date の 3 分岐を統合、bash 内蔵 `printf %()T` で外部依存最小化
- `is_gnu_date` を削除（不要化）

### Fixed
- BSD `date -j -f` の `Z` リテラル扱いによる TZ オフセットずれを `TZ=UTC` 明示で修正

## [v1.17.0] - パフォーマンスチューニング (subshell 削減)

### Changed
- `log_to_file` の `$(date ...)` を bash 内蔵 `printf %()T` に置換 (約 12x 高速)
- `normalize_account_name_full/minimal` の sed パイプを pure bash パラメータ展開に置換
- `create_profile_config` の heredoc サブシェルを単一 `printf` に置換
- Phase 3 ループの `echo | grep` を `${line%% *}` + 正規表現マッチに置換
- 8 アカウント E2E ベンチマーク: ~13.7s → ~8-9s (約 36% 短縮)

## [v1.16.0] - キャッシュ機構と並列処理の実装

### Added
- `lib/common.sh` にキャッシュ層 (`get_cached_accounts` / `get_cached_roles` 等) を実装
- `lib/fetch-account-roles.sh` ワーカースクリプト
- `xargs -P` によるアカウント単位並列化
- `--refresh-cache` / `--parallel N` フラグ
- `test/test-cache.sh` が動作可能化

### Changed
- 200 アカウント環境で初回 200s → 25s、2 回目以降 2s に短縮

## [v1.15.0] - 事故防止のための安全対策強化とリポジトリ整理

### Added
- shellcheck GitHub Actions ワークフロー
- バックアップ 10 世代ローテーション
- AWS_SSO_CONFIG_GENERATOR マーカー整合性チェック

### Changed
- 全スクリプトに `set -euo pipefail` を統一
- 未追跡ファイル整理 (`.aws-sso-cache/` を `.gitignore` に追加等)

## [v1.14.0] - バグ修正

### Fixed
- unbound variable、`grep -c` 二重出力、スピナー描画順序

## v1.12.0 以前

### v1.12.0
- ディレクトリ構造のリファクタリング (`lib/` 集約)
- `check.sh` のサブコマンド形式

### v1.10.0
- デフォルトプレフィックス `autogen` → `awssso` に変更
- クイックスタートに前提条件セクション追加
- `setup-aws-sso.sh` → `check-environment.sh` にリネーム

### v1.9.2
- `--help`/`--force` オプション追加、デフォルト処理アカウント数を全アカウントに

### v1.9.1
- プログレス表示形式の改善

### v1.9
- プログレス表示機能と複数ブロック対応

### v1.8
- shellcheck 完全対応、テストディレクトリ作成

### v1.7
- プロファイル品質チェック機能追加

### v1.6
- リージョン設定確認機能強化

### v1.5
- ツール名変更とブランディング統一

### v1.4
- プロファイル分析機能追加

### v1.3
- 複数 SSO Session 対応

### v1.2
- 管理機能強化

### v1.1
- 自動生成機能追加

### v1.0
- 基本機能実装
