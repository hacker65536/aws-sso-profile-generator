#!/usr/bin/env bash

# AWS SSO ロール取得ワーカー (xargs -P から並列に呼ばれる)
#
# 引数:
#   $1 = account_id
#   $2 = output_dir (結果ファイルを書き込むディレクトリ)
#
# 入力:
#   ACCESS_TOKEN, SSO_SESSION_NAME, SSO_START_URL, SSO_REGION 環境変数
#   (親プロセスが export していることを期待)
#
# 出力ファイル:
#   $output_dir/<account_id>.roles  成功時: ロール名を 1 行 1 件で出力
#   $output_dir/<account_id>.err    失敗時: エラー詳細を 1 行で出力
#
# 標準出力 (親が集約用に capture):
#   "hit <account_id>"            キャッシュヒット
#   "fetch <account_id>"          API 呼び出して取得
#   "err <account_id> <reason>"   失敗

set -euo pipefail

# 引数チェック
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <account_id> <output_dir>" >&2
    exit 2
fi

account_id="$1"
output_dir="$2"

# common.sh の読み込み (SCRIPT_DIR は本ファイルの場所基準)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# 必須環境変数の確認
: "${ACCESS_TOKEN:?ACCESS_TOKEN が未設定です}"
: "${SSO_SESSION_NAME:?SSO_SESSION_NAME が未設定です}"
: "${SSO_START_URL:?SSO_START_URL が未設定です}"

# 出力ディレクトリの確認
if [ ! -d "$output_dir" ]; then
    echo "err ${account_id} output_dir_missing"
    exit 1
fi

# キャッシュヒットかどうかを事前判定 (ログ用)
hash=$(cache_session_hash "$SSO_START_URL")
cache_file=$(cache_file_roles "$account_id" "$hash")
was_cached="no"
if is_cache_valid "$cache_file"; then
    was_cached="yes"
fi

# ロール取得 (キャッシュ経由、ミス時のみ API)
roles_json=""
if roles_json=$(get_cached_roles "$account_id" "$ACCESS_TOKEN" "$SSO_SESSION_NAME" "$SSO_START_URL" 2>/dev/null); then
    # ロール名のみを 1 行ずつ出力
    if ! echo "$roles_json" | jq -r '.roleList[].roleName' > "${output_dir}/${account_id}.roles" 2>/dev/null; then
        echo "ロール JSON の解析に失敗しました" > "${output_dir}/${account_id}.err"
        echo "err ${account_id} jq_parse_failed"
        exit 1
    fi

    if [ "$was_cached" = "yes" ]; then
        echo "hit ${account_id}"
    else
        echo "fetch ${account_id}"
    fi
    exit 0
else
    echo "ロール一覧の取得に失敗しました (API 呼び出し失敗またはレスポンス不正)" > "${output_dir}/${account_id}.err"
    echo "err ${account_id} fetch_failed"
    exit 1
fi
