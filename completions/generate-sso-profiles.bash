# bash completion for generate-sso-profiles.sh
# 使い方: source completions/generate-sso-profiles.bash
#   または ~/.bashrc に source 行を追加

# shellcheck disable=SC2207
# 説明: COMPREPLY=( $(compgen ...) ) は bash 公式 completion で広く使われる慣用パターン

_generate_sso_profiles() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="--help -h --force -f --refresh-cache --dry-run --parallel --account-filter --role-filter"

    case "$prev" in
        --parallel)
            COMPREPLY=( $(compgen -W "1 2 4 8 12 16 24 32" -- "$cur") )
            return 0
            ;;
        --account-filter|--role-filter)
            # 候補なし (パターンはユーザが指定)
            return 0
            ;;
    esac

    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}

complete -F _generate_sso_profiles generate-sso-profiles.sh
complete -F _generate_sso_profiles ./generate-sso-profiles.sh

_cleanup_generated_profiles() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="--help -h --dry-run --session"

    case "$prev" in
        --session)
            return 0
            ;;
    esac

    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}

complete -F _cleanup_generated_profiles cleanup-generated-profiles.sh
complete -F _cleanup_generated_profiles ./cleanup-generated-profiles.sh

_check_sh() {
    local cur prev cmds
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "$COMP_CWORD" in
        1)
            cmds="tools aws-config sso-config sso-profiles cache help"
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
            ;;
        2)
            case "${COMP_WORDS[1]}" in
                sso-profiles)
                    COMPREPLY=( $(compgen -W "analyze auto manual duplicates" -- "$cur") )
                    ;;
                cache)
                    COMPREPLY=( $(compgen -W "stats clear validate help" -- "$cur") )
                    ;;
            esac
            ;;
        3)
            case "${COMP_WORDS[1]} ${COMP_WORDS[2]}" in
                "sso-profiles auto"|"sso-profiles manual")
                    COMPREPLY=( $(compgen -W "--all" -- "$cur") )
                    ;;
            esac
            ;;
    esac
}

complete -F _check_sh check.sh
complete -F _check_sh ./check.sh
