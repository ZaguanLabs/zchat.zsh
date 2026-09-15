# lib/ui.zsh - Curses Layout, Multi-Pane Window Management, and Rendering for zchat

source "${${(%):-%x}:A:h}/drawing.zsh"
source "${${(%):-%x}:A:h}/terminal.zsh"
source "${${(%):-%x}:A:h}/ui_preferences.zsh"
source "${${(%):-%x}:A:h}/commands.zsh"

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
typeset -gi UI_ACTIVE=0 UI_NATIVE_GEOMETRY=0 UI_SMALL_SCREEN=0
typeset -g UI_INPUT_WINDOW=input_win
typeset -gi UI_SIDEBAR_HIDDEN=0 UI_SLASH_ROWS=0 UI_SLASH_SELECTED=1

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
  ui_slash_update
  INPUT_H=$(( INPUT_VISIBLE_ROWS + 2 + UI_SLASH_ROWS ))
}

# Query terminal geometry and allocate curses windows
ui_setup_windows() {
  ui_destroy_windows

  # Get dimensions from stdscr (pos: cur_y cur_x beg_y beg_x max_y max_x)
  local -a scr_pos=()
  zchat_draw position stdscr scr_pos 2>/dev/null
  SCREEN_H=${scr_pos[5]:-${LINES:-24}}
  SCREEN_W=${scr_pos[6]:-${COLUMNS:-80}}

  UI_SMALL_SCREEN=0
  UI_INPUT_WINDOW=input_win
  if (( SCREEN_H < 12 || SCREEN_W < 32 )); then
    UI_SMALL_SCREEN=1
    UI_INPUT_WINDOW=stdscr
    SIDE_W=0
    FOCUS_PANE=input
    return 0
  fi

  # Dynamic sidebar width
  if (( UI_SIDEBAR_HIDDEN || SCREEN_W < 75 )); then
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
  zchat_draw addwin top_win $TOP_H $SCREEN_W 0 0 2>/dev/null
  if (( SIDE_W > 0 )); then
    zchat_draw addwin side_win $main_h $SIDE_W $TOP_H 0 2>/dev/null
  fi
  zchat_draw addwin chat_win $main_h $chat_w $TOP_H $chat_x 2>/dev/null
  zchat_draw addwin input_win $INPUT_H $SCREEN_W $input_y 0 2>/dev/null
  zchat_draw addwin foot_win $FOOT_H $SCREEN_W $foot_y 0 2>/dev/null
  local window
  for window in top_win chat_win input_win foot_win; do ui_window_background "$window"; done
  (( SIDE_W > 0 )) && ui_window_background side_win
  (( SIDE_W == 0 )) && [[ "$FOCUS_PANE" == sidebar ]] && FOCUS_PANE=input
  return 0
}

# Check the physical terminal dimensions without an external stty dependency.
ui_poll_resize() {
  local -F now=$EPOCHREALTIME
  (( now < UI_NEXT_RESIZE_CHECK )) && return 0
  UI_NEXT_RESIZE_CHECK=$(( now + UI_RESIZE_CHECK_INTERVAL ))

  local new_h new_w
  if (( UI_NATIVE_GEOMETRY )); then
    local -a dimensions=()
    zchat_draw geometry dimensions 2>/dev/null || return 0
    (( ${#dimensions} == 2 )) || return 0
    new_h=$dimensions[1]; new_w=$dimensions[2]
  else
    # Stock curses: refresh terminfo to query the TTY without a subprocess.
    zmodload -u zsh/terminfo 2>/dev/null || return 0
    zmodload zsh/terminfo 2>/dev/null || return 0
    new_h=${terminfo[lines]:-0}; new_w=${terminfo[cols]:-0}
  fi
  [[ "$new_h" == <1-> && "$new_w" == <1-> ]] || return 0
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
  zchat_draw resize "$new_h" "$new_w" endwin 2>/dev/null || return 1

  ui_setup_windows
  ui_refresh_all 0
}

# Keep non-streaming Ollama metadata and checkpoint requests cancellable. Other
# editing input waits for the request, while scrolling and resizing stay live.
ui_wait_for_async_request() {
  local -i TERMINAL_DISCARD_PASTE=1
  local label="${1:-Working}"
  local ch="" key="" mouse=""
  local previous_status="$UI_STATUS_TEXT"
  UI_STATUS_TEXT="$label"
  ui_draw_header
  while ! api_async_ready; do
    ui_poll_resize
    ch=""; key=""; mouse=""
    zchat_draw timeout "$UI_INPUT_WINDOW" 50
    terminal_read_event "$UI_INPUT_WINDOW" ch key mouse
    if [[ "$ch" == $'\x1b' || "$ch" == $'\x03' ]]; then
      UI_STATUS_TEXT="$previous_status"
      ui_draw_header
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
  UI_STATUS_TEXT="$previous_status"
  ui_draw_header
  return 0
}

ui_wait_for_compaction() {
  ui_wait_for_async_request "Compacting"
}

# Destroy all windows
ui_destroy_windows() {
  zchat_draw delwin top_win 2>/dev/null
  zchat_draw delwin side_win 2>/dev/null
  zchat_draw delwin chat_win 2>/dev/null
  zchat_draw delwin input_win 2>/dev/null
  zchat_draw delwin foot_win 2>/dev/null
}

# Enter and leave curses through one lifecycle so temporary plain-text views
# restore the same terminal modes as normal startup and shutdown.
ui_init() {
  local -i is_streaming="${1:-0}"
  zchat_draw init || return 1
  ui_theme_init
  UI_NATIVE_GEOMETRY=0
  (( ${ZCHAT_DRAW_FEATURES[(Ie)geometry]} )) && UI_NATIVE_GEOMETRY=1
  UI_ACTIVE=1
  ui_preferences_load
  input_detect_boundaries
  terminal_start
  ui_setup_windows
  ui_refresh_all "$is_streaming"
}

ui_end() {
  (( UI_ACTIVE )) || return 0
  UI_ACTIVE=0
  terminal_end
  ui_destroy_windows
  zchat_draw end 2>/dev/null
  print -rn -- "${terminfo[cnorm]}" 2>/dev/null
}

# Build the visible transcript as stable plain text. Expanded reasoning is
# included and collapsed reasoning remains hidden, matching the curses view.
ui_plain_transcript() {
  local output="" label="" role="" content="" thinking="" time="" model=""
  local -i i
  for (( i=1; i<=${#MSG_ROLES}; i++ )); do
    role="${MSG_ROLES[i]}"
    content="${MSG_CONTENTS[i]}"
    thinking="${MSG_THINKINGS[i]:-}"
    time="${MSG_TIMES[i]:-}"
    case "$role" in
      user) label="You" ;;
      assistant)
        model="${MSG_MODELS[i]:-$SESSION_MODEL}"
        label="Assistant (${model})"
        ;;
      system) label="System" ;;
      error) label="Error" ;;
      *) label="${role:u}" ;;
    esac
    [[ -n "$output" ]] && output+=$'\n'
    output+="=== ${label}${time:+  ${time}} ==="$'\n'
    if [[ -n "$thinking" ]] && (( ${MSG_THINKING_EXPANDED[i]:-0} )); then
      output+=$'Reasoning:\n'"$thinking"$'\n\n'
    fi
    [[ -n "$content" ]] && output+="$content"$'\n'
  done
  [[ -n "$output" ]] || output="(No transcript events yet.)"$'\n'
  zchat_terminal_safe "$output" 1
}

# Suspend curses so terminal mouse selection and native copy shortcuts work
# normally, without introducing a platform-specific clipboard dependency.
ui_copy_view() {
  local -i is_streaming="${1:-0}"
  local transcript="" ignored=""
  local -i suspend_status=0
  (( UI_ACTIVE )) || return 1
  ui_plain_transcript
  transcript="$REPLY"
  terminal_suspend
  suspend_status=$?
  if (( suspend_status == 2 )); then
    ui_end
  elif (( suspend_status != 0 )); then
    UI_STATUS_TEXT='Finish pasting before opening the copy view'
    ui_draw_header
    return 0
  fi
  {
    print -rn -- $'\e[2J\e[H'
    print -r -- "zchat.zsh transcript copy view"
    print -r -- "Select text with the terminal mouse and use its normal copy shortcut. Scroll as needed."
    print -r -- "Press Enter when finished to return to zchat."
    print -r -- ""
    print -r -- "$transcript"
    print -r -- ""
    print -rn -- "Press Enter to return: "
  } > /dev/tty
  IFS= read -r ignored < /dev/tty
  if (( suspend_status == 0 )); then
    terminal_resume || return 1
    ui_setup_windows
    ui_refresh_all "$is_streaming"
  else
    ui_init "$is_streaming"
  fi
}

# Render the Top Header Bar
ui_draw_header() {
  (( UI_SMALL_SCREEN )) && return 0
  local -i defer_refresh="${1:-0}"
  local stat_val="$UI_STATUS_TEXT" badge identity badge_style=success/surface
  zchat_terminal_safe "$stat_val"
  zchat_clip "$REPLY" $(( SCREEN_W / 2 - 6 ))
  badge="[ $REPLY ]"
  local -i status_x=$(( SCREEN_W - ${(m)#badge} - 2 ))
  identity="${ZCHAT_NAME} · ${SESSION_MODEL} (${OLLAMA_HOST})"
  case "$stat_val" in
    *Error*|*Stopped*) badge_style=error/surface ;;
    *Thinking*|*Streaming*|*Generating*|*Compacting*) badge_style=accent/surface ;;
  esac
  zchat_draw clear top_win
  ui_attr top_win -dim -bold border/surface
  ui_border top_win
  ui_draw_row top_win 1 2 $(( status_x - 3 )) 'text/surface' "$identity"
  ui_draw_row top_win 1 "$status_x" $(( SCREEN_W - status_x - 1 )) "$badge_style" "$badge"

  (( defer_refresh )) || terminal_refresh top_win
}

# Render the Sidebar
ui_draw_sidebar() {
  (( UI_SMALL_SCREEN )) && return 0
  (( SIDE_W <= 0 )) && return
  local -i defer_refresh="${1:-0}"

  local inner_h=$(( SCREEN_H - 3 - INPUT_H - 1 - 2 ))
  local inner_w=$(( SIDE_W - 2 ))
  local total=${#SESSION_IDS}
  local row=1 i=1 is_curr=0
  local s_id="" s_title="" display_txt="" line_fmt=""

  zchat_draw clear side_win
  if [[ "$FOCUS_PANE" == "sidebar" ]]; then
    ui_attr side_win -dim bold accent/surface
  else
    ui_attr side_win -dim -bold border/surface
  fi
  ui_border side_win
  zchat_draw move side_win 0 2
  ui_attr side_win bold white/black
  zchat_curses_string side_win " Sessions (${#SESSION_IDS}) "

  for (( i=1; i<=total && row<=inner_h; i++ )); do
    s_id="${SESSION_IDS[i]}"
    s_title="${SESSION_TITLES[i]:-Untitled}"
    is_curr=0
    [[ "$s_id" == "$CURRENT_SESSION_ID" ]] && is_curr=1

    zchat_draw move side_win $row 1
    zchat_terminal_safe "$s_title"
    zchat_clip "$REPLY" $(( inner_w - 4 )); display_txt="$REPLY"

    if (( is_curr )); then
      ui_attr side_win bold green/black
      zchat_pad_right "$display_txt" $(( inner_w - 4 ))
      line_fmt=" ▶ $REPLY"
      zchat_curses_string side_win "$line_fmt"
    else
      ui_attr side_win dim white/black
      zchat_pad_right "$display_txt" $(( inner_w - 4 ))
      line_fmt="   $REPLY"
      zchat_curses_string side_win "$line_fmt"
    fi
    (( row++ ))
  done

  # Bottom helper info in sidebar
  if (( inner_h - row >= 3 )); then
    zchat_draw move side_win $(( inner_h - 2 )) 1
    ui_attr side_win dim cyan/black
    zchat_curses_string side_win " ^N: New Chat"
    zchat_draw move side_win $(( inner_h - 1 )) 1
    zchat_curses_string side_win " ^O: Models"
  fi

  (( defer_refresh )) || terminal_refresh side_win
}

# Render the Chat Viewport
ui_draw_chat() {
  (( UI_SMALL_SCREEN )) && return 0
  local is_stream="${1:-0}"
  local -i defer_refresh="${2:-0}"
  local chat_inner_w=$(( SCREEN_W - SIDE_W - 2 ))
  local chat_inner_h=$(( SCREEN_H - 3 - INPUT_H - 1 - 2 ))

  render_messages $chat_inner_w $is_stream

  zchat_draw clear chat_win
  if [[ "$FOCUS_PANE" == "chat" ]]; then
    ui_attr chat_win -dim bold accent/surface
  else
    ui_attr chat_win -dim -bold border/surface
  fi
  ui_border chat_win

  zchat_draw move chat_win 0 2
  ui_attr chat_win bold cyan/black
  zchat_curses_string chat_win " Chat Transcript (${#MSG_ROLES} msgs) "

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

  local -i row idx span_index
  local line_str attr_str span_str
  local -a spans=()
  for (( row=1; row<=chat_inner_h; row++ )); do
    idx=$(( CHAT_SCROLL_OFFSET + row ))
    (( idx <= total_lines )) || break
    line_str="${RENDERED_LINES[idx]}"
    attr_str="${RENDERED_ATTRS[idx]:-default/default}"
    span_str="${RENDERED_SPANS[idx]:-}"
    spans=()
    if [[ -n "$span_str" ]] && render_unpack_spans "$span_str"; then
      for (( span_index=1; span_index<=${#RENDER_SPAN_TEXTS}; span_index++ )); do
        spans+=("${RENDER_SPAN_ATTRS[span_index]:-$attr_str}" "${RENDER_SPAN_TEXTS[span_index]}")
      done
    else
      spans=("$attr_str" "$line_str")
    fi
    ui_draw_row chat_win "$row" 1 "$chat_inner_w" "${spans[@]}"
  done

  # Scroll indicator badge
  if (( total_lines > chat_inner_h && CHAT_SCROLL_OFFSET < total_lines - chat_inner_h )); then
    zchat_draw move chat_win 0 $(( chat_inner_w - 18 ))
    ui_attr chat_win -dim bold accent/surface
    zchat_curses_string chat_win " [▼ Scroll: PgDn] "
  elif (( CHAT_SCROLL_OFFSET > 0 )); then
    zchat_draw move chat_win 0 $(( chat_inner_w - 18 ))
    ui_attr chat_win dim white/black
    zchat_curses_string chat_win " [▲ Scrolled Up] "
  fi

  (( defer_refresh )) || terminal_refresh chat_win
}

# Render the multiline, cursor-following prompt editor.
ui_draw_input() {
  (( UI_SMALL_SCREEN )) && return 0
  local -i defer_refresh="${1:-0}"
  local -i max_rows=$(( INPUT_H - 2 - UI_SLASH_ROWS )) row visual_row cursor_y cursor_x total
  local visible="" marker="" title=" Message "

  ui_input_width
  input_layout "$REPLY" "$max_rows"
  total=${#INPUT_VISUAL_LINES}

  zchat_draw clear input_win
  if [[ "$FOCUS_PANE" == "input" ]]; then
    ui_attr input_win -dim bold accent/surface
  else
    ui_attr input_win -dim -bold border/surface
  fi
  ui_border input_win

  zchat_draw move input_win 0 2
  ui_attr input_win bold white/black
  if (( total > INPUT_VISIBLE_ROWS )); then
    title=" Message (${INPUT_VIEW_TOP}-$(( INPUT_VIEW_TOP + INPUT_VISIBLE_ROWS - 1 ))/${total}) "
  fi
  zchat_curses_string input_win "${title[1,$(( SCREEN_W - 4 ))]}"

  for (( row=1; row<=INPUT_VISIBLE_ROWS; row++ )); do
    visual_row=$(( INPUT_VIEW_TOP + row - 1 ))
    visible="${INPUT_VISUAL_LINES[visual_row]}"
    marker="│"
    (( visual_row == 1 )) && marker="❯"
    (( row == 1 && INPUT_VIEW_TOP > 1 )) && marker="↑"
    (( row == INPUT_VISIBLE_ROWS && visual_row < total )) && marker="↓"
    zchat_draw move input_win $row 2
    ui_attr input_win -dim bold accent/surface
    zchat_curses_string input_win "$marker "
    ui_attr input_win white/black
    zchat_curses_string input_win "$visible"
  done

  ui_slash_draw

  cursor_y=$(( INPUT_CURSOR_ROW - INPUT_VIEW_TOP + 1 ))
  cursor_x=$(( 4 + INPUT_CURSOR_COL ))
  (( cursor_y < 1 )) && cursor_y=1
  (( cursor_y > INPUT_VISIBLE_ROWS )) && cursor_y=$INPUT_VISIBLE_ROWS
  (( cursor_x < 4 )) && cursor_x=4
  (( cursor_x > SCREEN_W - 2 )) && cursor_x=$(( SCREEN_W - 2 ))
  zchat_draw move input_win $cursor_y $cursor_x

  (( defer_refresh )) || terminal_refresh input_win
}

# Grow the prompt upward only when it crosses a visual-row boundary.
ui_input_changed() {
  (( UI_SMALL_SCREEN )) && { ui_refresh_all; return 0; }
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
  (( UI_SMALL_SCREEN )) && return 0
  local -i defer_refresh="${1:-0}"
  local bar_str=" Enter Send   Alt+Enter Newline   ^O Model   ^N New   ^H Help   ^Q Quit" padded=""
  zchat_draw clear foot_win
  ui_attr foot_win -reverse -bold muted/surface
  zchat_pad_right "$bar_str" "$SCREEN_W"
  padded="$REPLY"
  zchat_draw move foot_win 0 0
  zchat_curses_string foot_win "$padded"
  ui_attr foot_win -reverse default/default
  (( defer_refresh )) || terminal_refresh foot_win
}

# Full UI refresh
ui_refresh_all() {
  if (( ! UI_SMALL_SCREEN )); then
    local -i previous_height=$INPUT_H
    ui_calculate_input_height
    (( INPUT_H != previous_height )) && ui_setup_windows
  fi
  if (( UI_SMALL_SCREEN )); then
    zchat_draw clear stdscr
    ui_draw_row stdscr 0 0 $(( SCREEN_W - 1 )) 'text/surface' 'Enlarge terminal to 32 × 12'
    (( SCREEN_H > 1 )) && ui_draw_row stdscr 1 0 $(( SCREEN_W - 1 )) 'muted/surface' 'Ctrl+Q quits'
    terminal_refresh stdscr
    return 0
  fi
  local is_stream="${1:-${STREAM_PID:+1}}"
  is_stream=${is_stream:-0}
  local -a windows=(top_win)
  ui_draw_header 1
  if (( SIDE_W > 0 )); then
    ui_draw_sidebar 1
    windows+=(side_win)
  fi
  ui_draw_chat "$is_stream" 1
  ui_draw_input 1
  ui_draw_footer 1
  windows+=(chat_win input_win foot_win)
  terminal_refresh "${windows[@]}"
}

# Streaming changes only the status badge and transcript. Avoid repainting the
# sidebar, prompt, and footer for every visual frame.
ui_refresh_stream() {
  (( UI_SMALL_SCREEN )) && return 0
  ui_draw_header 1
  ui_draw_chat 1 1
  terminal_refresh top_win chat_win
}

ui_toggle_sidebar() {
  emulate -L zsh
  (( UI_ACTIVE )) || return 0
  UI_SIDEBAR_HIDDEN=$(( ! UI_SIDEBAR_HIDDEN ))
  ui_setup_windows
  ui_preferences_save || UI_STATUS_TEXT='Could not save sidebar preference'
  ui_refresh_all
}
