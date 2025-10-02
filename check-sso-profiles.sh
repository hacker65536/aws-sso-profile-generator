#!/usr/bin/env bash

# AWS SSO プロファイル分析スクリプト
# 自動生成プロファイルと手動プロファイルの分析・一覧表示を行います

set -e

# 共通関数とカラー設定を読み込み
source "$(dirname "$0")/common.sh"

# BSD/GNU grep対応の安全なカウント関数
safe_grep_count() {
    local pattern="$1"
    local file="$2"
    
    # ファイルが存在しない、または空の場合は0を返す
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo "0"
        return 0
    fi
    
    # grepでカウント（BSD/GNU grep両対応）
    local count
    count=$(grep -c "$pattern" "$file" 2>/dev/null)
    local exit_code=$?
    
    # grepが何も見つからない場合（exit code 1）は0を返す
    if [ $exit_code -eq 1 ]; then
        echo "0"
    elif [ $exit_code -eq 0 ]; then
        echo "$count"
    else
        # その他のエラー（ファイル読み込みエラーなど）
        echo "0"
    fi
}

# パイプ入力に対する安全なgrepカウント
safe_pipe_grep_count() {
    local pattern="$1"
    local input="$2"
    
    # 入力が空の場合は0を返す
    if [ -z "$input" ]; then
        echo "0"
        return 0
    fi
    
    # grepでカウント（BSD/GNU grep両対応）
    local count
    count=$(echo "$input" | grep -c "$pattern" 2>/dev/null)
    local exit_code=$?
    
    # grepが何も見つからない場合（exit code 1）は0を返す
    if [ $exit_code -eq 1 ]; then
        echo "0"
    elif [ $exit_code -eq 0 ]; then
        echo "$count"
    else
        # その他のエラー
        echo "0"
    fi
}

# 安全な数値取得
safe_number() {
    local value="$1"
    # 最初の数値のみを取得し、空の場合は0を返す
    value=$(echo "$value" | head -1 | tr -d '\n\r' | sed 's/[^0-9]//g')
    if [ -z "$value" ]; then
        echo "0"
    else
        echo "$value"
    fi
}

# 安全なsedコマンド実行
safe_sed_range() {
    local start_line="$1"
    local end_line="$2"
    local file="$3"
    
    # 行番号が数値かつ空でないことを確認
    if [[ "$start_line" =~ ^[0-9]+$ ]] && [[ "$end_line" =~ ^[0-9]+$ ]] && [ "$start_line" -le "$end_line" ]; then
        sed -n "${start_line},${end_line}p" "$file" 2>/dev/null
    else
        echo ""
    fi
}

# 重複プロファイルのチェック
check_duplicate_profiles() {
    local config_file="$1"
    
    # 全プロファイル名を取得
    local all_profiles
    all_profiles=$(grep "^\[profile " "$config_file" 2>/dev/null | sed 's/\[profile \(.*\)\]/\1/' | sort)
    
    if [ -z "$all_profiles" ]; then
        return 0
    fi
    
    # 重複をチェック
    local duplicates
    duplicates=$(echo "$all_profiles" | uniq -d)
    
    if [ -n "$duplicates" ]; then
        echo
        echo "⚠️  重複プロファイル検出:"
        local duplicate_count
        duplicate_count=$(echo "$duplicates" | wc -l | tr -d ' ')
        echo "  重複プロファイル数: $duplicate_count 個"
        echo
        echo "  重複しているプロファイル名:"
        echo "$duplicates" | while IFS= read -r profile; do
            if [ -n "$profile" ]; then
                # 重複回数を取得
                local count
                count=$(echo "$all_profiles" | grep -c "^$profile$")
                echo "    - $profile (${count}回定義)"
            fi
        done
        echo
        log_warning "重複プロファイルが検出されました"
        log_info "重複プロファイルは予期しない動作の原因となる可能性があります"
        log_info "設定ファイルを確認して重複を解消することを推奨します"
    else
        echo
        echo "✅ 重複プロファイルチェック: 重複なし"
    fi
}

# プロファイル分析の実行
analyze_profiles() {
    local config_file="$1"
    
    log_info "プロファイル分析中..."
    log_info "設定ファイル: $config_file"
    echo
    
    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    # 自動生成プロファイルの検出
    local auto_generated_count=0
    local auto_start_line=""
    local auto_end_line=""
    
    auto_start_line=$(grep -n "# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null | cut -d: -f1 || echo "")
    auto_end_line=$(grep -n "# AWS_SSO_CONFIG_GENERATOR END" "$config_file" 2>/dev/null | cut -d: -f1 || echo "")
    
    if [ -n "$auto_start_line" ] && [ -n "$auto_end_line" ] && [ "$auto_start_line" != "" ] && [ "$auto_end_line" != "" ]; then
        auto_generated_count=$(safe_pipe_grep_count "^\[profile " "$(safe_sed_range "$auto_start_line" "$auto_end_line" "$config_file")")
    fi
    
    # auto_generated_countが空文字列の場合は0に設定
    auto_generated_count=$(safe_number "$auto_generated_count")
    
    # 全プロファイル数の取得
    local total_profiles
    total_profiles=$(safe_grep_count "^\[profile " "$config_file")
    
    # 手動管理プロファイル数（自動生成以外の全て）
    local manual_count
    # 数値の安全な計算
    total_profiles=$(safe_number "$total_profiles")
    auto_generated_count=$(safe_number "$auto_generated_count")
    manual_count=$((total_profiles - auto_generated_count))
    
    # 分析結果の表示
    log_success "プロファイル分析結果"
    echo
    echo "📊 プロファイル統計:"
    echo "  全プロファイル数: $total_profiles"
    echo "  自動生成プロファイル: $auto_generated_count"
    echo "  手動管理プロファイル: $manual_count"
    
    # 重複プロファイルのチェック
    check_duplicate_profiles "$config_file"
    
    echo
    
    # 詳細情報の表示
    if [ "${auto_generated_count:-0}" -gt 0 ]; then
        echo "🤖 自動生成プロファイル詳細:"
        local auto_section
        auto_section=$(safe_sed_range "$auto_start_line" "$auto_end_line" "$config_file")
        
        # 生成日時の取得
        local generation_time
        generation_time=$(echo "$auto_section" | head -1 | sed 's/.*START \(.*\)/\1/')
        echo "  生成日時: $generation_time"
        
        # 最初の5個のプロファイル名を表示
        local profile_names
        profile_names=$(echo "$auto_section" | grep "^\[profile " | sed 's/\[profile \(.*\)\]/\1/' | head -5)
        echo "  プロファイル例（最初の5個）:"
        echo "$profile_names" | while IFS= read -r profile; do
            [ -n "$profile" ] && echo "    - $profile"
        done
        
        if [ "${auto_generated_count:-0}" -gt 5 ]; then
            echo "    ... 他 $((auto_generated_count - 5)) 個"
        fi
        echo
    fi
    
    if [ "${manual_count:-0}" -gt 0 ]; then
        echo "✋ 手動管理プロファイル詳細:"
        
        # 自動生成プロファイル以外の全プロファイルを取得
        local temp_file
        local auto_profiles_file
        temp_file=$(mktemp)
        auto_profiles_file=$(mktemp)
        
        # 自動生成プロファイル名を一時ファイルに保存
        if [ -n "$auto_start_line" ] && [ -n "$auto_end_line" ]; then
            safe_sed_range "$auto_start_line" "$auto_end_line" "$config_file" | grep "^\[profile " | sed 's/\[profile \(.*\)\]/\1/' > "$auto_profiles_file"
        fi
        
        # 手動管理プロファイルの最初の5個を表示
        echo "  プロファイル例（最初の5個）:"
        
        # 全プロファイル名を取得
        local all_profiles
        all_profiles=$(grep "^\[profile " "$config_file" | sed 's/\[profile \(.*\)\]/\1/')
        
        # 手動管理プロファイル名を抽出（自動生成以外）
        echo "$all_profiles" | while IFS= read -r profile_name; do
            if ! grep -Fxq "$profile_name" "$auto_profiles_file" 2>/dev/null; then
                echo "$profile_name"
            fi
        done | head -5 | while IFS= read -r profile; do
            echo "    - $profile"
        done
        
        if [ $manual_count -gt 5 ]; then
            echo "    ... 他 $((manual_count - 5)) 個"
        fi
        
        rm -f "$temp_file" "$auto_profiles_file"
        echo
    fi
    

    
    return 0
}

# 自動生成プロファイルの詳細表示
show_auto_generated_details() {
    local config_file="$1"
    local show_all="${2:-false}"
    
    log_info "自動生成プロファイルの詳細確認中..."
    log_info "設定ファイル: $config_file"
    if [ "$show_all" = "true" ]; then
        log_info "表示モード: 全件表示（最大300件）"
    else
        log_info "表示モード: 最初の10件"
    fi
    echo
    
    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    # 自動生成セクションの検索
    local auto_start_line
    local auto_end_line
    
    auto_start_line=$(grep -n "# AWS_SSO_CONFIG_GENERATOR START" "$config_file" | cut -d: -f1)
    auto_end_line=$(grep -n "# AWS_SSO_CONFIG_GENERATOR END" "$config_file" | cut -d: -f1)
    
    if [ -n "$auto_start_line" ] && [ -n "$auto_end_line" ]; then
        local auto_section
        auto_section=$(safe_sed_range "$auto_start_line" "$auto_end_line" "$config_file")
        
        log_success "自動生成プロファイルが見つかりました"
        echo
        
        # 生成情報の表示
        local generation_time
        generation_time=$(echo "$auto_section" | head -1 | sed 's/.*START \(.*\)/\1/')
        echo "📋 自動生成情報:"
        echo "  生成日時: $generation_time"
        
        # プロファイル数のカウント
        local profile_count
        profile_count=$(safe_pipe_grep_count "^\[profile " "$auto_section")
        echo "  プロファイル数: $profile_count 個"
        echo
        
        # プロファイル名の表示
        local display_limit=10
        local display_count=$profile_count
        
        if [ "$show_all" = "true" ]; then
            display_limit=300
            if [ "$profile_count" -gt 300 ]; then
                display_count=300
                echo "🔍 プロファイル一覧（最初の300個）:"
            else
                echo "🔍 プロファイル一覧（全 $profile_count 個）:"
            fi
        else
            if [ "$profile_count" -gt 10 ]; then
                display_count=10
                echo "🔍 プロファイル一覧（最初の10個）:"
            else
                echo "🔍 プロファイル一覧（全 $profile_count 個）:"
            fi
        fi
        
        local profile_names
        profile_names=$(echo "$auto_section" | grep "^\[profile " | sed 's/\[profile \(.*\)\]/\1/' | head -$display_limit)
        
        echo "$profile_names" | while IFS= read -r profile; do
            [ -n "$profile" ] && echo "  - $profile"
        done
        
        if [ "$profile_count" -gt "$display_count" ]; then
            echo "  ... 他 $((profile_count - display_count)) 個"
        fi
        
        return 0
    else
        log_info "自動生成プロファイルは見つかりませんでした"
        echo
        log_info "自動生成プロファイルを作成するには:"
        echo "  ./generate-sso-profiles.sh を実行してください"
        return 1
    fi
}

# 手動管理プロファイルの詳細表示
show_manual_profiles_details() {
    local config_file="$1"
    local show_all="${2:-false}"
    
    log_info "手動管理プロファイルの詳細確認中..."
    log_info "設定ファイル: $config_file"
    if [ "$show_all" = "true" ]; then
        log_info "表示モード: 全件表示（最大300件）"
    else
        log_info "表示モード: 最初の10件"
    fi
    echo
    
    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    # 自動生成プロファイルの範囲を取得
    local auto_start_line
    local auto_end_line
    
    auto_start_line=$(grep -n "# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null | cut -d: -f1 || echo "")
    auto_end_line=$(grep -n "# AWS_SSO_CONFIG_GENERATOR END" "$config_file" 2>/dev/null | cut -d: -f1 || echo "")
    
    # 全プロファイル数の取得
    local total_profiles
    total_profiles=$(safe_grep_count "^\[profile " "$config_file")
    
    # 自動生成プロファイル数の取得
    local auto_generated_count=0
    if [ -n "$auto_start_line" ] && [ -n "$auto_end_line" ] && [ "$auto_start_line" != "" ] && [ "$auto_end_line" != "" ]; then
        auto_generated_count=$(safe_pipe_grep_count "^\[profile " "$(safe_sed_range "$auto_start_line" "$auto_end_line" "$config_file")")
    fi
    
    # 手動管理プロファイル数（自動生成以外の全て）
    local manual_count
    # 数値の安全な計算
    total_profiles=$(safe_number "$total_profiles")
    auto_generated_count=$(safe_number "$auto_generated_count")
    manual_count=$((total_profiles - auto_generated_count))
    
    if [ "${manual_count:-0}" -gt 0 ]; then
        log_success "手動管理プロファイルが見つかりました"
        echo
        
        local temp_file
        local auto_profiles_file
        temp_file=$(mktemp)
        auto_profiles_file=$(mktemp)
        echo "PROFILE SESSION ACCOUNT ROLE REGION" > "$temp_file"
        
        # 自動生成プロファイル名を一時ファイルに保存
        if [ -n "$auto_start_line" ] && [ -n "$auto_end_line" ]; then
            safe_sed_range "$auto_start_line" "$auto_end_line" "$config_file" | grep "^\[profile " | sed 's/\[profile \(.*\)\]/\1/' > "$auto_profiles_file"
        fi
        
        # 手動管理プロファイルの情報を収集（最初の10個まで）
        local count=0
        local sso_session=""
        local account_id=""
        local role_name=""
        local region=""
        
        # より確実なアプローチ：sedとgrepを組み合わせて使用
        local display_limit=10
        if [ "$show_all" = "true" ]; then
            display_limit=300
        fi
        
        local profile_names
        profile_names=$(grep "^\[profile " "$config_file" | sed 's/\[profile \(.*\)\]/\1/' | head -$display_limit)
        
        echo "$profile_names" | while IFS= read -r profile_name; do
            # 自動生成プロファイルでないかチェック
            if ! grep -Fxq "$profile_name" "$auto_profiles_file" 2>/dev/null; then
                # プロファイルの詳細情報を取得
                local profile_start_line
                local profile_end_line
                local sso_session=""
                local account_id=""
                local role_name=""
                local region=""
                
                profile_start_line=$(grep -n "^\[profile $profile_name\]" "$config_file" | cut -d: -f1)
                if [ -n "$profile_start_line" ]; then
                    # 次のプロファイルまたはセクションの開始行を見つける
                    profile_end_line=$(tail -n +$((profile_start_line + 1)) "$config_file" | grep -n "^\[" | head -1 | cut -d: -f1)
                    if [ -n "$profile_end_line" ]; then
                        profile_end_line=$((profile_start_line + profile_end_line - 1))
                    else
                        profile_end_line=$(wc -l < "$config_file")
                    fi
                    
                    # プロファイルセクションから情報を抽出
                    local profile_section
                    profile_section=$(sed -n "${profile_start_line},${profile_end_line}p" "$config_file")
                    
                    sso_session=$(echo "$profile_section" | grep "^sso_session" | sed 's/sso_session[[:space:]]*=[[:space:]]*//' || echo "-")
                    account_id=$(echo "$profile_section" | grep "^sso_account_id" | sed 's/sso_account_id[[:space:]]*=[[:space:]]*//' || echo "-")
                    role_name=$(echo "$profile_section" | grep "^sso_role_name" | sed 's/sso_role_name[[:space:]]*=[[:space:]]*//' || echo "-")
                    region=$(echo "$profile_section" | grep "^region" | sed 's/region[[:space:]]*=[[:space:]]*//' || echo "-")
                    
                    echo "$profile_name ${sso_session:-"-"} ${account_id:-"-"} ${role_name:-"-"} ${region:-"-"}" >> "$temp_file"
                fi
            fi
        done
        
        # 手動管理プロファイルの表示
        local displayed_count
        displayed_count=$(( $(wc -l < "$temp_file") - 1 ))
        
        if [ $displayed_count -gt 0 ]; then
            column -t < "$temp_file"
            echo
            if [ "$show_all" = "true" ]; then
                if [ $manual_count -gt 300 ]; then
                    log_info "表示: 300 個（全 $manual_count 個中、上限300件）"
                else
                    log_success "手動管理プロファイル数: $manual_count 個（全件表示）"
                fi
            else
                if [ $manual_count -gt $displayed_count ]; then
                    log_info "表示: $displayed_count 個（全 $manual_count 個中）"
                else
                    log_success "手動管理プロファイル数: $manual_count 個"
                fi
            fi
        else
            log_warning "手動管理プロファイルの詳細取得に失敗しました"
        fi
        
        rm -f "$temp_file" "$auto_profiles_file"
        return 0
    else
        log_info "手動管理プロファイルは見つかりませんでした"
        echo
        log_info "全てのプロファイルが自動生成されています"
        return 1
    fi
}

# 重複プロファイルの詳細表示
show_duplicate_details() {
    local config_file="$1"
    
    log_info "重複プロファイルの詳細確認中..."
    log_info "設定ファイル: $config_file"
    echo
    
    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "設定ファイルが見つかりません: $config_file"
        return 1
    fi
    
    # 全プロファイル名を取得（行番号付き）
    local all_profiles_with_lines
    all_profiles_with_lines=$(grep -n "^\[profile " "$config_file" 2>/dev/null)
    
    if [ -z "$all_profiles_with_lines" ]; then
        log_info "プロファイルが見つかりませんでした"
        return 0
    fi
    
    # プロファイル名のみを取得してソート
    local all_profiles
    all_profiles=$(echo "$all_profiles_with_lines" | sed 's/^[0-9]*:\[profile \(.*\)\]/\1/' | sort)
    
    # 重複をチェック
    local duplicates
    duplicates=$(echo "$all_profiles" | uniq -d)
    
    if [ -n "$duplicates" ]; then
        log_warning "重複プロファイルが検出されました"
        echo
        
        local duplicate_count
        duplicate_count=$(echo "$duplicates" | wc -l | tr -d ' ')
        echo "📋 重複プロファイル詳細 ($duplicate_count 個):"
        echo
        
        echo "$duplicates" | while IFS= read -r profile; do
            if [ -n "$profile" ]; then
                echo "🔍 プロファイル名: $profile"
                
                # 該当するプロファイルの行番号と詳細を表示
                local profile_lines
                profile_lines=$(echo "$all_profiles_with_lines" | grep "\[profile $profile\]")
                
                local count=1
                echo "$profile_lines" | while IFS= read -r line; do
                    local line_num
                    line_num=$(echo "$line" | cut -d: -f1)
                    echo "  定義 $count: 行 $line_num"
                    
                    # プロファイルの設定内容を表示（次のプロファイルまで）
                    local next_profile_line
                    next_profile_line=$(tail -n +$((line_num + 1)) "$config_file" | grep -n "^\[" | head -1 | cut -d: -f1)
                    
                    if [ -n "$next_profile_line" ]; then
                        local end_line=$((line_num + next_profile_line - 1))
                        sed -n "${line_num},${end_line}p" "$config_file" | head -10 | sed 's/^/    /'
                    else
                        tail -n +"$line_num" "$config_file" | head -10 | sed 's/^/    /'
                    fi
                    
                    count=$((count + 1))
                    echo
                done
                echo "  ---"
                echo
            fi
        done
        
        echo
        log_info "重複解消の推奨事項:"
        echo "  1. 設定ファイルを手動で編集して重複を削除"
        echo "  2. 自動生成プロファイルの場合は再生成を検討"
        echo "  3. バックアップを取ってから編集作業を実施"
        
        return 1
    else
        log_success "重複プロファイルは見つかりませんでした"
        echo
        local total_count
        total_count=$(echo "$all_profiles" | wc -l | tr -d ' ')
        echo "✅ 全 $total_count 個のプロファイルは一意です"
        return 0
    fi
}

# 使用方法を表示
show_usage() {
    echo "使用方法: $0 [COMMAND] [OPTIONS]"
    echo
    echo "コマンド:"
    echo "  analyze               全プロファイルの分析（デフォルト）"
    echo "  auto [--all]          自動生成プロファイルの詳細表示"
    echo "  manual [--all]        手動管理プロファイルの詳細表示"
    echo "  duplicates            重複プロファイルの詳細チェック"
    echo "  -h, --help            このヘルプを表示"
    echo
    echo "オプション:"
    echo "  --all                 全件表示（最大300件まで、デフォルトは10件）"
    echo
    echo "例:"
    echo "  $0                    # 全プロファイルの分析を実行"
    echo "  $0 analyze            # 全プロファイルの分析を実行"
    echo "  $0 auto               # 自動生成プロファイルの詳細を表示（最初の10件）"
    echo "  $0 auto --all         # 自動生成プロファイルの詳細を全件表示"
    echo "  $0 manual             # 手動管理プロファイルの詳細を表示（最初の10件）"
    echo "  $0 manual --all       # 手動管理プロファイルの詳細を全件表示"
    echo "  $0 duplicates         # 重複プロファイルの詳細チェック"
}

# メイン実行
main() {
    # ヘルプオプションの処理
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    echo "📊 AWS SSO プロファイル分析"
    echo "=========================="
    echo
    
    local config_file
    config_file=$(get_config_file)
    
    local result
    local show_all=false
    
    # --allオプションの確認
    if [ "$2" = "--all" ]; then
        show_all=true
    fi
    
    case "${1:-analyze}" in
        "analyze"|"")
            analyze_profiles "$config_file"
            result=$?
            ;;
        "auto")
            show_auto_generated_details "$config_file" "$show_all"
            result=$?
            ;;
        "manual")
            show_manual_profiles_details "$config_file" "$show_all"
            result=$?
            ;;
        "duplicates")
            show_duplicate_details "$config_file"
            result=$?
            ;;
        *)
            log_error "不明なコマンド: $1"
            echo
            show_usage
            exit 1
            ;;
    esac
    
    echo
    if [ $result -eq 0 ]; then
        log_success "プロファイル分析が完了しました"
    else
        log_error "プロファイル分析でエラーが発生しました"
    fi
    
    exit $result
}

# スクリプト実行
main "$@"