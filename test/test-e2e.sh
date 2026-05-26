#!/usr/bin/env bash

# AWS SSO Profile Generator - E2E テスト
# mock aws function を export してフルパイプライン (Phase 1/2/3) を検証する
#
# 検証項目:
#   - 8 アカウント × 2 ロール = 16 プロファイルが正しく生成される
#   - 命名規則 awssso-{name}-{id}:{role} に従う
#   - START/END マーカーが 1 ペアで揃う
#   - キャッシュファイル (accounts + roles × N + metadata) が作られる
#   - 2 回目実行でキャッシュヒット (mtime 不変)
#   - --refresh-cache でキャッシュが再取得される (mtime 更新)
#
# 注意:
#   - HOME / AWS_CONFIG_FILE / CACHE_DIR を sandbox に向け、実環境を汚染しない
#   - mktemp で sandbox 作成、trap で確実にクリーンアップ

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX=$(mktemp -d -t aws-sso-e2e.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

echo "🧪 AWS SSO Profile Generator - E2E テスト"
echo "========================================="
echo "Sandbox: $SANDBOX"
echo

# ============================================================================
# Sandbox セットアップ
# ============================================================================

mkdir -p "$SANDBOX/.aws/sso/cache"

# mock AWS_CONFIG_FILE
cat > "$SANDBOX/aws-config" <<'EOF'
[default]
region = ap-northeast-1

[sso-session test-session]
sso_region = ap-northeast-1
sso_start_url = https://test.example.awsapps.com/start/
sso_registration_scopes = sso:account:access
EOF

# mock SSO アクセストークン (有効期限 +1h)
# bash 4.2+ 内蔵の printf %()T で外部 date 不要 (BSD/GNU 検出スキップ)
_now_epoch=0
printf -v _now_epoch '%(%s)T' -1
TZ=UTC printf -v EXPIRES '%(%Y-%m-%dT%H:%M:%SZ)T' "$((_now_epoch + 3600))"

cat > "$SANDBOX/.aws/sso/cache/test-token.json" <<EOF
{
  "startUrl": "https://test.example.awsapps.com/start/",
  "region": "ap-northeast-1",
  "accessToken": "mock-access-token-FAKE-FOR-TESTING",
  "expiresAt": "$EXPIRES"
}
EOF

# ============================================================================
# mock aws function (関数 export 経由で xargs → bash → worker まで伝播)
# ============================================================================

aws() {
    case "$1 $2" in
        "sso list-accounts")
            cat <<'EOF2'
{"accountList":[
  {"accountId":"100000000001","accountName":"acct-one","emailAddress":"one@example.com"},
  {"accountId":"100000000002","accountName":"acct-two","emailAddress":"two@example.com"},
  {"accountId":"100000000003","accountName":"acct-three","emailAddress":"three@example.com"},
  {"accountId":"100000000004","accountName":"acct-four","emailAddress":"four@example.com"},
  {"accountId":"100000000005","accountName":"acct-five","emailAddress":"five@example.com"},
  {"accountId":"100000000006","accountName":"acct-six","emailAddress":"six@example.com"},
  {"accountId":"100000000007","accountName":"acct-seven","emailAddress":"seven@example.com"},
  {"accountId":"100000000008","accountName":"acct-eight","emailAddress":"eight@example.com"}
]}
EOF2
            ;;
        "sso list-account-roles")
            local aid="" prev=""
            for arg in "$@"; do
                if [ "$prev" = "--account-id" ]; then aid="$arg"; break; fi
                prev="$arg"
            done
            # API 遅延を僅かにシミュレートして並列効果を可視化 (テスト総時間 < 3s)
            sleep 0.1
            cat <<EOF2
{"roleList":[
  {"roleName":"AWSReadOnlyAccess","accountId":"$aid"},
  {"roleName":"AWSAdministratorAccess","accountId":"$aid"}
]}
EOF2
            ;;
        "configure list")
            echo "  region                ap-northeast-1   config-file    $AWS_CONFIG_FILE"
            ;;
        "configure get")
            echo "ap-northeast-1"
            ;;
        *)
            echo "MOCK: unhandled aws command: $*" >&2
            return 1
            ;;
    esac
}
export -f aws

# ============================================================================
# 環境変数 (sandbox に閉じ込める)
# ============================================================================

export HOME="$SANDBOX"
export AWS_CONFIG_FILE="$SANDBOX/aws-config"
export CACHE_DIR="$SANDBOX/.aws-sso-cache"
export CACHE_EXPIRY_HOURS=24
unset AWS_PROFILE || true

cd "$SCRIPT_ROOT"

# ============================================================================
# Assertion ヘルパー
# ============================================================================

PASS=0
FAIL=0
RUN_LOG="$SANDBOX/run.log"

assert() {
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

# ============================================================================
# Test 1: 初回実行 (--force --parallel 4)
# ============================================================================

echo "Test 1: 初回実行 (--force --parallel 4)"
SECONDS=0
if bash generate-sso-profiles.sh --force --parallel 4 > "$RUN_LOG" 2>&1; then
    echo "  ⏱  実行時間: ${SECONDS} 秒"
else
    echo "  ❌ generate-sso-profiles.sh が異常終了 (rc=$?)"
    tail -20 "$RUN_LOG" | sed 's/^/    > /'
    FAIL=$((FAIL + 1))
fi

profile_count=$(grep -c "^\[profile awssso-" "$AWS_CONFIG_FILE" 2>/dev/null || echo 0)
assert "16 プロファイル生成 (8 アカウント × 2 ロール)" [ "$profile_count" -eq 16 ]

cache_total=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
assert "キャッシュファイル 10 個 (accounts 1 + roles 8 + metadata 1)" [ "$cache_total" -eq 10 ]

assert "命名規則: awssso-acct-one-100000000001:AWSReadOnlyAccess" \
    grep -q "^\[profile awssso-acct-one-100000000001:AWSReadOnlyAccess\]" "$AWS_CONFIG_FILE"

start_count=$(grep -c "^# AWS_SSO_CONFIG_GENERATOR START" "$AWS_CONFIG_FILE" 2>/dev/null || echo 0)
end_count=$(grep -c "^# AWS_SSO_CONFIG_GENERATOR END" "$AWS_CONFIG_FILE" 2>/dev/null || echo 0)
assert "START マーカーが 1 個" [ "$start_count" = "1" ]
assert "END マーカーが 1 個" [ "$end_count" = "1" ]

assert "metadata.json が存在" [ -f "$CACHE_DIR/metadata.json" ]

# ============================================================================
# Test 2: 2 回目実行 (キャッシュヒット、mtime 不変を確認)
# ============================================================================

echo
echo "Test 2: 2 回目実行 (キャッシュヒット期待)"

# 代表的なキャッシュファイルの mtime を記録
SAMPLE_CACHE=$(find "$CACHE_DIR" -maxdepth 1 -type f -name "roles-100000000001-*.json" | head -1)
mtime_before=$(stat -f %m "$SAMPLE_CACHE" 2>/dev/null || stat -c %Y "$SAMPLE_CACHE")

sleep 1  # mtime 分解能 (秒) を超えるため
SECONDS=0
if bash generate-sso-profiles.sh --force --parallel 4 > "$RUN_LOG" 2>&1; then
    echo "  ⏱  実行時間: ${SECONDS} 秒"
else
    echo "  ❌ 2 回目実行が異常終了"
    tail -20 "$RUN_LOG" | sed 's/^/    > /'
    FAIL=$((FAIL + 1))
fi

mtime_after=$(stat -f %m "$SAMPLE_CACHE" 2>/dev/null || stat -c %Y "$SAMPLE_CACHE")
assert "キャッシュ mtime 不変 (= API 再呼び出しなし)" \
    [ "$mtime_before" = "$mtime_after" ]

profile_count_2=$(grep -c "^\[profile awssso-" "$AWS_CONFIG_FILE" 2>/dev/null || echo 0)
assert "プロファイル数同一 (16)" [ "$profile_count_2" -eq 16 ]

# Phase 2 統計のログ確認 (LOG_FILE は $HOME/.aws/ 配下)
latest_log=$(ls -t "$SANDBOX/.aws/sso-profile-generator-"*.log 2>/dev/null | head -1)
if [ -n "$latest_log" ] && grep -q "cache hit=8" "$latest_log"; then
    echo "  ✅ ログに 'cache hit=8' が記録されている"
    PASS=$((PASS + 1))
else
    echo "  ❌ ログに 'cache hit=8' が見つからない"
    [ -n "$latest_log" ] && echo "    log: $latest_log"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: --refresh-cache で再取得 (mtime 更新)
# ============================================================================

echo
echo "Test 3: --refresh-cache でキャッシュ再取得"

# refresh で sample cache file はいったん削除 → 新規作成される
sleep 1
SECONDS=0
if bash generate-sso-profiles.sh --force --refresh-cache --parallel 8 > "$RUN_LOG" 2>&1; then
    echo "  ⏱  実行時間: ${SECONDS} 秒"
else
    echo "  ❌ refresh-cache 実行が異常終了"
    tail -20 "$RUN_LOG" | sed 's/^/    > /'
    FAIL=$((FAIL + 1))
fi

SAMPLE_CACHE_NEW=$(find "$CACHE_DIR" -maxdepth 1 -type f -name "roles-100000000001-*.json" | head -1)
mtime_refresh=$(stat -f %m "$SAMPLE_CACHE_NEW" 2>/dev/null || stat -c %Y "$SAMPLE_CACHE_NEW")
assert "--refresh-cache で mtime が更新" \
    [ "$mtime_refresh" -gt "$mtime_after" ]

profile_count_3=$(grep -c "^\[profile awssso-" "$AWS_CONFIG_FILE" 2>/dev/null || echo 0)
assert "refresh 後もプロファイル数 16" [ "$profile_count_3" -eq 16 ]

# ============================================================================
# Test 4: --dry-run モード (設定ファイル変更なしを md5 で確認)
# ============================================================================

echo
echo "Test 4: --dry-run モード (設定ファイル変更なしを確認)"

# 現在の config の md5 を保存
md5_before=$(md5 -q "$AWS_CONFIG_FILE" 2>/dev/null || md5sum "$AWS_CONFIG_FILE" | awk '{print $1}')

SECONDS=0
if bash generate-sso-profiles.sh --force --dry-run --parallel 8 > "$RUN_LOG" 2>&1; then
    echo "  ⏱  実行時間: ${SECONDS} 秒"
else
    echo "  ❌ --dry-run 実行が異常終了"
    tail -20 "$RUN_LOG" | sed 's/^/    > /'
    FAIL=$((FAIL + 1))
fi

md5_after=$(md5 -q "$AWS_CONFIG_FILE" 2>/dev/null || md5sum "$AWS_CONFIG_FILE" | awk '{print $1}')

assert "--dry-run で config の md5 が不変" [ "$md5_before" = "$md5_after" ]
assert "--dry-run 出力に DRY-RUN マーカーが含まれる" grep -q "DRY-RUN" "$RUN_LOG"
assert "--dry-run プレビューに 16 件と表示される" grep -q "16 profiles would be generated" "$RUN_LOG"

# ============================================================================
# Test 5: Diff 表示 (再実行で「変更なし」と出る)
# ============================================================================

echo
echo "Test 5: Diff 表示 (連続再実行で変更なし期待)"

if bash generate-sso-profiles.sh --force --parallel 8 > "$RUN_LOG" 2>&1; then
    :
else
    echo "  ❌ Test 5 実行が異常終了"
    FAIL=$((FAIL + 1))
fi
assert "Diff: 前回と同一 (変更なし)" grep -q "No changes since last run" "$RUN_LOG"

# ============================================================================
# 結果サマリ
# ============================================================================

echo
echo "========================================="
echo "📊 E2E テスト結果"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo

if [ "$FAIL" -gt 0 ]; then
    echo "❌ E2E テスト失敗"
    exit 1
fi

echo "🎉 全 E2E テスト通過"
exit 0
