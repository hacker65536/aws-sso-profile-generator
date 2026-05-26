#!/usr/bin/env bash

# AWS SSO プロファイル分析スクリプト
# 自動生成プロファイルと手動プロファイルの分析・一覧表示を行います

set -euo pipefail

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
    all_profiles=$(extract_profile_names < "$config_file" 2>/dev/null | sort)
    
    if [ -z "$all_profiles" ]; then
        return 0
    fi
    
    # 重複をチェック
    local duplicates
    duplicates=$(echo "$all_profiles" | uniq -d)
    
    if [ -n "$duplicates" ]; then
        echo
        echo "⚠️  Duplicate profiles detected:"
        local duplicate_count
        duplicate_count=$(echo "$duplicates" | wc -l | tr -d ' ')
        echo "  Duplicate count: $duplicate_count"
        echo
        echo "  Duplicate profile names:"
        echo "$duplicates" | while IFS= read -r profile; do
            if [ -n "$profile" ]; then
                # 重複回数を取得
                local count
                count=$(echo "$all_profiles" | grep -c "^$profile$")
                echo "    - $profile (defined ${count} times)"
            fi
        done
        echo
        log_warning "Duplicate profiles detected"
        log_info "Duplicate profiles may cause unexpected behavior"
        log_info "Edit the config file to resolve duplicates"
    else
        echo
        echo "✅ Duplicate check: no duplicates"
    fi
}

# プロファイル分析の実行
analyze_profiles() {
    local config_file="$1"
    
    log_info "Analyzing profiles..."
    log_info "Config file: $config_file"
    echo

    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "Config file not found: $config_file"
        return 1
    fi
    
    # 自動生成プロファイルの検出（複数ブロック対応）
    local auto_generated_count=0
    
    # 全ての自動生成ブロックを検出
    local start_lines
    local end_lines
    start_lines=$(grep -n "# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null | cut -d: -f1)
    end_lines=$(grep -n "# AWS_SSO_CONFIG_GENERATOR END" "$config_file" 2>/dev/null | cut -d: -f1)
    
    if [ -n "$start_lines" ] && [ -n "$end_lines" ]; then
        # 各ブロックのプロファイル数を合計
        local start_array
        local end_array
        mapfile -t start_array <<< "$start_lines"
        mapfile -t end_array <<< "$end_lines"
        
        # ブロック数の確認
        local start_count=${#start_array[@]}
        local end_count=${#end_array[@]}
        
        if [ "$start_count" -eq "$end_count" ]; then
            # 各ブロックを処理
            for ((i=0; i<start_count; i++)); do
                local block_start=${start_array[i]}
                local block_end=${end_array[i]}
                
                if [ -n "$block_start" ] && [ -n "$block_end" ] && [ "$block_start" -lt "$block_end" ]; then
                    local block_profiles
                    block_profiles=$(safe_pipe_grep_count "^\[profile " "$(safe_sed_range "$block_start" "$block_end" "$config_file")")
                    block_profiles=$(safe_number "$block_profiles")
                    auto_generated_count=$((auto_generated_count + block_profiles))
                fi
            done
        else
            log_debug "Auto-generated marker count mismatch: START=$start_count, END=$end_count"
        fi
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
    log_success "Profile analysis results"
    echo
    echo "📊 Profile statistics:"
    log_kv "Total profiles"     "$total_profiles"
    log_kv "Auto-generated"     "$auto_generated_count"
    log_kv "Manual"             "$manual_count"
    
    # 重複プロファイルのチェック
    check_duplicate_profiles "$config_file"
    
    echo
    
    # 詳細情報の表示
    if [ "${auto_generated_count:-0}" -gt 0 ]; then
        echo "🤖 Auto-generated profile details:"
        
        # 複数ブロック対応の詳細表示
        if [ -n "$start_lines" ] && [ -n "$end_lines" ]; then
            local start_array
            local end_array
            mapfile -t start_array <<< "$start_lines"
            mapfile -t end_array <<< "$end_lines"
            local start_count=${#start_array[@]}
            
            if [ "$start_count" -gt 0 ]; then
                # 最新の生成日時を取得（最後のブロック）
                local latest_start=${start_array[$((start_count-1))]}
                local latest_end=${end_array[$((start_count-1))]}
                local latest_section
                latest_section=$(safe_sed_range "$latest_start" "$latest_end" "$config_file")
                
                local generation_time
                generation_time=$(echo "$latest_section" | head -1 | sed 's/.*START \(.*\)/\1/')
                log_kv "Generated at" "$generation_time"
                
                # 全ブロックからプロファイル名を取得（最初の5個）
                local all_profile_names=""
                for ((i=0; i<start_count; i++)); do
                    local block_start=${start_array[i]}
                    local block_end=${end_array[i]}
                    local block_section
                    block_section=$(safe_sed_range "$block_start" "$block_end" "$config_file")
                    local block_profile_names
                    block_profile_names=$(echo "$block_section" | extract_profile_names)
                    if [ -n "$all_profile_names" ]; then
                        all_profile_names="$all_profile_names"$'\n'"$block_profile_names"
                    else
                        all_profile_names="$block_profile_names"
                    fi
                done
                
                echo "  Profile examples (first 5):"
                echo "$all_profile_names" | head -5 | while IFS= read -r profile; do
                    [ -n "$profile" ] && echo "    - $profile"
                done

                if [ "${auto_generated_count:-0}" -gt 5 ]; then
                    echo "    ... and $((auto_generated_count - 5)) more"
                fi
            fi
        fi
        echo
    fi

    if [ "${manual_count:-0}" -gt 0 ]; then
        echo "✋ Manual profile details:"

        # 自動生成プロファイル以外の全プロファイルを取得
        local auto_profiles_file
        auto_profiles_file=$(mktemp)

        # 自動生成プロファイル名を一時ファイルに保存（既に取得済みのブロック情報を使用）
        if [ -n "$start_lines" ] && [ -n "$end_lines" ]; then
            local ab_start_array
            local ab_end_array
            mapfile -t ab_start_array <<< "$start_lines"
            mapfile -t ab_end_array <<< "$end_lines"
            local ab_count=${#ab_start_array[@]}
            for ((j=0; j<ab_count; j++)); do
                local abs=${ab_start_array[j]}
                local abe=${ab_end_array[j]}
                if [ -n "$abs" ] && [ -n "$abe" ]; then
                    safe_sed_range "$abs" "$abe" "$config_file" | extract_profile_names >> "$auto_profiles_file"
                fi
            done
        fi

        # 手動管理プロファイルの最初の5個を表示
        echo "  Profile examples (first 5):"

        # 全プロファイル名を取得
        local all_profiles
        all_profiles=$(extract_profile_names < "$config_file")

        # 手動管理プロファイル名を抽出（自動生成以外）
        echo "$all_profiles" | while IFS= read -r profile_name; do
            if ! grep -Fxq "$profile_name" "$auto_profiles_file" 2>/dev/null; then
                echo "$profile_name"
            fi
        done | head -5 | while IFS= read -r profile; do
            echo "    - $profile"
        done

        if [ $manual_count -gt 5 ]; then
            echo "    ... and $((manual_count - 5)) more"
        fi

        rm -f "$auto_profiles_file"
        echo
    fi
    

    
    return 0
}

# 自動生成プロファイルの詳細表示
show_auto_generated_details() {
    local config_file="$1"
    local show_all="${2:-false}"
    
    log_info "Inspecting auto-generated profiles..."
    log_info "Config file: $config_file"
    if [ "$show_all" = "true" ]; then
        log_info "Display: all (up to 300)"
    else
        log_info "Display: first 10"
    fi
    echo

    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "Config file not found: $config_file"
        return 1
    fi
    
    # 自動生成セクションの検索（複数ブロック対応）
    local start_lines
    local end_lines
    start_lines=$(grep -n "# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null | cut -d: -f1)
    end_lines=$(grep -n "# AWS_SSO_CONFIG_GENERATOR END" "$config_file" 2>/dev/null | cut -d: -f1)
    
    if [ -n "$start_lines" ] && [ -n "$end_lines" ]; then
        local start_array
        local end_array
        mapfile -t start_array <<< "$start_lines"
        mapfile -t end_array <<< "$end_lines"
        local start_count=${#start_array[@]}
        local end_count=${#end_array[@]}

        if [ "$start_count" -eq "$end_count" ] && [ "$start_count" -gt 0 ]; then
            log_success "Auto-generated profiles found"
            echo

            # 最新の生成情報を表示（最後のブロック）
            local latest_start=${start_array[$((start_count-1))]}
            local latest_end=${end_array[$((end_count-1))]}
            local latest_section
            latest_section=$(safe_sed_range "$latest_start" "$latest_end" "$config_file")

            local generation_time
            generation_time=$(echo "$latest_section" | head -1 | sed 's/.*START \(.*\)/\1/')
            echo "📋 Auto-generation info:"
            log_kv "Latest generated at" "$generation_time"
            log_kv "Block count"         "$start_count"
            
            # 全ブロックのプロファイル数を合計
            local total_profile_count=0
            for ((i=0; i<start_count; i++)); do
                local block_start=${start_array[i]}
                local block_end=${end_array[i]}
                local block_section
                block_section=$(safe_sed_range "$block_start" "$block_end" "$config_file")
                local block_profiles
                block_profiles=$(safe_pipe_grep_count "^\[profile " "$block_section")
                block_profiles=$(safe_number "$block_profiles")
                total_profile_count=$((total_profile_count + block_profiles))
            done
            
            log_kv "Total profiles" "$total_profile_count"
            local profile_count=$total_profile_count
        else
            log_debug "Auto-generated marker count mismatch: START=$start_count, END=$end_count"
            return 1
        fi
        echo

        # プロファイル名の表示
        local display_limit=10
        local display_count=$profile_count

        if [ "$show_all" = "true" ]; then
            display_limit=300
            if [ "$profile_count" -gt 300 ]; then
                display_count=300
                echo "🔍 Profile list (first 300):"
            else
                echo "🔍 Profile list (all $profile_count):"
            fi
        else
            if [ "$profile_count" -gt 10 ]; then
                display_count=10
                echo "🔍 Profile list (first 10):"
            else
                echo "🔍 Profile list (all $profile_count):"
            fi
        fi
        
        # 全ブロックからプロファイル名を取得
        local all_profile_names=""
        for ((i=0; i<start_count; i++)); do
            local block_start=${start_array[i]}
            local block_end=${end_array[i]}
            local block_section
            block_section=$(safe_sed_range "$block_start" "$block_end" "$config_file")
            local block_profile_names
            block_profile_names=$(echo "$block_section" | extract_profile_names)
            if [ -n "$all_profile_names" ]; then
                all_profile_names="$all_profile_names"$'\n'"$block_profile_names"
            else
                all_profile_names="$block_profile_names"
            fi
        done
        
        # 表示制限を適用
        echo "$all_profile_names" | head -$display_limit | while IFS= read -r profile; do
            [ -n "$profile" ] && echo "  - $profile"
        done
        
        if [ "$profile_count" -gt "$display_count" ]; then
            echo "  ... and $((profile_count - display_count)) more"
        fi

        return 0
    else
        log_info "No auto-generated profiles found"
        echo
        log_info "To create auto-generated profiles:"
        echo "  Run ./generate-sso-profiles.sh"
        return 1
    fi
}

# 手動管理プロファイルの詳細表示
show_manual_profiles_details() {
    local config_file="$1"
    local show_all="${2:-false}"
    
    log_info "Inspecting manual profiles..."
    log_info "Config file: $config_file"
    if [ "$show_all" = "true" ]; then
        log_info "Display: all (up to 300)"
    else
        log_info "Display: first 10"
    fi
    echo

    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "Config file not found: $config_file"
        return 1
    fi
    
    # 自動生成プロファイルの範囲を取得（複数ブロック対応）
    local start_lines
    local end_lines
    start_lines=$(grep -n "# AWS_SSO_CONFIG_GENERATOR START" "$config_file" 2>/dev/null | cut -d: -f1)
    end_lines=$(grep -n "# AWS_SSO_CONFIG_GENERATOR END" "$config_file" 2>/dev/null | cut -d: -f1)
    
    # 全プロファイル数の取得
    local total_profiles
    total_profiles=$(safe_grep_count "^\[profile " "$config_file")
    
    # 自動生成プロファイル数の取得（複数ブロック対応）
    local auto_generated_count=0
    if [ -n "$start_lines" ] && [ -n "$end_lines" ]; then
        local start_array
        local end_array
        mapfile -t start_array <<< "$start_lines"
        mapfile -t end_array <<< "$end_lines"
        local start_count=${#start_array[@]}
        local end_count=${#end_array[@]}
        
        if [ "$start_count" -eq "$end_count" ]; then
            for ((i=0; i<start_count; i++)); do
                local block_start=${start_array[i]}
                local block_end=${end_array[i]}
                if [ -n "$block_start" ] && [ -n "$block_end" ] && [ "$block_start" -lt "$block_end" ]; then
                    local block_profiles
                    block_profiles=$(safe_pipe_grep_count "^\[profile " "$(safe_sed_range "$block_start" "$block_end" "$config_file")")
                    block_profiles=$(safe_number "$block_profiles")
                    auto_generated_count=$((auto_generated_count + block_profiles))
                fi
            done
        fi
    fi
    
    # 手動管理プロファイル数（自動生成以外の全て）
    local manual_count
    # 数値の安全な計算
    total_profiles=$(safe_number "$total_profiles")
    auto_generated_count=$(safe_number "$auto_generated_count")
    manual_count=$((total_profiles - auto_generated_count))
    
    if [ "${manual_count:-0}" -gt 0 ]; then
        log_success "Manual profiles found"
        echo
        
        local temp_file
        local auto_profiles_file
        temp_file=$(mktemp)
        auto_profiles_file=$(mktemp)
        echo "PROFILE SESSION ACCOUNT ROLE REGION" > "$temp_file"
        
        # 自動生成プロファイル名を一時ファイルに保存（複数ブロック対応）
        if [ -n "$start_lines" ] && [ -n "$end_lines" ]; then
            local start_array
            local end_array
            mapfile -t start_array <<< "$start_lines"
            mapfile -t end_array <<< "$end_lines"
            local start_count=${#start_array[@]}
            
            for ((i=0; i<start_count; i++)); do
                local block_start=${start_array[i]}
                local block_end=${end_array[i]}
                if [ -n "$block_start" ] && [ -n "$block_end" ]; then
                    safe_sed_range "$block_start" "$block_end" "$config_file" | extract_profile_names >> "$auto_profiles_file"
                fi
            done
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
        
        local all_profile_names
        all_profile_names=$(extract_profile_names < "$config_file")

        local write_count=0
        while IFS= read -r profile_name; do
            if [ "$write_count" -ge "$display_limit" ]; then
                break
            fi
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
                    write_count=$((write_count + 1))
                fi
            fi
        done <<< "$all_profile_names"
        
        # 手動管理プロファイルの表示
        local displayed_count
        displayed_count=$(( $(wc -l < "$temp_file") - 1 ))
        
        if [ $displayed_count -gt 0 ]; then
            column -t < "$temp_file"
            echo
            if [ "$show_all" = "true" ]; then
                if [ $manual_count -gt 300 ]; then
                    log_info "Displayed: 300 of $manual_count (capped at 300)"
                else
                    log_success "Manual profiles: $manual_count (all displayed)"
                fi
            else
                if [ $manual_count -gt $displayed_count ]; then
                    log_info "Displayed: $displayed_count of $manual_count"
                else
                    log_success "Manual profiles: $manual_count"
                fi
            fi
        else
            log_warning "Failed to fetch manual profile details"
        fi

        rm -f "$temp_file" "$auto_profiles_file"
        return 0
    else
        log_info "No manual profiles found"
        echo
        log_info "All profiles are auto-generated"
        return 1
    fi
}

# 重複プロファイルの詳細表示
show_duplicate_details() {
    local config_file="$1"
    
    log_info "Inspecting duplicate profiles..."
    log_info "Config file: $config_file"
    echo

    # 設定ファイルの存在確認
    if [ ! -f "$config_file" ]; then
        log_warning "Config file not found: $config_file"
        return 1
    fi
    
    # 全プロファイル名を取得（行番号付き）
    local all_profiles_with_lines
    all_profiles_with_lines=$(grep -n "^\[profile " "$config_file" 2>/dev/null)
    
    if [ -z "$all_profiles_with_lines" ]; then
        log_info "No profiles found"
        return 0
    fi
    
    # プロファイル名のみを取得してソート
    local all_profiles
    all_profiles=$(echo "$all_profiles_with_lines" | sed 's/^[0-9]*:\[profile \(.*\)\]/\1/' | sort)
    
    # 重複をチェック
    local duplicates
    duplicates=$(echo "$all_profiles" | uniq -d)
    
    if [ -n "$duplicates" ]; then
        log_warning "Duplicate profiles detected"
        echo

        local duplicate_count
        duplicate_count=$(echo "$duplicates" | wc -l | tr -d ' ')
        echo "📋 Duplicate profile details ($duplicate_count):"
        echo

        echo "$duplicates" | while IFS= read -r profile; do
            if [ -n "$profile" ]; then
                echo "🔍 Profile: $profile"

                # 該当するプロファイルの行番号と詳細を表示
                local profile_lines
                profile_lines=$(echo "$all_profiles_with_lines" | grep "\[profile $profile\]")

                local count=1
                echo "$profile_lines" | while IFS= read -r line; do
                    local line_num
                    line_num=$(echo "$line" | cut -d: -f1)
                    echo "  Definition $count: line $line_num"

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
        log_info "Recommended steps to resolve duplicates:"
        echo "  1. Edit the config file manually to remove duplicates"
        echo "  2. For auto-generated profiles, consider regenerating"
        echo "  3. Always back up the config file before editing"

        return 1
    else
        log_success "No duplicate profiles found"
        echo
        local total_count
        total_count=$(echo "$all_profiles" | wc -l | tr -d ' ')
        echo "✅ All $total_count profiles are unique"
        return 0
    fi
}

# 使用方法を表示
show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo
    echo "Commands:"
    echo "  analyze               Analyze all profiles (default)"
    echo "  auto [--all]          Show auto-generated profile details"
    echo "  manual [--all]        Show manual profile details"
    echo "  duplicates            Inspect duplicate profiles"
    echo "  -h, --help            Show this help"
    echo
    echo "Options:"
    echo "  --all                 Show all entries (up to 300; default 10)"
    echo
    echo "Examples:"
    echo "  $0                    # Analyze all profiles"
    echo "  $0 analyze            # Analyze all profiles"
    echo "  $0 auto               # Show auto-generated profile details (first 10)"
    echo "  $0 auto --all         # Show all auto-generated profile details"
    echo "  $0 manual             # Show manual profile details (first 10)"
    echo "  $0 manual --all       # Show all manual profile details"
    echo "  $0 duplicates         # Inspect duplicate profiles"
}

# メイン実行
main() {
    # ヘルプオプションの処理
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    echo "📊 AWS SSO Profile Analysis"
    echo "=========================="
    echo
    
    local config_file
    config_file=$(get_config_file)
    
    local result
    local show_all=false
    
    # --allオプションの確認
    if [ "${2:-}" = "--all" ]; then
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
            log_error "Unknown command: $1"
            echo
            show_usage
            exit 1
            ;;
    esac

    echo
    if [ $result -eq 0 ]; then
        log_success "Profile analysis complete"
    else
        log_error "Errors occurred during profile analysis"
    fi
    
    exit $result
}

# スクリプト実行
main "$@"