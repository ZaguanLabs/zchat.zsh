# lib/ui.zsh - Curses Layout, Multi-Pane Window Management, and Rendering for zchat

# Terminal Dimensions and Layout Metrics
typeset -g SCREEN_H=24
typeset -g SCREEN_W=80
typeset -g TOP_H=3
typeset -g SIDE_W=24
typeset -g INPUT_H=4
typeset -g FOOT_H=1

# Focus management: 'input', 'sidebar', 'chat'
typeset -g FOCUS_PANE="input"

# Scroll and UI state
typeset -g CHAT_SCROLL_OFFSET=0
typeset -g CHAT_AUTO_SCROLL=1
typeset -g UI_STATUS_TEXT="Ready"

# Query terminal geometry and allocate curses windows
ui_setup_windows() {
  ui_destroy_windows

  # Get physical screen dimensions from stdscr (pos: beg_y beg_x cur_y cur_x max_y max_x)
  local -a scr_pos=()
  zcurses position stdscr scr_pos 2>/dev/null
  SCREEN_H=${scr_pos[5]:-${LINES:-24}}
  SCREEN_W=${scr_pos[6]:-${COLUMNS:-80}}

  local top_h=3
  local foot_h=1
  local input_h=4

  # Adapt to smaller terminal heights
  if (( SCREEN_H < 22 )); then
    top_h=3
    input_h=3
  fi

  # Dynamic sidebar width
  if (( SCREEN_W < 75 )); then
    SIDE_W=0
  elif (( SCREEN_W < 100 )); then
    SIDE_W=20
  else
    SIDE_W=24
  fi

  local main_h=$(( SCREEN_H - top_h - foot_h - input_h ))
  if (( main_h < 3 )); then
    main_h=3
  fi

  TOP_H=$top_h
  INPUT_H=$input_h
  FOOT_H=$foot_h

  local chat_x=$SIDE_W
  local chat_w=$(( SCREEN_W - SIDE_W ))
  local input_y=$(( top_h + main_h ))
  local foot_y=$(( SCREEN_H - foot_h ))

  # Create windows strictly within stdscr boundaries
  zcurses addwin top_win $top_h $SCREEN_W 0 0 2>/dev/null
  if (( SIDE_W > 0 )); then
    zcurses addwin side_win $main_h $SIDE_W $top_h 0 2>/dev/null
  fi
  zcurses addwin chat_win $main_h $chat_w $top_h $chat_x 2>/dev/null
  zcurses addwin input_win $input_h $SCREEN_W $input_y 0 2>/dev/null
  zcurses addwin foot_win $foot_h $SCREEN_W $foot_y 0 2>/dev/null
}

# Destroy all windows
ui_destroy_windows() {
  zcurses delwin top_win 2>/dev/null
  zcurses delwin side_win 2>/dev/null
  zcurses delwin chat_win 2>/dev/null
  zcurses delwin input_win 2>/dev/null
  zcurses delwin foot_win 2>/dev/null
}

# Render the Top Header Bar
ui_draw_header() {
  local stat_val="${1:-$UI_STATUS_TEXT}"
  local status_str="[ ${stat_val} ]"
  local status_x=$(( SCREEN_W - ${#status_str} - 3 ))

  zcurses clear top_win
  zcurses attr top_win bold cyan/black
  zcurses border top_win
  zcurses move top_win 1 2

  zcurses attr top_win bold cyan/black
  zcurses string top_win "⚡ ${ZCHAT_NAME} v${ZCHAT_VERSION} "
  zcurses attr top_win dim white/black
  zcurses string top_win "│ "

  zcurses attr top_win bold white/black
  zcurses string top_win "Model: "
  zcurses attr top_win bold yellow/black
  zcurses string top_win "${SESSION_MODEL}"

  zcurses attr top_win dim white/black
  zcurses string top_win " (${OLLAMA_HOST})"

  # Status badge on the right
  if (( status_x > 50 )); then
    zcurses move top_win 1 $status_x
    if [[ "$stat_val" == *"Thinking"* ]]; then
      zcurses attr top_win bold magenta/black
    elif [[ "$stat_val" == *"Streaming"* || "$stat_val" == *"Generating"* ]]; then
      zcurses attr top_win bold yellow/black
    elif [[ "$stat_val" == *"Error"* || "$stat_val" == *"Stopped"* ]]; then
      zcurses attr top_win bold red/black
    else
      zcurses attr top_win bold green/black
    fi
    zcurses string top_win "$status_str"
  fi

  zcurses refresh top_win
}

# Render the Sidebar
ui_draw_sidebar() {
  (( SIDE_W <= 0 )) && return

  local inner_h=$(( SCREEN_H - 3 - INPUT_H - 1 - 2 ))
  local inner_w=$(( SIDE_W - 2 ))
  local total=${#SESSION_IDS}
  local row=1 i=1 is_curr=0
  local s_id="" s_title="" display_txt="" line_fmt=""

  zcurses clear side_win
  if [[ "$FOCUS_PANE" == "sidebar" ]]; then
    zcurses attr side_win bold yellow/black
  else
    zcurses attr side_win dim white/black
  fi
  zcurses border side_win
  zcurses move side_win 0 2
  zcurses attr side_win bold white/black
  zcurses string side_win " Sessions (${#SESSION_IDS}) "

  for (( i=1; i<=total && row<=inner_h; i++ )); do
    s_id="${SESSION_IDS[i]}"
    s_title="${SESSION_TITLES[i]:-Untitled}"
    is_curr=0
    [[ "$s_id" == "$CURRENT_SESSION_ID" ]] && is_curr=1

    zcurses move side_win $row 1
    display_txt="${s_title[1,$(( inner_w - 4 ))]}"

    if (( is_curr )); then
      zcurses attr side_win bold green/black
      zchat_pad_right "$display_txt" $(( inner_w - 4 ))
      line_fmt=" ▶ $REPLY"
      zcurses string side_win "$line_fmt"
    else
      zcurses attr side_win dim white/black
      zchat_pad_right "$display_txt" $(( inner_w - 4 ))
      line_fmt="   $REPLY"
      zcurses string side_win "$line_fmt"
    fi
    (( row++ ))
  done

  # Bottom helper info in sidebar
  if (( inner_h - row >= 3 )); then
    zcurses move side_win $(( inner_h - 2 )) 1
    zcurses attr side_win dim cyan/black
    zcurses string side_win " ^N: New Chat"
    zcurses move side_win $(( inner_h - 1 )) 1
    zcurses string side_win " ^O: Models"
  fi

  zcurses refresh side_win
}

# Render the Chat Viewport
ui_draw_chat() {
  local is_stream="${1:-0}"
  local chat_inner_w=$(( SCREEN_W - SIDE_W - 2 ))
  local chat_inner_h=$(( SCREEN_H - 3 - INPUT_H - 1 - 2 ))

  render_messages $chat_inner_w $is_stream

  zcurses clear chat_win
  if [[ "$FOCUS_PANE" == "chat" ]]; then
    zcurses attr chat_win bold yellow/black
  else
    zcurses attr chat_win dim white/black
  fi
  zcurses border chat_win

  zcurses move chat_win 0 2
  zcurses attr chat_win bold cyan/black
  zcurses string chat_win " Chat Transcript (${#MSG_ROLES} msgs) "

  local total_lines=${#RENDERED_LINES}

  # Manage scroll offset
  if (( CHAT_AUTO_SCROLL )); then
    if (( total_lines > chat_inner_h )); then
      CHAT_SCROLL_OFFSET=$(( total_lines - chat_inner_h ))
    else
      CHAT_SCROLL_OFFSET=0
    fi
  else
    if (( CHAT_SCROLL_OFFSET > total_lines - chat_inner_h )); then
      CHAT_SCROLL_OFFSET=$(( total_lines - chat_inner_h ))
    fi
    (( CHAT_SCROLL_OFFSET < 0 )) && CHAT_SCROLL_OFFSET=0
  fi

  local row=1 idx=1 current_x=1 pad_len=0
  local line_str="" attr_str="" span_str="" sp="" s_attr="" s_text=""
  local visible_str="" padded="" padding=""
  local -a spans=() parts=()

  for (( row=1; row<=chat_inner_h; row++ )); do
    idx=$(( CHAT_SCROLL_OFFSET + row ))
    if (( idx <= total_lines )); then
      line_str="${RENDERED_LINES[idx]}"
      attr_str="${RENDERED_ATTRS[idx]:-default/default}"
      span_str="${RENDERED_SPANS[idx]:-}"

      zcurses move chat_win $row 1
      zcurses attr chat_win -bold -dim -underline -reverse -standout default/default

      if [[ -n "$span_str" ]]; then
        spans=("${(@s.~@~.)span_str}")
        current_x=1
        for sp in "${spans[@]}"; do
          parts=("${(@s.~#~.)sp}")
          s_attr="${parts[1]:-$attr_str}"
          s_text="${parts[2]:-}"
          [[ -z "$s_text" ]] && continue
          zcurses attr chat_win -bold -dim -underline -reverse -standout default/default
          zcurses attr chat_win $=s_attr
          zcurses string chat_win "$s_text"
          (( current_x += ${#s_text} ))
          (( current_x > chat_inner_w )) && break
        done
        if (( current_x <= chat_inner_w )); then
          pad_len=$(( chat_inner_w - current_x + 1 ))
          zchat_repeat " " "$pad_len"
          padding="$REPLY"
          zcurses attr chat_win -bold -dim -underline -reverse -standout default/default
          zcurses attr chat_win $=attr_str
          zcurses string chat_win "$padding"
        fi
      else
        zcurses attr chat_win -bold -dim -underline -reverse -standout default/default
        zcurses attr chat_win $=attr_str
        visible_str="${line_str[1,$chat_inner_w]}"
        zchat_pad_right "$visible_str" "$chat_inner_w"
        padded="$REPLY"
        zcurses string chat_win "$padded"
      fi
    fi
  done

  # Scroll indicator badge
  if (( total_lines > chat_inner_h && CHAT_SCROLL_OFFSET < total_lines - chat_inner_h )); then
    zcurses move chat_win 0 $(( chat_inner_w - 18 ))
    zcurses attr chat_win bold yellow/black
    zcurses string chat_win " [▼ Scroll: PgDn] "
  elif (( CHAT_SCROLL_OFFSET > 0 )); then
    zcurses move chat_win 0 $(( chat_inner_w - 18 ))
    zcurses attr chat_win dim white/black
    zcurses string chat_win " [▲ Scrolled Up] "
  fi

  zcurses refresh chat_win
}

# Render the Input Box
ui_draw_input() {
  local inner_w=$(( SCREEN_W - 4 ))
  local disp_buf="$INPUT_BUF"
  local disp_pos=$INPUT_POS
  local max_input_w=$(( inner_w - 2 ))
  local start_char=1
  local visible_input="" cursor_x=4

  zcurses clear input_win
  if [[ "$FOCUS_PANE" == "input" ]]; then
    zcurses attr input_win bold green/black
  else
    zcurses attr input_win dim white/black
  fi
  zcurses border input_win

  zcurses move input_win 0 2
  zcurses attr input_win bold white/black
  zcurses string input_win " Prompt (Enter to Send, Ctrl+C to cancel) "

  zcurses move input_win 1 2
  zcurses attr input_win bold green/black
  zcurses string input_win "❯ "

  zcurses attr input_win bold white/black

  # Horizontal scrolling for long inputs
  if (( disp_pos > max_input_w )); then
    start_char=$(( disp_pos - max_input_w + 1 ))
  fi

  visible_input="${disp_buf[start_char,$(( start_char + max_input_w ))]}"
  zcurses string input_win "$visible_input"

  # Position the active cursor inside the input window
  cursor_x=$(( 4 + disp_pos - start_char + 1 ))
  (( cursor_x < 4 )) && cursor_x=4
  (( cursor_x > SCREEN_W - 2 )) && cursor_x=$(( SCREEN_W - 2 ))
  zcurses move input_win 1 $cursor_x

  zcurses refresh input_win
}

# Render the Bottom Footer Bar
ui_draw_footer() {
  local bar_str="" padded=""
  zcurses clear foot_win
  zcurses attr foot_win reverse dim white/black
  printf -v bar_str " %-7s %-12s %-12s %-8s %-10s %-10s %-8s" \
    "[Enter]" "Send" \
    "[^O] Model" \
    "[^R] Reason" \
    "[^N] New" \
    "[^S] System" \
    "[Tab] Focus" \
    "[^Q] Quit"

  zchat_pad_right "$bar_str" "$SCREEN_W"
  padded="$REPLY"
  zcurses move foot_win 0 0
  zcurses string foot_win "$padded"
  zcurses attr foot_win -reverse default/default
  zcurses refresh foot_win
}

# Full UI refresh
ui_refresh_all() {
  local is_stream="${1:-0}"
  ui_draw_header
  (( SIDE_W > 0 )) && ui_draw_sidebar
  ui_draw_chat $is_stream
  ui_draw_input
  ui_draw_footer
}
