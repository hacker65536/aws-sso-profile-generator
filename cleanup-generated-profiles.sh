#!/usr/bin/env bash

# AWS SSO 自動生成プロファイル削除スクリプト
# AWS_SSO_CONFIG_GENERATOR で生成されたプロファイルを削除します

set -e

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

# 削除予定プロファイルの表示
show_profiles_to_delete() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    log_info "削除予定のプロファイル:"
    
    # AWS_SSO_CONFIG_GENERATOR で囲まれたブロック内のプロファイルを抽出
    local in_generator_block=false
    local profile_count=0
    
    while IFS= read -r line; do
        if [[ $line =~ ^#[[:space:]]*AWS_SSO_CONFIG_GENERATOR[[:space:]]+START ]]; then
            in_generator_block=true
            continue
        elif [[ $line =~ ^#[[:space:]]*AWS_SSO_CONFIG_GENERATOR[[:space:]]+END ]]; then
            in_generator_block=false
            continue
        elif [[ $in_generator_block == true ]] && [[ $line =~ ^\[profile[[:space:]]+(.+)\] ]]; then
            local profile_name="${BASH_REMATCH[1]}"
            echo "  - $profile_name"
            profile_count=$((profile_count + 1))
        fi
    done < "$config_file"
    
    if [ $profile_count -eq 0 ]; then
        echo "  (削除対象のプロファイルはありません)"
    else
        echo
        log_info "削除予定プロファイル数: $profile_count 個"
    fi
}

# 自動生成プロファイルの確認
check_generated_profiles() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_error "AWS設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    # AWS_SSO_CONFIG_GENERATOR コメントの検索
    local generator_blocks
    generator_blocks=$(grep -n "AWS_SSO_CONFIG_GENERATOR" "$config_file" 2>/dev/null || true)
    
    if [ -z "$generator_blocks" ]; then
        log_info "自動生成されたプロファイルは見つかりませんでした"
        return 1
    fi
    
    log_info "自動生成プロファイルブロックを検出しました:"
    echo "$generator_blocks"
    echo
    
    return 0
}

# 自動生成プロファイルの削除
remove_generated_profiles() {
    local config_file="$1"
    
    log_info "設定ファイルのバックアップを作成中..."
    local backup_file
    backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$config_file" "$backup_file"
    log_success "バックアップファイルを作成しました: $backup_file"
    
    log_info "自動生成プロファイルを削除中..."
    
    # AWS_SSO_CONFIG_GENERATOR で囲まれたブロックを削除
    # sedを使用してSTARTからENDまでのブロックを削除
    sed -i.tmp '/^# AWS_SSO_CONFIG_GENERATOR START/,/^# AWS_SSO_CONFIG_GENERATOR END/d' "$config_file"
    
    # 一時ファイルを削除
    rm -f "${config_file}.tmp"
    
    log_success "自動生成プロファイルを削除しました"
}

# 削除結果の確認
verify_cleanup() {
    local config_file="$1"
    
    log_info "削除結果を確認中..."
    
    local remaining_blocks
    remaining_blocks=$(grep -n "AWS_SSO_CONFIG_GENERATOR" "$config_file" 2>/dev/null || true)
    
    if [ -z "$remaining_blocks" ]; then
        log_success "すべての自動生成プロファイルが正常に削除されました"
        return 0
    else
        log_warning "一部の自動生成プロファイルが残っている可能性があります:"
        echo "$remaining_blocks"
        return 1
    fi
}



# メイン実行
main() {
    echo "🗑️  AWS SSO 自動生成プロファイル削除"
    echo "====================================="
    echo
    
    # 設定ファイルの取得
    local config_file
    config_file=$(get_config_file)
    
    log_info "設定ファイル: $config_file"
    echo
    
    # 削除前の統計を取得
    local before_stats
    before_stats=$(get_profile_stats_data "$config_file")
    
    # 削除前の統計表示
    log_info "削除前の状態:"
    echo
    show_profile_stats "$config_file"
    echo
    
    # 自動生成プロファイルの確認
    if ! check_generated_profiles "$config_file"; then
        log_info "削除対象のプロファイルがありません"
        exit 0
    fi
    
    # 削除予定プロファイルの表示
    echo
    show_profiles_to_delete "$config_file"
    
    # 削除確認
    echo
    log_warning "自動生成されたプロファイル（AWS_SSO_CONFIG_GENERATOR）をすべて削除します"
    read -r -p "続行しますか？ (y/n): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "削除をキャンセルしました"
        exit 0
    fi
    
    echo
    
    # プロファイル削除の実行
    remove_generated_profiles "$config_file"
    
    echo
    
    # 削除結果の確認
    verify_cleanup "$config_file"
    
    # 削除後の統計を取得
    local after_stats
    after_stats=$(get_profile_stats_data "$config_file")
    
    # 削除後の統計表示
    echo
    log_info "削除後の状態:"
    echo
    show_profile_stats "$config_file"
    
    # diff形式での変更表示
    echo
    log_info "変更内容 (diff形式):"
    show_profile_diff "$before_stats" "$after_stats"
    
    echo
    log_success "自動生成プロファイルの削除が完了しました！"
}

# スクリプト実行
main "$@"