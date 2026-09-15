# lib/modal.zsh - Overlay Modals and Pickers for zchat

# Helper: Draw framed modal box with title
_modal_frame() {
  local win="$1"
  local title="$2"

  ui_window_background "$win"
  zchat_draw clear "$win"
  ui_attr "$win" -dim -bold border/surface
  ui_border "$win"

  zchat_draw move "$win" 0 2
  ui_attr "$win" bold white/black
  zchat_curses_string "$win" " ${title} "
  ui_attr "$win" default/default
}

# Modal 1: Select Ollama Model
modal_select_model() {
  (( UI_SMALL_SCREEN )) && return 0
  local -a models=()
  local -i request_status=1
  if api_async_start GET /api/tags "" "$OLLAMA_HOST"; then
    ui_wait_for_async_request "Loading models"
    request_status=$?
    if (( request_status == 130 )); then
      api_async_cancel
      return 130
    fi
    if api_async_collect && json_parse_models "$API_HTTP_BODY"; then
      models=("${JSON_MODEL_NAMES[@]}")
    fi
  fi

  local total=${#models}
  if (( total == 0 )); then
    models=("$SESSION_MODEL")
    total=1
  fi

  local sel=1
  local i=1
  for (( i=1; i<=total; i++ )); do
    if [[ "${models[i]}" == "$SESSION_MODEL" ]]; then
      sel=$i
      break
    fi
  done

  local m_h=18
  local m_w=56
  (( m_h > SCREEN_H - 2 )) && m_h=$(( SCREEN_H - 2 ))
  (( m_w > SCREEN_W - 4 )) && m_w=$(( SCREEN_W - 4 ))

  local m_y=$(( (SCREEN_H - m_h) / 2 ))
  local m_x=$(( (SCREEN_W - m_w) / 2 ))

  zchat_draw addwin modal_win $m_h $m_w $m_y $m_x 2>/dev/null || return

  local max_visible=$(( m_h - 4 ))
  local scroll_top=1
  local row=2 mod_name="" display_str="" padded=""
  local ch="" key="" mouse="" cur_ch="" cur_key=""

  while true; do
    _modal_frame modal_win "Select Ollama Model (↑/↓: Nav, Enter: Select, Esc: Cancel)"

    # Adjust scrolling window
    if (( sel < scroll_top )); then
      scroll_top=$sel
    elif (( sel >= scroll_top + max_visible )); then
      scroll_top=$(( sel - max_visible + 1 ))
    fi

    row=2
    for (( i=scroll_top; i<=total && i<scroll_top+max_visible; i++ )); do
      mod_name="${models[i]}"
      display_str="  ${mod_name}"
      [[ "$mod_name" == "$SESSION_MODEL" ]] && display_str="★ ${mod_name}"

      zchat_draw move modal_win $row 2
      if (( i == sel )); then
        ui_attr modal_win reverse bold cyan/black
        zchat_pad_right "$display_str" $(( m_w - 4 ))
        padded="$REPLY"
        zchat_curses_string modal_win "$padded"
        ui_attr modal_win -reverse default/default
      else
        ui_attr modal_win white/black
        zchat_pad_right "$display_str" $(( m_w - 4 ))
        padded="$REPLY"
        zchat_curses_string modal_win "$padded"
      fi
      (( row++ ))
    done

    # Status count at bottom
    zchat_draw move modal_win $(( m_h - 2 )) 2
    ui_attr modal_win dim white/black
    zchat_curses_string modal_win "Model ${sel}/${total}  [Host: ${OLLAMA_HOST}]"

    terminal_refresh modal_win

    ch=""
    key=""
    mouse=""
    _modal_input
    cur_ch="$ch"
    cur_key="$key"
    ch="" key="" mouse=""

    if [[ "$cur_key" == "UP" || "$cur_ch" == "k" ]]; then
      (( sel > 1 )) && (( sel-- ))
    elif [[ "$cur_key" == "DOWN" || "$cur_ch" == "j" ]]; then
      (( sel < total )) && (( sel++ ))
    elif [[ "$cur_key" == "PPAGE" ]]; then
      (( sel -= 5 ))
      (( sel < 1 )) && sel=1
    elif [[ "$cur_key" == "NPAGE" ]]; then
      (( sel += 5 ))
      (( sel > total )) && sel=$total
    elif [[ "$cur_ch" == $'\n' || "$cur_ch" == $'\r' || "$cur_key" == "ENTER" || "$cur_key" == "PADENTER" ]]; then
      SESSION_MODEL="${models[sel]}"
      state_save_session || UI_STATUS_TEXT="Save error"
      break
    elif [[ "$cur_ch" == $'\x1b' || "$cur_ch" == "q" || "$cur_ch" == $'\x03' ]]; then
      break
    fi
  done

  zchat_draw delwin modal_win 2>/dev/null
}

# Modal 2: Edit System Prompt
modal_system_prompt() {
  (( UI_SMALL_SCREEN )) && return 0
  local -a presets=(
    "Default: Helpful, knowledgeable, and concise AI assistant."
    "Coding: Expert software engineer providing minimal, correct code."
    "Concise: Extremely direct and compact answers with no fluff."
    "Explain Like I'm 5: Simple analogies and gentle explanations."
    "Custom / Keep Current"
  )

  local sel=1
  local total=${#presets}
  local m_h=14
  local m_w=68
  (( m_h > SCREEN_H - 2 )) && m_h=$(( SCREEN_H - 2 ))
  (( m_w > SCREEN_W - 4 )) && m_w=$(( SCREEN_W - 4 ))

  local m_y=$(( (SCREEN_H - m_h) / 2 ))
  local m_x=$(( (SCREEN_W - m_w) / 2 ))

  zchat_draw addwin modal_win $m_h $m_w $m_y $m_x 2>/dev/null || return

  local ch="" key="" mouse="" cur_ch="" cur_key=""
  local row=2 i=1 p="" padded="" cur_preview=""

  while true; do
    _modal_frame modal_win "System Prompt Presets (↑/↓: Nav, Enter: Set, Esc: Cancel)"

    row=2
    for (( i=1; i<=total; i++ )); do
      zchat_draw move modal_win $row 2
      p="${presets[i]}"
      zchat_pad_right "  $p" $(( m_w - 4 ))
      padded="$REPLY"
      if (( i == sel )); then
        ui_attr modal_win reverse bold magenta/black
        zchat_curses_string modal_win "$padded"
        ui_attr modal_win -reverse default/default
      else
        ui_attr modal_win white/black
        zchat_curses_string modal_win "$padded"
      fi
      (( row++ ))
    done

    zchat_draw move modal_win $(( m_h - 3 )) 2
    ui_attr modal_win dim white/black
    cur_preview="${SESSION_SYSTEM_PROMPT[1,$(( m_w - 14 ))]}"
    zchat_curses_string modal_win "Active: \"${cur_preview}...\""

    terminal_refresh modal_win

    ch=""
    key=""
    mouse=""
    _modal_input
    cur_ch="$ch"
    cur_key="$key"
    ch="" key="" mouse=""

    if [[ "$cur_key" == "UP" || "$cur_ch" == "k" ]]; then
      (( sel > 1 )) && (( sel-- ))
    elif [[ "$cur_key" == "DOWN" || "$cur_ch" == "j" ]]; then
      (( sel < total )) && (( sel++ ))
    elif [[ "$cur_ch" == $'\n' || "$cur_ch" == $'\r' || "$cur_key" == "ENTER" || "$cur_key" == "PADENTER" ]]; then
      case "$sel" in
        1) SESSION_SYSTEM_PROMPT="You are a helpful, knowledgeable, and concise AI assistant." ;;
        2) SESSION_SYSTEM_PROMPT="You are an expert software engineer. Provide clean, correct, minimal code with concise explanations." ;;
        3) SESSION_SYSTEM_PROMPT="Provide direct, concise answers. Avoid pleasantries, preambles, and summaries." ;;
        4) SESSION_SYSTEM_PROMPT="Explain concepts using simple everyday metaphors as if explaining to a 5-year-old." ;;
        5) ;;
      esac
      state_save_session || UI_STATUS_TEXT="Save error"
      break
    elif [[ "$cur_ch" == $'\x1b' || "$cur_ch" == "q" || "$cur_ch" == $'\x03' ]]; then
      break
    fi
  done

  zchat_draw delwin modal_win 2>/dev/null
}

# Modal 3: Help / Keybindings
modal_show_help() {
  (( UI_SMALL_SCREEN )) && return 0
  local m_h=24
  local m_w=72
  (( m_h > SCREEN_H - 2 )) && m_h=$(( SCREEN_H - 2 ))
  (( m_w > SCREEN_W - 4 )) && m_w=$(( SCREEN_W - 4 ))

  local m_y=$(( (SCREEN_H - m_h) / 2 ))
  local m_x=$(( (SCREEN_W - m_w) / 2 ))

  zchat_draw addwin modal_win $m_h $m_w $m_y $m_x 2>/dev/null || return

  local -a help_items=(
    "Enter         : Send message"
    "Shift/Alt+Enter: Insert a prompt newline"
    "Ctrl+R        : Toggle Reasoning expand/collapse"
    "Ctrl+Y /copy  : Open plain-text transcript copy view"
    "Ctrl+N        : Start a new chat session"
    "Ctrl+O        : Open model picker (switch Ollama model)"
    "/host URL     : Change and save the Ollama URL"
    "/compact/context: Checkpoint / show context budget"
    "Ctrl+S        : Change system prompt preset"
    "Ctrl+C        : Cancel active streaming / Clear input"
    "Ctrl+B /sidebar: Toggle sessions sidebar (saved)"
    "Alt+1 / Alt+2 : Focus sessions / message input"
    "/ then Tab    : Complete a slash command (Up/Down selects)"
    "Tab           : Cycle input, sessions and chat focus"
    "PgUp / PgDn   : Scroll chat history"
    "Home / End    : Jump to start / end of chat"
    "Ctrl+U        : Clear input line"
    "Ctrl+W        : Delete previous word"
    "Up / Down     : Navigate input history (when input empty)"
    "Ctrl+Q / ^D   : Quit zchat.zsh"
  )

  local -i row offset=0 capacity=$(( m_h - 3 )) index maximum
  local item="" ch="" key="" mouse=""
  maximum=$(( ${#help_items} - capacity ))
  (( maximum < 0 )) && maximum=0
  while true; do
    _modal_frame modal_win "Help · ↑/↓ Scroll · Esc Close"
    for (( row=0; row<capacity; row++ )); do
      index=$(( offset + row + 1 ))
      (( index <= ${#help_items} )) || break
      ui_draw_row modal_win $(( row + 2 )) 2 $(( m_w - 4 )) text/surface "${help_items[index]}"
    done
    terminal_refresh modal_win
    ch=''; key=''; mouse=''
    _modal_input
    case "$key" in
      UP) (( offset-- )) ;;
      DOWN) (( offset++ )) ;;
      PPAGE) (( offset-=capacity )) ;;
      NPAGE) (( offset+=capacity )) ;;
      HOME) offset=0 ;;
      END) offset=$maximum ;;
      PASTE*) continue ;;
      *) break ;;
    esac
    (( offset < 0 )) && offset=0
    (( offset > maximum )) && offset=$maximum
  done

  zchat_draw delwin modal_win 2>/dev/null
}

# Keep resize polling live while an overlay owns input. Close on resize so the
# caller redraws a correctly sized chat; never retain an off-screen modal.
_modal_input() {
  local -i TERMINAL_DISCARD_PASTE=1
  local -i previous_h=$SCREEN_H previous_w=$SCREEN_W
  while true; do
    zchat_draw timeout modal_win 50
    terminal_read_event modal_win ch key mouse
    ui_poll_resize
    if (( SCREEN_H != previous_h || SCREEN_W != previous_w )); then
      ch=$'\e'; key=''
      return 0
    fi
    [[ -n "$ch$key" ]] && return 0
  done
}
