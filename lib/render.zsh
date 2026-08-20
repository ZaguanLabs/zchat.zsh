# lib/render.zsh - Markdown parsing, Syntax styling, and Collapsible Reasoning for zchat

setopt EXTENDED_GLOB 2>/dev/null

typeset -ga RENDERED_LINES=()
typeset -ga RENDERED_ATTRS=()
typeset -ga RENDERED_SPANS=()

typeset -g SPAN_SEP="~@~"
typeset -g FIELD_SEP="~#~"

# Tokenize inline markdown (bold, italic, strikethrough, code, links) into a span string
# Usage: _render_tokenize_inline "text" "default_attr"
_render_tokenize_inline() {
  local line="$1"
  local def_attr="${2:-white/black}"
  local -a spans=()
  local rem="$line" m=""

  while [[ -n "$rem" ]]; do
    # Inline code: `code`
    if [[ "$rem" =~ "^(\`[^\`]+\`)(.*)" ]]; then
      m="${match[1]}"
      spans+=("bold yellow/black${FIELD_SEP}${m[2,-2]}")
      rem="${match[2]}"

    # Bold + Italic: ***text***
    elif [[ "$rem" =~ "^(\*\*\*[^\*]+\*\*\*)(.*)" ]]; then
      m="${match[1]}"
      spans+=("bold cyan/black${FIELD_SEP}${m[4,-4]}")
      rem="${match[2]}"

    # Strikethrough: ~~text~~
    elif [[ "$rem" =~ "^(~~[^~]+~~)(.*)" ]]; then
      m="${match[1]}"
      spans+=("dim white/black${FIELD_SEP}${m[3,-3]}")
      rem="${match[2]}"

    # Bold: **bold**
    elif [[ "$rem" =~ "^(\*\*[^\*]+\*\*)(.*)" ]]; then
      m="${match[1]}"
      spans+=("bold white/black${FIELD_SEP}${m[3,-3]}")
      rem="${match[2]}"

    # Italic: *italic* (styled in dim white without underline lines)
    elif [[ "$rem" =~ "^(\*[^\*]+\*)(.*)" ]]; then
      m="${match[1]}"
      spans+=("dim white/black${FIELD_SEP}${m[2,-2]}")
      rem="${match[2]}"

    # Markdown links: [Label](url)
    elif [[ "$rem" =~ "^(\[[^]]+\]\([^)]+\))(.*)" ]]; then
      m="${match[1]}"
      rem="${match[2]}"
      if [[ "$m" =~ "\[([^]]+)\]\(([^)]+)\)" ]]; then
        spans+=("bold cyan/black${FIELD_SEP}${match[1]}")
        spans+=("dim white/black${FIELD_SEP} (${match[2]})")
      fi

    # Plain text chunk
    else
      if [[ "$rem" =~ "^([^\\\`\*\[~]+)(.*)" ]]; then
        spans+=("${def_attr}${FIELD_SEP}${match[1]}")
        rem="${match[2]}"
      else
        spans+=("${def_attr}${FIELD_SEP}${rem[1,1]}")
        rem="${rem[2,-1]}"
      fi
    fi
  done

  REPLY="${(j.~@~.)spans}"
}

# Helper to add a rendered line with optional spans
_add_line() {
  local line_text="$1"
  local line_attr="${2:-white/black}"
  local inline_fmt="${3:-1}"
  local span_str=""

  RENDERED_LINES+=("$line_text")
  RENDERED_ATTRS+=("$line_attr")

  if (( inline_fmt )) && [[ "$line_text" =~ '[\`\*\[~]' ]]; then
    _render_tokenize_inline "$line_text" "$line_attr"
    span_str="$REPLY"
    RENDERED_SPANS+=("$span_str")
  else
    RENDERED_SPANS+=("")
  fi
}

# Format markdown table lines into Unicode box drawing
_render_markdown_table() {
  local -a raw_tbl=("$@")
  local -a clean_rows=() col_widths=() cells=()
  local l="" r="" c="" top_b="  ┌" mid_b="  ├" bot_b="  └" bar="" line_str="" cell_txt="" padded=""
  local total_rows=0 num_cols=0 min_w=3 c_idx=1 row_idx=1 i=1 w=0

  for l in "${raw_tbl[@]}"; do
    # Skip separator row |---|---|
    [[ "$l" =~ "^[[:space:]]*\|[-: |]+\|[[:space:]]*$" ]] && continue
    r="$l"
    r="${r##[[:space:]]#}"
    r="${r%%[[:space:]]#}"
    r="${r#|}"
    r="${r%|}"
    clean_rows+=("$r")
  done

  total_rows=${#clean_rows}
  (( total_rows == 0 )) && return

  # Compute max column count and widths
  for r in "${clean_rows[@]}"; do
    cells=("${(@s.|.)r}")
    c_idx=1
    for c in "${cells[@]}"; do
      c="${c##[[:space:]]#}"
      c="${c%%[[:space:]]#}"
      w=${#c}
      if (( w > ${col_widths[c_idx]:-0} )); then
        col_widths[c_idx]=$w
      fi
      (( c_idx++ ))
    done
  done

  num_cols=${#col_widths}
  (( num_cols == 0 )) && return

  for (( i=1; i<=num_cols; i++ )); do
    (( col_widths[i] < min_w )) && col_widths[i]=$min_w
  done

  # Build top, middle, bottom borders
  for (( i=1; i<=num_cols; i++ )); do
    zchat_repeat "─" $(( col_widths[i] + 2 ))
    bar="$REPLY"
    top_b+="$bar"
    mid_b+="$bar"
    bot_b+="$bar"
    if (( i < num_cols )); then
      top_b+="┬"
      mid_b+="┼"
      bot_b+="┴"
    else
      top_b+="┐"
      mid_b+="┤"
      bot_b+="┘"
    fi
  done

  _add_line "$top_b" "dim cyan/black" 0
  row_idx=1
  for r in "${clean_rows[@]}"; do
    cells=("${(@s.|.)r}")
    line_str="  │"
    for (( i=1; i<=num_cols; i++ )); do
      cell_txt="${cells[i]:-}"
      cell_txt="${cell_txt##[[:space:]]#}"
      cell_txt="${cell_txt%%[[:space:]]#}"
      zchat_pad_right "$cell_txt" "${col_widths[i]}"
      padded=" $REPLY "
      line_str+="${padded}│"
    done

    if (( row_idx == 1 )); then
      _add_line "$line_str" "bold cyan/black" 1
      if (( total_rows > 1 )); then
        _add_line "$mid_b" "dim cyan/black" 0
      fi
    else
      _add_line "$line_str" "white/black" 1
    fi
    (( row_idx++ ))
  done
  _add_line "$bot_b" "dim cyan/black" 0
}

# Main markdown renderer for all conversation messages
# Usage: render_messages <inner_width> [is_streaming]
render_messages() {
  local width="${1:-60}"
  local is_streaming="${2:-0}"
  local text_width=$(( width - 4 ))
  (( text_width < 20 )) && text_width=20

  RENDERED_LINES=()
  RENDERED_ATTRS=()
  RENDERED_SPANS=()

  local count=${#MSG_ROLES}
  if (( count == 0 )); then
    _add_line " " "default/default" 0
    _add_line "  👋 Welcome to ZSH AI Chat!" "bold cyan/black" 0
    _add_line " " "default/default" 0
    _add_line "  • Type your message in the bottom input box and press Enter to send." "dim white/black" 0
    _add_line "  • Press Ctrl+O to select another Ollama model (e.g. gemma4:12b, deepseek)." "dim white/black" 0
    _add_line "  • Press Ctrl+R to expand or collapse Reasoning blocks." "dim white/black" 0
    _add_line "  • Press Ctrl+N for new chat, Ctrl+S for system prompt presets." "dim white/black" 0
    _add_line "  • Press Tab to switch focus or PgUp/PgDn to scroll history." "dim white/black" 0
    _add_line " " "default/default" 0
    return
  fi

  local i=1 role="" content="" thinking="" tm="" exp=0
  local -a raw_lines=() wrapped=() think_raw=() table_buf=()
  local l="" wl="" in_code=0 code_lang="" in_table=0 line_num=1
  local think_count=0 show_expanded=0 banner_hdr="" pad_w=0 bbar=""
  local hdr="" pad_len=0 bar="" num_prefix="" code_attr="" rbar=""
  local mark="" t_txt="" num="" num_txt="" first=1 b_txt=""

  for (( i=1; i<=count; i++ )); do
    role="${MSG_ROLES[i]}"
    content="${MSG_CONTENTS[i]}"
    thinking="${MSG_THINKINGS[i]:-}"
    exp="${MSG_THINKING_EXPANDED[i]:-0}"
    tm="${MSG_TIMES[i]:-}"
    if [[ -z "$tm" ]]; then
      zchat_time
      tm="[$REPLY]"
    fi

    # Trim leading/trailing whitespace
    content="${content##[[:space:]]#}"
    content="${content%%[[:space:]]#}"
    thinking="${thinking##[[:space:]]#}"
    thinking="${thinking%%[[:space:]]#}"

    case "$role" in
      user)
        [[ -z "$content" ]] && continue
        _add_line "🧑 You  ${tm}" "bold green/black" 0

        raw_lines=("${(f)content}")
        for l in "${raw_lines[@]}"; do
          if [[ -z "$l" ]]; then
            _add_line " " "default/default" 0
          else
            zchat_wrap "$l" "$text_width"
            wrapped=("${ZCHAT_WRAPPED[@]}")
            for wl in "${wrapped[@]}"; do
              _add_line "  $wl" "green/black" 1
            done
          fi
        done
        _add_line " " "default/default" 0
        ;;

      assistant)
        _add_line "🤖 Assistant (${SESSION_MODEL})  ${tm}" "bold cyan/black" 0

        # ----------------------------------------------------------------------
        # 1. Reasoning Block (Collapsible)
        # ----------------------------------------------------------------------
        if (( is_streaming == 1 && i == count )) && [[ -z "$content" ]]; then
          # Active thinking in progress (show from millisecond 0)
          pad_w=$(( text_width - 4 ))
          (( pad_w < 10 )) && pad_w=10
          zchat_repeat "─" "$pad_w"
          bbar="$REPLY"

          if [[ -z "$thinking" ]]; then
            _add_line "  ▼ 💭 Thinking..." "bold magenta/black" 0
            _add_line "  │ (generating reasoning...)" "dim magenta/black" 0
            _add_line "  └──${bbar}" "dim magenta/black" 0
          else
            think_raw=("${(f)thinking}")
            think_count=${#think_raw}
            _add_line "  ▼ 💭 Thinking... (${think_count} lines)" "bold magenta/black" 0

            for l in "${think_raw[@]}"; do
              if [[ -z "$l" ]]; then
                _add_line "  │" "dim magenta/black" 0
              else
                zchat_wrap "$l" $(( text_width - 4 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                for wl in "${wrapped[@]}"; do
                  _add_line "  │ $wl" "dim magenta/black" 0
                done
              fi
            done
            _add_line "  └──${bbar}" "dim magenta/black" 0
          fi
          _add_line " " "default/default" 0

        elif [[ -n "$thinking" ]]; then
          think_raw=("${(f)thinking}")
          think_count=${#think_raw}

          if (( exp == 1 )); then
            _add_line "  ▼ 💭 Reasoning (${think_count} lines) [Press ^R to collapse]" "bold magenta/black" 0

            for l in "${think_raw[@]}"; do
              if [[ -z "$l" ]]; then
                _add_line "  │" "dim magenta/black" 0
              else
                zchat_wrap "$l" $(( text_width - 4 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                for wl in "${wrapped[@]}"; do
                  _add_line "  │ $wl" "dim magenta/black" 0
                done
              fi
            done
            pad_w=$(( text_width - 4 ))
            (( pad_w < 10 )) && pad_w=10
            zchat_repeat "─" "$pad_w"
            bbar="$REPLY"
            _add_line "  └──${bbar}" "dim magenta/black" 0
          else
            _add_line "  ▶ 💭 Reasoning (${think_count} lines) [Press ^R to expand]" "dim magenta/black" 0
          fi
          _add_line " " "default/default" 0
        fi

        # ----------------------------------------------------------------------
        # 2. Main Markdown Content
        # ----------------------------------------------------------------------
        if [[ -n "$content" ]]; then
          raw_lines=("${(f)content}")
          in_code=0
          code_lang=""
          line_num=1
          in_table=0
          table_buf=()

          for l in "${raw_lines[@]}"; do
            # Table handling
            if (( ! in_code )) && [[ "$l" =~ "^[[:space:]]*\|.*\|[[:space:]]*$" ]]; then
              in_table=1
              table_buf+=("$l")
              continue
            elif (( in_table )); then
              in_table=0
              _render_markdown_table "${table_buf[@]}"
              table_buf=()
            fi

            # Fenced code block toggle
            if [[ "$l" =~ '^```([a-zA-Z0-9_-]*)' ]]; then
              if (( in_code == 0 )); then
                in_code=1
                line_num=1
                code_lang="${match[1]:-code}"
                hdr="  ┌──   [${code_lang}] "
                pad_len=$(( text_width - ${#hdr} ))
                (( pad_len < 2 )) && pad_len=2
                zchat_repeat "─" "$pad_len"
                bar="$REPLY"
                _add_line "${hdr}${bar}" "bold cyan/black" 0
              else
                in_code=0
                zchat_repeat "─" "$text_width"
                bar="$REPLY"
                _add_line "  └──${bar}" "dim yellow/black" 0
              fi

            # Inside code block
            elif (( in_code )); then
              printf -v num_prefix "  │ %2d  " "$line_num"
              (( line_num++ ))
              code_attr="yellow/black"
              if [[ "$l" =~ '^[[:space:]]*(#|//|--)' ]]; then
                code_attr="dim green/black"
              fi
              _add_line "${num_prefix}${l}" "$code_attr" 0

            # Outside code block - standard markdown elements
            else
              # Blank line
              if [[ -z "$l" ]]; then
                _add_line " " "default/default" 0

              # Level 1 Heading: # Heading
              elif [[ "$l" =~ '^# (.*)' ]]; then
                _add_line " " "default/default" 0
                _add_line "  ◆ ${(U)match[1]}" "bold magenta/black" 1

              # Level 2 Heading: ## Heading
              elif [[ "$l" =~ '^## (.*)' ]]; then
                _add_line " " "default/default" 0
                _add_line "  ◇ ${match[1]}" "bold cyan/black" 1

              # Level 3 Heading: ### Heading
              elif [[ "$l" =~ '^### (.*)' ]]; then
                _add_line " " "default/default" 0
                _add_line "  ▸ ${match[1]}" "bold yellow/black" 1

              # Level 4+ Heading: #### Heading
              elif [[ "$l" =~ '^####+ (.*)' ]]; then
                _add_line "  ▪ ${match[1]}" "bold white/black" 1

              # Horizontal Rule: --- or *** or ___
              elif [[ "$l" =~ '^[[:space:]]*([-*_]{3,})[[:space:]]*$' ]]; then
                zchat_repeat "─" "$text_width"
                rbar="$REPLY"
                _add_line "  ${rbar}" "dim white/black" 0

              # Nested Blockquote: >> Quote
              elif [[ "$l" =~ '^[[:space:]]*>>[[:space:]]*(.*)' ]]; then
                zchat_wrap "${match[1]}" $(( text_width - 8 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                for wl in "${wrapped[@]}"; do
                  _add_line "  ▎ ▎ $wl" "dim cyan/black" 1
                done

              # Standard Blockquote: > Quote
              elif [[ "$l" =~ '^[[:space:]]*>[[:space:]]*(.*)' ]]; then
                zchat_wrap "${match[1]}" $(( text_width - 4 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                for wl in "${wrapped[@]}"; do
                  _add_line "  ▎ $wl" "dim cyan/black" 1
                done

              # Task List: - [ ] or - [x]
              elif [[ "$l" =~ '^[[:space:]]*[-*][[:space:]]+\[([ xX])\][[:space:]]+(.*)' ]]; then
                mark="${match[1]}"
                t_txt="${match[2]}"
                if [[ "$mark" == " " ]]; then
                  _add_line "  ☐ $t_txt" "dim white/black" 1
                else
                  _add_line "  ☑ $t_txt" "bold green/black" 1
                fi

              # Numbered List: 1. Item
              elif [[ "$l" =~ '^[[:space:]]*([0-9]+)\.[[:space:]]+(.*)' ]]; then
                num="${match[1]}"
                num_txt="${match[2]}"
                zchat_wrap "$num_txt" $(( text_width - 6 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                first=1
                for wl in "${wrapped[@]}"; do
                  if (( first )); then
                    _add_line "  ${num}. $wl" "white/black" 1
                    first=0
                  else
                    _add_line "     $wl" "white/black" 1
                  fi
                done

              # Nested Unordered Bullet List:   * Item
              elif [[ "$l" =~ '^[[:space:]]{2,}[-*][[:space:]]+(.*)' ]]; then
                b_txt="${match[1]}"
                zchat_wrap "$b_txt" $(( text_width - 6 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                first=1
                for wl in "${wrapped[@]}"; do
                  if (( first )); then
                    _add_line "    ◦ $wl" "white/black" 1
                    first=0
                  else
                    _add_line "      $wl" "white/black" 1
                  fi
                done

              # Unordered Bullet List: * Item or - Item
              elif [[ "$l" =~ '^[[:space:]]*[-*][[:space:]]+(.*)' ]]; then
                b_txt="${match[1]}"
                zchat_wrap "$b_txt" $(( text_width - 4 ))
                wrapped=("${ZCHAT_WRAPPED[@]}")
                first=1
                for wl in "${wrapped[@]}"; do
                  if (( first )); then
                    _add_line "  • $wl" "white/black" 1
                    first=0
                  else
                    _add_line "    $wl" "white/black" 1
                  fi
                done

              # Standard paragraph
              else
                zchat_wrap "$l" "$text_width"
                wrapped=("${ZCHAT_WRAPPED[@]}")
                for wl in "${wrapped[@]}"; do
                  _add_line "  $wl" "white/black" 1
                done
              fi
            fi
          done

          # Flush remaining table if ended at EOF
          if (( in_table )); then
            _render_markdown_table "${table_buf[@]}"
          fi

        elif [[ -z "$thinking" ]] && (( is_streaming == 0 )); then
          _add_line "  ..." "dim white/black" 0
        fi

        _add_line " " "default/default" 0
        ;;

      system)
        _add_line "ℹ️ System Notice" "bold magenta/black" 0
        zchat_wrap "$content" "$text_width"
        wrapped=("${ZCHAT_WRAPPED[@]}")
        for wl in "${wrapped[@]}"; do
          _add_line "  $wl" "magenta/black" 1
        done
        _add_line " " "default/default" 0
        ;;
    esac
  done
}
