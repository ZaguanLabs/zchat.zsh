# lib/ui.zsh - Curses Layout, Multi-Pane Window Management, and Rendering for zchat

# Terminal Dimensions and Layout Metrics
typeset -g SCREEN_H=24
typeset -g SCREEN_W=80
typeset -g TOP_H=3
typeset -g SIDE_W=24
typeset -g INPUT_H=4
typeset -g FOOT_H=1
typeset -gr INPUT_MAX_ROWS=4
typeset -gF UI_NEXT_RESIZE_CHECK=0.0
typeset -grF UI_RESIZE_CHECK_INTERVAL=0.25

# Focus management: 'input', 'sidebar', 'chat'
typeset -g FOCUS_PANE="input"

# Scroll and UI state
typeset -g CHAT_SCROLL_OFFSET=0
typeset -g CHAT_AUTO_SCROLL=1
typeset -g UI_STATUS_TEXT="Ready"

# Width available to one visual editor row after the prompt marker.
ui_input_width() {
  REPLY=$(( SCREEN_W - 6 ))
  (( REPLY < 1 )) && REPLY=1
}

ui_calculate_input_height() {
  local -i max_rows=$INPUT_MAX_ROWS
  local -i available=$(( SCREEN_H - TOP_H - FOOT_H - 5 ))
  (( available < 1 )) && available=1
  (( max_rows > available )) && max_rows=$available
  ui_input_width
  input_layout "$REPLY" "$max_rows"
  INPUT_H=$(( INPUT_VISIBLE_ROWS + 2 ))
}

# Query terminal geometry and allocate curses windows
ui_setup_windows() {
  ui_destroy_windows

  # Get physical screen dimensions from stdscr (pos: beg_y beg_x cur_y cur_x max_y max_x)
  local -a scr_pos=()
  zcurses position stdscr scr_pos 2>/dev/null
  SCREEN_H=${scr_pos[5]:-${LINES:-24}}
  SCREEN_W=${scr_pos[6]:-${COLUMNS:-80}}

  # Dynamic sidebar width
  if (( SCREEN_W < 75 )); then
    SIDE_W=0
  elif (( SCREEN_W < 100 )); then
    SIDE_W=20
  else
    SIDE_W=24
  fi

  TOP_H=3
  FOOT_H=1
  ui_calculate_input_height

  local main_h=$(( SCREEN_H - TOP_H - FOOT_H - INPUT_H ))
  if (( main_h < 3 )); then
    main_h=3
  fi

  local chat_x=$SIDE_W
  local chat_w=$(( SCREEN_W - SIDE_W ))
  local input_y=$(( TOP_H + main_h ))
  local foot_y=$(( SCREEN_H - FOOT_H ))

  # Create windows strictly within stdscr boundaries
  zcurses addwin top_win $TOP_H $SCREEN_W 0 0 2>/dev/null
  if (( SIDE_W > 0 )); then
    zcurses addwin side_win $main_h $SIDE_W $TOP_H 0 2>/dev/null
  fi
  zcurses addwin chat_win $main_h $chat_w $TOP_H $chat_x 2>/dev/null
  zcurses addwin input_win $INPUT_H $SCREEN_W $input_y 0 2>/dev/null
  zcurses addwin foot_win $FOOT_H $SCREEN_W $foot_y 0 2>/dev/null
}

# Check the physical terminal dimensions without an external stty dependency.
ui_poll_resize() {
  local -F now=$EPOCHREALTIME
  (( now < UI_NEXT_RESIZE_CHECK )) && return 0
  UI_NEXT_RESIZE_CHECK=$(( now + UI_RESIZE_CHECK_INTERVAL ))

  # Reloading terminfo makes setupterm query the current TTY dimensions. This
  # is needed because non-interactive Zsh scripts do not update LINES/COLUMNS
  # from WINCH while zsh/curses is active.
  zmodload -u zsh/terminfo 2>/dev/null || return 0
  zmodload zsh/terminfo 2>/dev/null || return 0

  local new_h="${terminfo[lines]:-0}"
  local new_w="${terminfo[cols]:-0}"
  (( new_h > 0 && new_w > 0 )) || return 0
  (( new_h == SCREEN_H && new_w == SCREEN_W )) && return 0

  ui_resize_windows "$new_h" "$new_w"
}

# Synchronize curses with the physical terminal, then rebuild and redraw the UI.
ui_resize_windows() {
  local new_h="${1:-${terminfo[lines]:-${LINES:-$SCREEN_H}}}"
  local new_w="${2:-${terminfo[cols]:-${COLUMNS:-$SCREEN_W}}}"

  # endwin makes ncurses re-enter the terminal with the new geometry. Keep the
  # existing windows intact if this curses build lacks resize_term support.
  zcurses resize "$new_h" "$new_w" endwin 2>/dev/null || return 1

  ui_setup_windows
  ui_refresh_all 0
}

# Keep checkpoint generation cancellable even though its Ollama response is
# deliberately non-streaming. Other editing input waits for the request.
ui_wait_for_compaction() {
  local ch="" key="" mouse=""
  while ! api_async_ready; do
    ui_poll_resize
    ch=""; key=""; mouse=""
    zcurses timeout input_win 50
    zcurses input input_win ch key mouse
    if [[ "$ch" == $'\x1b' || "$ch" == $'\x03' ]]; then
      return 130
    elif [[ "$key" == "PPAGE" ]]; then
      CHAT_AUTO_SCROLL=0
      (( CHAT_SCROLL_OFFSET -= 6 ))
      (( CHAT_SCROLL_OFFSET < 0 )) && CHAT_SCROLL_OFFSET=0
      ui_draw_chat 0
    elif [[ "$key" == "NPAGE" ]]; then
      (( CHAT_SCROLL_OFFSET += 6 ))
      ui_draw_chat 0
    fi
  done
  return 0
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

# Render the multiline, cursor-following prompt editor.
ui_draw_input() {
  local -i defer_refresh="${1:-0}"
  local -i max_rows=$(( INPUT_H - 2 )) row visual_row cursor_y cursor_x total
  local visible="" marker="" title=" Prompt (Enter sends · Shift-Enter newline) "

  ui_input_width
  input_layout "$REPLY" "$max_rows"
  total=${#INPUT_VISUAL_LINES}

  zcurses clear input_win
  if [[ "$FOCUS_PANE" == "input" ]]; then
    zcurses attr input_win bold green/black
  else
    zcurses attr input_win dim white/black
  fi
  zcurses border input_win

  zcurses move input_win 0 2
  zcurses attr input_win bold white/black
  if (( total > INPUT_VISIBLE_ROWS )); then
    title=" Prompt (Enter sends · Shift-Enter newline · ${INPUT_VIEW_TOP}-$(( INPUT_VIEW_TOP + INPUT_VISIBLE_ROWS - 1 ))/${total}) "
  fi
  zcurses string input_win "${title[1,$(( SCREEN_W - 4 ))]}"

  for (( row=1; row<=INPUT_VISIBLE_ROWS; row++ )); do
    visual_row=$(( INPUT_VIEW_TOP + row - 1 ))
    visible="${INPUT_VISUAL_LINES[visual_row]}"
    marker="│"
    (( visual_row == 1 )) && marker="❯"
    (( row == 1 && INPUT_VIEW_TOP > 1 )) && marker="↑"
    (( row == INPUT_VISIBLE_ROWS && visual_row < total )) && marker="↓"
    zcurses move input_win $row 2
    zcurses attr input_win bold green/black
    zcurses string input_win "$marker "
    zcurses attr input_win white/black
    zcurses string input_win "$visible"
  done

  cursor_y=$(( INPUT_CURSOR_ROW - INPUT_VIEW_TOP + 1 ))
  cursor_x=$(( 4 + INPUT_CURSOR_COL ))
  (( cursor_y < 1 )) && cursor_y=1
  (( cursor_y > INPUT_VISIBLE_ROWS )) && cursor_y=$INPUT_VISIBLE_ROWS
  (( cursor_x < 4 )) && cursor_x=4
  (( cursor_x > SCREEN_W - 2 )) && cursor_x=$(( SCREEN_W - 2 ))
  zcurses move input_win $cursor_y $cursor_x

  (( defer_refresh )) || zcurses refresh input_win
}

# Grow the prompt upward only when it crosses a visual-row boundary.
ui_input_changed() {
  local -i previous_height=$INPUT_H
  ui_calculate_input_height
  if (( INPUT_H != previous_height )); then
    ui_setup_windows
    ui_refresh_all 0
  else
    ui_draw_input
  fi
}

# Render the Bottom Footer Bar
ui_draw_footer() {
  local bar_str=" Enter Send  S/M-Enter Newline  ^O Model  ^R Reason  ^N New  PgUp/Dn Scroll  ^Q Quit" padded=""
  zcurses clear foot_win
  zcurses attr foot_win reverse dim white/black
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
