# Shell 補完スクリプト

`generate-sso-profiles.sh` / `cleanup-generated-profiles.sh` / `check.sh` のオプション・サブコマンド補完を提供します。

## Bash

```bash
# 一時的に有効化
source ./completions/generate-sso-profiles.bash

# 永続化
echo "source $(pwd)/completions/generate-sso-profiles.bash" >> ~/.bashrc
```

## Zsh

```zsh
# fpath に追加して compinit
fpath=(/path/to/aws-sso-profile-generator/completions $fpath)
autoload -Uz compinit && compinit

# または直接 source (簡易)
source ./completions/generate-sso-profiles.zsh
```

## 補完される内容

| コマンド | 補完対象 |
|---|---|
| `generate-sso-profiles.sh` | `--help` `--force` `--refresh-cache` `--dry-run` `--parallel <N>` `--account-filter <PATTERN>` `--role-filter <PATTERN>` |
| `cleanup-generated-profiles.sh` | `--help` `--dry-run` `--session <NAME>` |
| `check.sh` | `tools` `aws-config` `sso-config` `sso-profiles` `cache` のサブコマンド、`sso-profiles` 下位の `analyze` `auto` `manual` `duplicates`、`cache` 下位の `stats` `clear` `validate` |
| `--parallel` | `1 2 4 8 12 16 24 32` の候補を提示 |
