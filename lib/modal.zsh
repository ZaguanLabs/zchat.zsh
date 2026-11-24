# lib/modal.zsh - Overlay Modals and Pickers for zchat

# Helper: Draw framed modal box with title
_modal_frame() {
  local win="$1"
  local title="$2"
  local -a geometry=()

  ui_window_background "$win" editor
  zchat_draw clear "$win"
  ui_attr "$win" -reverse -dim -bold accent/editor
  ui_border "$win"
  zchat_draw position "$win" geometry || return 1
  ui_draw_row "$win" 0 2 $(( geometry[6] - 4 )) 'reverse bold accent/editor' " $title "
}

_modal_choice() {
  local -i row=$1 width=$2 selected=$3
  local text="$4" style='text/editor' REPLY
  ui_clip_label "$text" "$width"
  if (( selected )); then
    style='bold text/selection'
    [[ $UI_COLOR_MODE == mono || $UI_COLOR_MODE == basic ]] && style='reverse bold text/editor'
    ui_fill modal_win "$row" 2 1 "$width" "$style" ' '
  fi
  ui_draw_row modal_win "$row" 2 "$width" "$style" "$REPLY"
}

# Modal 1: Select Model
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

  models+=("${REMOTE_MODELS[@]}")
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
  local row=2 mod_name="" display_str=""
  local ch="" key="" mouse="" cur_ch="" cur_key=""

  while true; do
    _modal_frame modal_win 'Select model'

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
      [[ "$mod_name" == "$SESSION_MODEL" ]] && display_str="• ${mod_name}"
      _modal_choice "$row" $(( m_w - 4 )) $(( i == sel )) "$display_str"
      (( row++ ))
    done

    ui_draw_row modal_win $(( m_h - 2 )) 2 $(( m_w - 4 )) 'muted/editor' "${sel}/${total}  ↑/↓  Enter  Esc"

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
  local row=2 i=1 REPLY

  while true; do
    _modal_frame modal_win 'System prompt'

    row=2
    for (( i=1; i<=total; i++ )); do
      _modal_choice "$row" $(( m_w - 4 )) $(( i == sel )) "  ${presets[i]}"
      (( row++ ))
    done

    ui_clip_label "Active · ${SESSION_SYSTEM_PROMPT}" $(( m_w - 4 ))
    ui_draw_row modal_win $(( m_h - 3 )) 2 $(( m_w - 4 )) 'muted/editor' "$REPLY"
    ui_draw_row modal_win $(( m_h - 2 )) 2 $(( m_w - 4 )) 'muted/editor' '↑/↓  Enter  Esc'

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
    "Ctrl+O        : Open model picker (switch model)"
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

  local -i row offset=0 capacity=$(( m_h - 4 )) index maximum
  local item="" ch="" key="" mouse=""
  local -a help_lines=()
  for item in "${help_items[@]}"; do
    zchat_wrap "$item" $(( m_w - 4 ))
    help_lines+=("${ZCHAT_WRAPPED[@]}")
  done
  maximum=$(( ${#help_lines} - capacity ))
  (( maximum < 0 )) && maximum=0
  while true; do
    _modal_frame modal_win 'Keyboard shortcuts'
    for (( row=0; row<capacity; row++ )); do
      index=$(( offset + row + 1 ))
      (( index <= ${#help_lines} )) || break
      ui_draw_row modal_win $(( row + 2 )) 2 $(( m_w - 4 )) text/editor "${help_lines[index]}"
    done
    ui_draw_row modal_win $(( m_h - 2 )) 2 $(( m_w - 4 )) 'muted/editor' '↑/↓ Scroll  Esc Close'
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
