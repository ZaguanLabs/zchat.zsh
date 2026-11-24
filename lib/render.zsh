# lib/render.zsh - Markdown parsing, Syntax styling, and Collapsible Reasoning for zchat

setopt EXTENDED_GLOB 2>/dev/null

typeset -ga RENDERED_LINES=()
typeset -ga RENDERED_ATTRS=()
typeset -ga RENDERED_SPANS=()
typeset -ga RENDER_PREFIX_LINES=()
typeset -ga RENDER_PREFIX_ATTRS=()
typeset -ga RENDER_PREFIX_SPANS=()
typeset -gi RENDER_REVISION=0
typeset -gi RENDER_PREFIX_REVISION=-1
typeset -gi RENDER_PREFIX_WIDTH=0
typeset -gi RENDER_PREFIX_COUNT=-1
typeset -g RENDER_PREFIX_SESSION=""

typeset -ga RENDER_SPAN_ATTRS=()
typeset -ga RENDER_SPAN_TEXTS=()

# Span data is length-prefixed because rendered text is untrusted and can
# contain any printable delimiter. Lengths count Zsh characters consistently
# with the renderer's indexing and width calculations.
_render_pack_span() {
  local attr="$1" text="$2"
  REPLY="${#attr}:${attr}${#text}:${text}"
}

render_unpack_spans() {
  local data="$1" digits="" attr="" text=""
  local -i length
  RENDER_SPAN_ATTRS=()
  RENDER_SPAN_TEXTS=()

  while [[ -n "$data" ]]; do
    [[ "$data" == <->:* ]] || return 1
    digits="${data%%:*}"
    (( ${#digits} <= 10 )) || return 1
    data="${data[$(( ${#digits} + 2 )),-1]}"
    length=$(( 10#$digits ))
    (( ${#data} >= length )) || return 1
    if (( length )); then
      attr="${data[1,$length]}"
      data="${data[$(( length + 1 )),-1]}"
    else
      attr=""
    fi

    [[ "$data" == <->:* ]] || return 1
    digits="${data%%:*}"
    (( ${#digits} <= 10 )) || return 1
    data="${data[$(( ${#digits} + 2 )),-1]}"
    length=$(( 10#$digits ))
    (( ${#data} >= length )) || return 1
    if (( length )); then
      text="${data[1,$length]}"
      data="${data[$(( length + 1 )),-1]}"
    else
      text=""
    fi
    RENDER_SPAN_ATTRS+=("$attr")
    RENDER_SPAN_TEXTS+=("$text")
  done
}

render_invalidate() {
  (( ++RENDER_REVISION ))
  return 0
}

# Tokenize inline markdown (bold, italic, strikethrough, code, links) into a span string
# Usage: _render_tokenize_inline "text" "default_attr"
_render_tokenize_inline() {
  local line="$1"
  local def_attr="${2:-white/black}"
  local rem="$line" m="" encoded=""
  local -i cut

  while [[ -n "$rem" ]]; do
    # Consume the plain-text run up to the next inline marker at C speed. The
    # marker patterns below are start-anchored, so they can only match here.
    cut=${rem[(ib:1:)[\\\\\`\*\[~]]}
    if (( cut > 1 )); then
      if (( cut > ${#rem} )); then
        _render_pack_span "$def_attr" "$rem"
        encoded+="$REPLY"
        break
      fi
      _render_pack_span "$def_attr" "${rem[1,cut-1]}"
      encoded+="$REPLY"
      rem="${rem[cut,-1]}"
    fi

    # Inline code: `code`
    if [[ "$rem" =~ "^(\`[^\`]+\`)(.*)" ]]; then
      m="${match[1]}"
      _render_pack_span "bold yellow/black" "${m[2,-2]}"
      encoded+="$REPLY"
      rem="${match[2]}"

    # Bold + Italic: ***text***
    elif [[ "$rem" =~ "^(\*\*\*[^\*]+\*\*\*)(.*)" ]]; then
      m="${match[1]}"
      _render_pack_span "bold cyan/black" "${m[4,-4]}"
      encoded+="$REPLY"
      rem="${match[2]}"

    # Strikethrough: ~~text~~
    elif [[ "$rem" =~ "^(~~[^~]+~~)(.*)" ]]; then
      m="${match[1]}"
      _render_pack_span "dim white/black" "${m[3,-3]}"
      encoded+="$REPLY"
      rem="${match[2]}"

    # Bold: **bold**
    elif [[ "$rem" =~ "^(\*\*[^\*]+\*\*)(.*)" ]]; then
      m="${match[1]}"
      _render_pack_span "bold white/black" "${m[3,-3]}"
      encoded+="$REPLY"
      rem="${match[2]}"

    # Italic: *italic* (styled in dim white without underline lines)
    elif [[ "$rem" =~ "^(\*[^\*]+\*)(.*)" ]]; then
      m="${match[1]}"
      _render_pack_span "dim white/black" "${m[2,-2]}"
      encoded+="$REPLY"
      rem="${match[2]}"

    # Markdown links: [Label](url)
    elif [[ "$rem" =~ "^(\[[^]]+\]\([^)]+\))(.*)" ]]; then
      m="${match[1]}"
      rem="${match[2]}"
      if [[ "$m" =~ "\[([^]]+)\]\(([^)]+)\)" ]]; then
        _render_pack_span "bold cyan/black" "${match[1]}"
        encoded+="$REPLY"
        _render_pack_span "dim white/black" " (${match[2]})"
        encoded+="$REPLY"
      fi

    # A marker character that opens no inline construct is literal text.
    else
      _render_pack_span "$def_attr" "${rem[1,1]}"
      encoded+="$REPLY"
      rem="${rem[2,-1]}"
    fi
  done

  REPLY="$encoded"
}

# Helper to add a rendered line with optional spans
_add_line() {
  local line_text="$1"
  local line_attr="${2:-white/black}"
  local inline_fmt="${3:-1}"
  local span_str=""

  RENDERED_LINES+=("$line_text")
  RENDERED_ATTRS+=("$line_attr")

  if (( inline_fmt )) && [[ "$line_text" == *[\`\*\[~]* ]]; then
    _render_tokenize_inline "$line_text" "$line_attr"
    span_str="$REPLY"
    RENDERED_SPANS+=("$span_str")
  else
    RENDERED_SPANS+=("")
  fi
}

_add_split_line() {
  local REPLY first_span
  _add_line "$2$4" "$1" 0
  _render_pack_span "$1" "$2"; first_span=$REPLY
  _render_pack_span "$3" "$4"
  RENDERED_SPANS[-1]="$first_span$REPLY"
}

_render_turn_heading() {
  local title="$1" style="$2" time="$3" REPLY
  local -i width=$4
  zchat_terminal_safe "$title"; title=$REPLY
  zchat_terminal_safe "$time"; time=$REPLY
  (( ${(m)#time} <= width / 3 )) || time=''
  [[ -n $time ]] && time="  $time"
  local -i title_width=$(( width - ${(m)#time} ))
  if (( ${(m)#title} > title_width )); then
    zchat_clip "$title" $(( title_width - 1 ))
    title="$REPLY…"
  fi
  _add_split_line "$style" "$title" 'muted/surface' "$time"
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
      w=${(m)#c}
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

# Render one inclusive message range. Finalized messages can be cached while the
# last assistant row changes during streaming.
_render_message_range() {
  local width="${1:-60}"
  local is_streaming="${2:-0}"
  local -i range_start="${3:-1}" range_end="${4:-${#MSG_ROLES}}" reset="${5:-1}"
  local text_width=$(( width - 4 ))
  (( text_width < 20 )) && text_width=20

  if (( reset )); then
    RENDERED_LINES=()
    RENDERED_ATTRS=()
    RENDERED_SPANS=()
  fi

  local count=$range_end total_count=${#MSG_ROLES}
  if (( total_count == 0 && reset )); then
    _add_line " " "default/default" 0
    _add_line '  Start a conversation' 'bold accent/surface' 0
    _add_line '  Ctrl+O  Choose a model' 'muted/surface' 0
    _add_line '  Ctrl+H  View shortcuts' 'muted/surface' 0
    return
  fi
  (( range_start <= range_end )) || return 0

  local i=1 role="" content="" thinking="" tm="" exp=0
  local -a raw_lines=() wrapped=() think_raw=() table_buf=()
  local l="" wl="" in_code=0 code_lang="" in_table=0 line_num=1
  local think_count=0 show_expanded=0 banner_hdr="" pad_w=0 bbar=""
  local hdr="" pad_len=0 bar="" num_prefix="" code_attr="" rbar="" REPLY
  local -i code_width
  local mark="" t_txt="" num="" num_txt="" first=1 b_txt=""

  for (( i=range_start; i<=range_end; i++ )); do
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
        _render_turn_heading '▎ You' 'bold user/surface' "$tm" "$width"

        raw_lines=("${(@f)content}")
        for l in "${raw_lines[@]}"; do
          if [[ -z "$l" ]]; then
            _add_line " " "default/default" 0
          else
            zchat_wrap "$l" "$text_width"
            wrapped=("${ZCHAT_WRAPPED[@]}")
            for wl in "${wrapped[@]}"; do
              _add_line "  $wl" "text/surface" 1
            done
          fi
        done
        _add_line " " "default/default" 0
        ;;

      assistant)
        _render_turn_heading "▎ Assistant (${MSG_MODELS[i]:-$SESSION_MODEL})" 'bold accent/surface' "$tm" "$width"

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
            _add_line "  ▾ Thinking…" "bold syntax/surface" 0
            _add_line "  └──${bbar}" "dim magenta/black" 0
          else
            think_raw=("${(f)thinking}")
            think_count=${#think_raw}
            _add_line "  ▾ Thinking · ${think_count} lines" "bold syntax/surface" 0

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
            _add_line "  ▾ Reasoning · ^R to collapse" "bold syntax/surface" 0

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
            _add_line "  ▸ Reasoning · ^R to expand" "syntax/surface" 0
          fi
          _add_line " " "default/default" 0
        fi

        # ----------------------------------------------------------------------
        # 2. Main Markdown Content
        # ----------------------------------------------------------------------
        if [[ -n "$content" ]]; then
          raw_lines=("${(@f)content}")
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
                zchat_clip "$code_lang" $(( text_width - 8 ))
                hdr="  ╭─ ${REPLY} "
                pad_len=$(( text_width - ${(m)#hdr} ))
                (( pad_len < 2 )) && pad_len=2
                zchat_repeat "─" "$pad_len"
                bar="$REPLY"
                _add_line "${hdr}${bar}" "bold accent/surface" 0
              else
                in_code=0
                zchat_repeat "─" $(( text_width - 5 ))
                bar="$REPLY"
                _add_line "  ╰──${bar}" "border/surface" 0
              fi

            # Inside code block
            elif (( in_code )); then
              printf -v num_prefix "  │ %2d  " "$line_num"
              (( line_num++ ))
              code_attr="text/surface"
              if [[ "$l" =~ '^[[:space:]]*(#|//|--)' ]]; then
                code_attr="muted/surface"
              fi
              zchat_terminal_safe "$l"
              code_width=$(( text_width - ${#num_prefix} ))
              if (( ${(m)#REPLY} <= code_width )); then
                _add_split_line 'muted/surface' "$num_prefix" "$code_attr" "$REPLY"
              else
                zchat_hard_wrap "$REPLY" "$code_width"
                for wl in "${ZCHAT_WRAPPED[@]}"; do
                  _add_split_line 'muted/surface' "$num_prefix" "$code_attr" "$wl"
                  num_prefix=${num_prefix//[[:digit:]]/ }
                done
              fi

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

# Main markdown renderer. During generation the immutable transcript prefix is
# reused and only the active assistant message is parsed again.
render_messages() {
  local -i width="${1:-60}" is_streaming="${2:-0}" count=${#MSG_ROLES} prefix_count
  if (( ! is_streaming || count == 0 )); then
    _render_message_range "$width" 0 1 "$count" 1
    return
  fi

  prefix_count=$(( count - 1 ))
  if (( RENDER_PREFIX_REVISION != RENDER_REVISION || RENDER_PREFIX_WIDTH != width || RENDER_PREFIX_COUNT != prefix_count )) \
    || [[ "$RENDER_PREFIX_SESSION" != "$CURRENT_SESSION_ID" ]]; then
    if (( prefix_count > 0 )); then
      _render_message_range "$width" 0 1 "$prefix_count" 1
      RENDER_PREFIX_LINES=("${RENDERED_LINES[@]}")
      RENDER_PREFIX_ATTRS=("${RENDERED_ATTRS[@]}")
      RENDER_PREFIX_SPANS=("${RENDERED_SPANS[@]}")
    else
      RENDER_PREFIX_LINES=()
      RENDER_PREFIX_ATTRS=()
      RENDER_PREFIX_SPANS=()
    fi
    RENDER_PREFIX_REVISION=$RENDER_REVISION
    RENDER_PREFIX_WIDTH=$width
    RENDER_PREFIX_COUNT=$prefix_count
    RENDER_PREFIX_SESSION="$CURRENT_SESSION_ID"
  fi

  RENDERED_LINES=("${RENDER_PREFIX_LINES[@]}")
  RENDERED_ATTRS=("${RENDER_PREFIX_ATTRS[@]}")
  RENDERED_SPANS=("${RENDER_PREFIX_SPANS[@]}")
  _render_message_range "$width" 1 "$count" "$count" 0
}
