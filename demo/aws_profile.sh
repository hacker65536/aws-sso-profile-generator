# fzf で AWS_PROFILE を切り替えるヘルパー（README の Tips と同一内容）
aws_profile() {
    local p
    p=$(aws configure list-profiles | grep '^awssso-' | fzf --prompt='AWS Profile > ') || return
    [ -n "$p" ] && export AWS_PROFILE="$p" && echo "AWS_PROFILE=$p"
}
