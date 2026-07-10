#!/usr/bin/env bash
# Record the aws-sso-profiles terminal demo into demo/aws-sso-profiles.gif.
#
# Deterministic and offline: a throwaway binary is built and driven against the
# committed fixtures via ASP_FAKE_INVENTORY, so no real AWS account or SSO login
# is involved. Re-running always starts from the same clean state (fixtures are
# copied into a fresh scratch dir every time).
#
# Requires: go, vhs (https://github.com/charmbracelet/vhs), ffmpeg.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

command -v vhs >/dev/null 2>&1 || { echo "vhs not found (brew install vhs)" >&2; exit 1; }

# 1) Build a throwaway binary and put it first on PATH.
bindir="$(mktemp -d)"
trap 'rm -rf "$bindir" "${work:-}"' EXIT
go build -o "$bindir/aws-sso-profiles" ./cmd/aws-sso-profiles

# 2) Fresh scratch workspace seeded from the immutable fixtures.
work="$(mktemp -d)"
cp demo/config.yaml "$work/.aws-sso-profiles.yaml"
cp demo/aws_config  "$work/aws_config"
cp demo/inv.json    "$work/inv.json"

# 3) Environment inherited by the VHS shell.
export PATH="$bindir:$PATH"
export WORK="$work"
export AWS_CONFIG_FILE="$work/aws_config"
export ASP_FAKE_INVENTORY="$work/inv.json"

# 4) Record. Output path in the tape is repo-relative, so run from repo root.
vhs demo/demo.tape

echo "wrote $repo/demo/aws-sso-profiles.gif"
