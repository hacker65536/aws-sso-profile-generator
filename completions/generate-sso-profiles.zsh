#compdef generate-sso-profiles.sh cleanup-generated-profiles.sh check.sh
# zsh completion for AWS SSO Profile Generator
# 使い方:
#   1. fpath に completions/ を追加: fpath=(.../completions $fpath)
#   2. compinit を実行
# または zsh 起動時に source completions/generate-sso-profiles.zsh

_generate_sso_profiles_cmd() {
    _arguments \
        '(--help -h)'{--help,-h}'[ヘルプを表示]' \
        '(--force -f)'{--force,-f}'[デフォルト値で自動実行 (対話なし)]' \
        '--refresh-cache[既存キャッシュを削除してから API を再取得]' \
        '--dry-run[設定ファイルを変更せず、生成予定のプロファイルだけ表示]' \
        '--parallel[並列度]:N:(1 2 4 8 12 16 24 32)' \
        "--account-filter[アカウント名 glob (例: 'prod-*')]:PATTERN:" \
        "--role-filter[ロール名 glob (例: 'AWSReadOnly*')]:PATTERN:"
}

_cleanup_generated_profiles_cmd() {
    _arguments \
        '(--help -h)'{--help,-h}'[ヘルプを表示]' \
        '--dry-run[削除予定を表示するだけで実ファイルは変更しない]' \
        '--session[特定セッションのみ削除]:SESSION_NAME:'
}

_check_sh_cmd() {
    local -a commands
    commands=(
        'tools:必要ツールの確認'
        'aws-config:AWS 設定ファイルの確認'
        'sso-config:SSO 設定の確認'
        'sso-profiles:SSO プロファイルの分析'
        'cache:キャッシュ管理'
        'help:ヘルプを表示'
    )

    if (( CURRENT == 2 )); then
        _describe 'command' commands
        return
    fi

    case "${words[2]}" in
        sso-profiles)
            local -a subcmds=(
                'analyze:全プロファイル分析'
                'auto:自動生成プロファイル詳細'
                'manual:手動管理プロファイル詳細'
                'duplicates:重複チェック'
            )
            _describe 'subcommand' subcmds
            ;;
        cache)
            local -a subcmds=(
                'stats:キャッシュ統計 (デフォルト)'
                'clear:全 or セッション単位削除'
                'validate:期限切れファイル一覧'
                'help:ヘルプ'
            )
            _describe 'subcommand' subcmds
            ;;
    esac
}

# サービス名でディスパッチ
case "$service" in
    generate-sso-profiles.sh) _generate_sso_profiles_cmd "$@" ;;
    cleanup-generated-profiles.sh) _cleanup_generated_profiles_cmd "$@" ;;
    check.sh) _check_sh_cmd "$@" ;;
esac
