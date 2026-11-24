# lib/ui.zsh - Curses Layout, Multi-Pane Window Management, and Rendering for zchat

source "${${(%):-%x}:A:h}/drawing.zsh"
source "${${(%):-%x}:A:h}/terminal.zsh"
source "${${(%):-%x}:A:h}/ui_preferences.zsh"
source "${${(%):-%x}:A:h}/commands.zsh"

# Terminal Dimensions and Layout Metrics
typeset -g SCREEN_H=24
typeset -g SCREEN_W=80
typeset -g TOP_H=2
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
    SIDE_W=22
  else
    SIDE_W=26
  fi

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
  ui_window_background top_win chrome
  ui_window_background chat_win
  ui_window_background input_win editor
  ui_window_background foot_win chrome
  (( SIDE_W > 0 )) && ui_window_background side_win rail
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
  ui_refresh_all
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
  local REPLY badge badge_style='bold success/chrome' backend=Ollama endpoint="$OLLAMA_HOST"
  local title model brand=" ${ZCHAT_NAME} v${ZCHAT_VERSION} "
  local -i current=${SESSION_IDS[(Ie)$CURRENT_SESSION_ID]} badge_x model_width
  local -i badge_limit=$(( SCREEN_W / 2 - 4 ))
  local -i badge_space=$(( SCREEN_W - ${#brand} - 8 ))
  local brand_style='bold ink/accent'
  [[ $UI_COLOR_MODE == mono || $UI_COLOR_MODE == basic ]] && brand_style='reverse bold accent/chrome'
  (( badge_space < badge_limit )) && badge_limit=$badge_space
  ui_clip_label "$UI_STATUS_TEXT" "$badge_limit"
  badge="[ $REPLY ]"
  badge_x=$(( SCREEN_W - ${(m)#badge} - 2 ))
  case "$UI_STATUS_TEXT" in
    *[Ee]rror*|*failed*) badge_style='bold error/chrome' ;;
    *Stopped*|*Wait*) badge_style='bold warning/chrome' ;;
    *Thinking*|*Streaming*|*Generating*|*Compacting*|*Loading*|*Preparing*) badge_style='bold accent/chrome' ;;
  esac
  if (( $+functions[remote_selected] )) && remote_selected; then
    backend=Remote
    endpoint=''
  fi

  zchat_draw clear top_win
  if (( current && SIDE_W == 0 && badge_x > ${#brand} + 8 )); then
    ui_clip_label "${SESSION_TITLES[current]}" $(( badge_x - ${#brand} - 6 ))
    title="  $REPLY"
  fi
  ui_draw_row top_win 0 2 $(( badge_x - 2 )) "$brand_style" "$brand" 'text/chrome' "$title"
  ui_draw_row top_win 0 "$badge_x" $(( SCREEN_W - badge_x - 1 )) "$badge_style" "$badge"

  model_width=$(( SCREEN_W - ${#backend} - 6 ))
  ui_clip_label "$SESSION_MODEL" "$model_width"
  model=$REPLY
  if (( ${#endpoint} && ${(m)#model} + ${(m)#endpoint} + 5 <= model_width )); then
    endpoint="  ·  $endpoint"
  else
    endpoint=''
  fi
  ui_draw_row top_win 1 2 $(( SCREEN_W - 4 )) 'muted/chrome' "$backend  " \
    'bold text/chrome' "$model" 'muted/chrome' "$endpoint"

  (( defer_refresh )) || terminal_refresh top_win input_win
}

# Render the Sidebar
ui_draw_sidebar() {
  (( UI_SMALL_SCREEN )) && return 0
  (( SIDE_W <= 0 )) && return
  local -i defer_refresh="${1:-0}"

  local -i height=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H )) width=$(( SIDE_W - 3 ))
  local -i total=${#SESSION_IDS} current=${SESSION_IDS[(Ie)$CURRENT_SESSION_ID]}
  local -i row=2 i first=1 last=$(( height - 1 ))
  local title_style='bold text/rail' selected_style='bold text/selection' REPLY
  local rule='│' marker='›'
  [[ $UI_BORDER_MODE == plain ]] && rule='|' marker='>'
  [[ $FOCUS_PANE == sidebar ]] && title_style='reverse bold accent/rail'
  [[ $UI_COLOR_MODE == mono || $UI_COLOR_MODE == basic ]] && selected_style='reverse bold text/rail'

  zchat_draw clear side_win
  ui_fill side_win 0 $(( SIDE_W - 1 )) "$height" 1 border/rail "$rule"
  ui_draw_row side_win 0 2 $(( width - 1 )) "$title_style" ' Sessions ' 'muted/rail' "$total"
  if (( height >= 8 )); then
    last=$(( height - 3 ))
    ui_draw_row side_win $(( height - 1 )) 2 $(( width - 1 )) 'muted/rail' '^B Hide sessions'
  fi
  (( current > last - row + 1 )) && first=$(( current - (last - row) ))
  for (( i=first; i<=total && row<=last; i++, row++ )); do
    ui_clip_label "${SESSION_TITLES[i]:-Untitled}" $(( width - 3 ))
    if (( i == current )); then
      ui_fill side_win "$row" 1 1 "$width" "$selected_style" ' '
      ui_draw_row side_win "$row" 1 "$width" "$selected_style" " $marker $REPLY"
    else
      ui_draw_row side_win "$row" 1 "$width" 'text/rail' "   $REPLY"
    fi
  done

  (( defer_refresh )) || terminal_refresh side_win
}

# Render the Chat Viewport
ui_draw_chat() {
  (( UI_SMALL_SCREEN )) && return 0
  local is_stream="${1:-0}"
  local -i defer_refresh="${2:-0}"
  local -i chat_width=$(( SCREEN_W - SIDE_W ))
  local -i chat_inner_w=$(( chat_width - 4 )) content_x=2
  local -i chat_inner_h=$(( SCREEN_H - TOP_H - INPUT_H - FOOT_H - 1 ))
  (( chat_inner_w > 94 )) && chat_inner_w=94

  render_messages $chat_inner_w $is_stream

  local total_lines=${#RENDERED_LINES}
  local -i max_scroll=$(( total_lines > chat_inner_h ? total_lines - chat_inner_h : 0 ))
  (( CHAT_AUTO_SCROLL || CHAT_SCROLL_OFFSET > max_scroll )) && CHAT_SCROLL_OFFSET=$max_scroll
  (( CHAT_SCROLL_OFFSET < 0 )) && CHAT_SCROLL_OFFSET=0

  local title_style='bold text/surface' trail='' rule='─'
  [[ $UI_BORDER_MODE == plain ]] && rule='-'
  [[ $FOCUS_PANE == chat ]] && title_style='reverse bold accent/surface'
  if (( CHAT_SCROLL_OFFSET < max_scroll )); then
    trail=' PgDn Newer '
  elif (( max_scroll > 0 )); then
    trail=' PgUp History '
  fi
  zchat_draw clear chat_win
  ui_fill chat_win 0 1 1 $(( chat_width - 2 )) border/surface "$rule"
  ui_draw_row chat_win 0 "$content_x" $(( chat_inner_w - ${#trail} )) \
    "$title_style" ' Conversation ' 'muted/surface' "${#MSG_ROLES} "
  [[ -n $trail ]] && ui_draw_row chat_win 0 $(( chat_width - ${#trail} - 2 ))  \
    "${#trail}" 'muted/surface' "$trail"

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
    ui_draw_row chat_win "$row" "$content_x" "$chat_inner_w" "${spans[@]}"
  done

  (( defer_refresh )) || terminal_refresh chat_win input_win
}

# Render the multiline, cursor-following prompt editor.
ui_draw_input() {
  (( UI_SMALL_SCREEN )) && return 0
  local -i defer_refresh="${1:-0}"
  local -i max_rows=$(( INPUT_H - 2 - UI_SLASH_ROWS )) row visual_row cursor_y cursor_x total
  local visible='' marker='' title=' Message ' title_style='bold text/editor'
  local marker_style='muted/editor' body_style border_style='border/editor'

  ui_input_width
  input_layout "$REPLY" "$max_rows"
  total=${#INPUT_VISUAL_LINES}

  zchat_draw clear input_win
  if [[ "$FOCUS_PANE" == input ]]; then
    border_style='accent/editor'
    marker_style='bold accent/editor'
    title_style='reverse bold accent/editor'
  fi
  ui_attr input_win -reverse -dim -bold "$border_style"
  ui_border input_win

  if (( total > INPUT_VISIBLE_ROWS )); then
    title=" Message (${INPUT_VIEW_TOP}-$(( INPUT_VIEW_TOP + INPUT_VISIBLE_ROWS - 1 ))/${total}) "
  fi
  ui_draw_row input_win 0 2 $(( SCREEN_W - 4 )) "$title_style" "$title"

  for (( row=1; row<=INPUT_VISIBLE_ROWS; row++ )); do
    visual_row=$(( INPUT_VIEW_TOP + row - 1 ))
    visible="${INPUT_VISUAL_LINES[visual_row]}"
    marker="│"
    (( visual_row == 1 )) && marker="❯"
    (( row == 1 && INPUT_VIEW_TOP > 1 )) && marker="↑"
    (( row == INPUT_VISIBLE_ROWS && visual_row < total )) && marker="↓"
    body_style='text/editor'
    if [[ -z $INPUT_BUF ]]; then
      visible='Type a message or / for commands'
      (( SCREEN_W < 40 )) && visible='Type a message or /'
      body_style='muted/editor'
    fi
    ui_draw_row input_win "$row" 2 $(( SCREEN_W - 4 )) "$marker_style" "$marker " "$body_style" "$visible"
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
    ui_refresh_all
  else
    ui_draw_input
  fi
}

# Render the Bottom Footer Bar
ui_draw_footer() {
  (( UI_SMALL_SCREEN )) && return 0
  local -i defer_refresh="${1:-0}"
  local -a shortcuts spans=()
  local key label
  local -i trailing_x=$(( SCREEN_W - 18 )) cells
  local -i remaining=$(( trailing_x - 4 ))
  local -i is_streaming=${2:-${STREAM_PID:+1}}
  if (( is_streaming )); then
    shortcuts=('^C' ' Stop')
  else
    case "$FOCUS_PANE" in
      input) shortcuts=(Enter ' Send' 'Alt+Enter' ' Newline') ;;
      sidebar) shortcuts=('↑/↓' ' Switch' Enter ' Compose') ;;
      chat) shortcuts=('PgUp/Dn' ' Scroll' End ' Latest') ;;
    esac
  fi
  shortcuts+=('^O' ' Model' '^N' ' New' Tab ' Focus')
  for key label in "${shortcuts[@]}"; do
    cells=$(( ${(m)#key} + ${#label} ))
    (( cells <= remaining )) || continue
    spans+=('bold text/chrome' "$key" 'muted/chrome' "$label  ")
    (( remaining -= cells + 2 ))
  done

  zchat_draw clear foot_win
  (( ${#spans} )) && ui_draw_row foot_win 0 2 $(( trailing_x - 3 )) "${spans[@]}"
  ui_draw_row foot_win 0 "$trailing_x" 16 'bold text/chrome' '^H' 'muted/chrome' ' Help  ' \
    'bold text/chrome' '^Q' 'muted/chrome' ' Quit'
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
  ui_draw_footer 1 "$is_stream"
  # Curses takes the physical cursor from the last presented window.
  windows+=(chat_win foot_win input_win)
  terminal_refresh "${windows[@]}"
}

# Paint only the changing windows, then use the prompt's saved cursor position.
ui_refresh_stream() {
  (( UI_SMALL_SCREEN )) && return 0
  ui_draw_header 1
  ui_draw_chat 1 1
  terminal_refresh top_win chat_win input_win
}

ui_toggle_sidebar() {
  emulate -L zsh
  (( UI_ACTIVE )) || return 0
  UI_SIDEBAR_HIDDEN=$(( ! UI_SIDEBAR_HIDDEN ))
  ui_setup_windows
  ui_preferences_save || UI_STATUS_TEXT='Could not save sidebar preference'
  ui_refresh_all
}
