#!/usr/bin/env bash
# 純関数の単体テスト
# - normalize_account_name_full / normalize_account_name_minimal
# - cache_session_hash の安定性
# - trim_trailing_empty_lines
# - extract_auto_profiles / extract_profile_names
# - parse_utc_to_epoch
# - perf_diff の整数 / 小数モード

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_ROOT/lib/common.sh"
# generate-sso-profiles.sh の normalize 関数を取り出すため部分 source
# (main 呼び出しを避けるため eval で関数定義だけ抽出)
eval "$(awk '
    /^normalize_account_name_(full|minimal)\(\)/, /^\}$/ { print }
' "$SCRIPT_ROOT/generate-sso-profiles.sh")"

echo "🧪 純関数の単体テスト"
echo "========================="

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        echo "     expected: '$expected'"
        echo "     actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

# ----------------------------------------------------------------------------
# normalize_account_name_minimal
# ----------------------------------------------------------------------------
echo
echo "[normalize_account_name_minimal]"
assert_eq "スペース→アンダースコア" \
    "My_Perfect-Web-Service_Prod" \
    "$(normalize_account_name_minimal 'My Perfect-Web-Service Prod')"
assert_eq "ハイフン保持" "acct-one" "$(normalize_account_name_minimal 'acct-one')"
assert_eq "実データ (llmgw)" "llmgw-bundle-br001-prod" \
    "$(normalize_account_name_minimal 'llmgw-bundle-br001-prod')"
assert_eq "連続スペース" "a__b" "$(normalize_account_name_minimal 'a  b')"
assert_eq "特殊文字除去" "abc123" "$(normalize_account_name_minimal 'abc!@#$%^&*()123')"

# ----------------------------------------------------------------------------
# normalize_account_name_full
# ----------------------------------------------------------------------------
echo
echo "[normalize_account_name_full]"
assert_eq "小文字化 + スペース/ハイフン" \
    "my_perfect_web_service_prod" \
    "$(normalize_account_name_full 'My Perfect-Web-Service Prod')"
assert_eq "ハイフン→アンダースコア" "acct_one" "$(normalize_account_name_full 'acct-one')"
assert_eq "数字保持" "123account" "$(normalize_account_name_full '数字123Account')"

# ----------------------------------------------------------------------------
# cache_session_hash の安定性
# ----------------------------------------------------------------------------
echo
echo "[cache_session_hash]"
h1=$(cache_session_hash "https://test.example.awsapps.com/start/")
h2=$(cache_session_hash "https://test.example.awsapps.com/start/")
assert_eq "同じ URL で同じ hash" "$h1" "$h2"
h3=$(cache_session_hash "https://different.example.awsapps.com/start/")
assert_true "異なる URL で異なる hash" [ "$h1" != "$h3" ]
assert_true "hash 長 8 桁" [ "${#h1}" = "8" ]

# ----------------------------------------------------------------------------
# trim_trailing_empty_lines
# ----------------------------------------------------------------------------
echo
echo "[trim_trailing_empty_lines]"
TMP=$(mktemp)
printf 'line1\n\nline2\n\n\n' > "$TMP"
trim_trailing_empty_lines "$TMP"
lines=$(wc -l < "$TMP" | tr -d ' ')
# 入力 5 行 (line1, '', line2, '', '') → trim 後 3 行 (line1, '', line2)
assert_eq "末尾 2 空行除去 (3 行になる)" "3" "$lines"
# 中間空行が保持されているか
assert_true "中間空行保持" grep -q '^$' "$TMP"
rm -f "$TMP"

# 空ファイルの場合
TMP=$(mktemp)
trim_trailing_empty_lines "$TMP"
assert_true "空ファイルでも壊さない" [ -f "$TMP" ]
rm -f "$TMP"

# ----------------------------------------------------------------------------
# extract_auto_profiles / extract_profile_names
# ----------------------------------------------------------------------------
echo
echo "[extract_auto_profiles]"
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
[profile manual-1]
region = us-east-1

# AWS_SSO_CONFIG_GENERATOR START 2026/05/27 00:00:00
[profile awssso-A]
sso_session = s
[profile awssso-B]
sso_session = s
# AWS_SSO_CONFIG_GENERATOR END 2026/05/27 00:00:00

[profile manual-2]
region = us-west-2
EOF
result=$(extract_auto_profiles "$TMP" | tr '\n' ',' | sed 's/,$//')
assert_eq "auto block 内のみ抽出 (sort 済)" "awssso-A,awssso-B" "$result"
rm -f "$TMP"

echo "[extract_profile_names]"
result=$(printf '[profile X]\nsso_session = s\n[profile Y]\n[notprofile]\n' | extract_profile_names | tr '\n' ',' | sed 's/,$//')
assert_eq "stdin から profile 名のみ抽出" "X,Y" "$result"

# ----------------------------------------------------------------------------
# parse_utc_to_epoch
# ----------------------------------------------------------------------------
echo
echo "[parse_utc_to_epoch]"
# 2025-01-01T00:00:00Z = 1735689600 (UTC)
epoch=$(parse_utc_to_epoch "2025-01-01T00:00:00Z")
assert_eq "2025-01-01T00:00:00Z → 1735689600" "1735689600" "$epoch"
# Unix epoch
epoch=$(parse_utc_to_epoch "1970-01-01T00:00:00Z")
assert_eq "1970-01-01T00:00:00Z → 0" "0" "$epoch"

# ----------------------------------------------------------------------------
# perf_diff
# ----------------------------------------------------------------------------
echo
echo "[perf_diff]"
assert_eq "整数モード (100-50)" "50" "$(perf_diff 50 100)"
diff=$(perf_diff "1000.000" "1001.234")
assert_eq "小数モード (1001.234-1000.000)" "1.234" "$diff"

# ----------------------------------------------------------------------------
# 結果サマリ
# ----------------------------------------------------------------------------
echo
echo "========================="
echo "📊 単体テスト結果"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "🎉 全単体テスト通過"
exit 0
