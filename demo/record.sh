#!/usr/bin/env bash
# Record the aws-sso-profiles terminal demos:
#   demo/demo.tape           -> demo/aws-sso-profiles.gif  (plan/apply lifecycle)
#   demo/profile-switch.tape -> demo/aws-profile-fzf.gif   (daily use: fzf switcher)
#
# Deterministic and offline: a throwaway binary is built and driven against the
# committed fixtures via ASP_FAKE_INVENTORY, so no real AWS account or SSO login
# is involved. Re-running always starts from the same clean state (fixtures are
# copied into a fresh scratch dir per tape).
#
# Requires: go, vhs (https://github.com/charmbracelet/vhs), ffmpeg.
# profile-switch.tape additionally requires: fzf, AWS CLI v2 (offline use only).
#
# Usage: bash demo/record.sh [tape ...]   # default: all tapes
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

command -v vhs >/dev/null 2>&1 || { echo "vhs not found (brew install vhs)" >&2; exit 1; }

tapes=("$@")
[ ${#tapes[@]} -eq 0 ] && tapes=(demo/demo.tape demo/profile-switch.tape)

# 1) Build a throwaway binary and put it first on PATH.
bindir="$(mktemp -d)"
trap 'rm -rf "$bindir" "${work:-}"' EXIT
go build -o "$bindir/aws-sso-profiles" ./cmd/aws-sso-profiles
export PATH="$bindir:$PATH"

for tape in "${tapes[@]}"; do
    # 2) Fresh scratch workspace seeded from the immutable fixtures.
    rm -rf "${work:-}"
    work="$(mktemp -d)"
    cp demo/config.yaml    "$work/.aws-sso-profiles.yaml"
    cp demo/aws_config     "$work/aws_config"
    cp demo/inv.json       "$work/inv.json"
    cp demo/aws_profile.sh "$work/aws_profile.sh"

    # 3) Environment inherited by the VHS shell. AWS_SHARED_CREDENTIALS_FILE
    #    points into the scratch dir (nonexistent) so `aws configure
    #    list-profiles` never sees the operator's real credentials file.
    export WORK="$work"
    export AWS_CONFIG_FILE="$work/aws_config"
    export AWS_SHARED_CREDENTIALS_FILE="$work/credentials"
    export ASP_FAKE_INVENTORY="$work/inv.json"

    # 4) Record. Output paths in the tapes are repo-relative, so run from repo root.
    vhs "$tape"
done

echo "recorded: ${tapes[*]}"
