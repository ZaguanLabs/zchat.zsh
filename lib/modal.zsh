# lib/modal.zsh - Overlay Modals and Pickers for zchat

# Helper: Draw framed modal box with title
_modal_frame() {
  local win="$1"
  local title="$2"
  local border_color="${3:-cyan/black}"

  zcurses clear "$win"
  zcurses attr "$win" bold $=border_color
  zcurses border "$win"

  zcurses move "$win" 0 2
  zcurses attr "$win" bold white/black
  zcurses string "$win" " ${title} "
  zcurses attr "$win" default/default
}

# Modal 1: Select Ollama Model
modal_select_model() {
  local -a models=()
  if api_get_models; then
    models=("${API_MODELS[@]}")
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
  (( m_h > SCREEN_H - 4 )) && m_h=$(( SCREEN_H - 4 ))
  (( m_w > SCREEN_W - 4 )) && m_w=$(( SCREEN_W - 4 ))

  local m_y=$(( (SCREEN_H - m_h) / 2 ))
  local m_x=$(( (SCREEN_W - m_w) / 2 ))

  zcurses addwin modal_win $m_h $m_w $m_y $m_x 2>/dev/null || return

  local max_visible=$(( m_h - 4 ))
  local scroll_top=1
  local row=2 mod_name="" display_str="" padded=""
  local ch="" key="" mouse="" cur_ch="" cur_key=""

  while true; do
    _modal_frame modal_win "Select Ollama Model (↑/↓: Nav, Enter: Select, Esc: Cancel)" "cyan/black"

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

      zcurses move modal_win $row 2
      if (( i == sel )); then
        zcurses attr modal_win reverse bold cyan/black
        zchat_pad_right "$display_str" $(( m_w - 4 ))
        padded="$REPLY"
        zcurses string modal_win "$padded"
        zcurses attr modal_win -reverse default/default
      else
        zcurses attr modal_win white/black
        zchat_pad_right "$display_str" $(( m_w - 4 ))
        padded="$REPLY"
        zcurses string modal_win "$padded"
      fi
      (( row++ ))
    done

    # Status count at bottom
    zcurses move modal_win $(( m_h - 2 )) 2
    zcurses attr modal_win dim white/black
    zcurses string modal_win "Model ${sel}/${total}  [Host: ${OLLAMA_HOST}]"

    zcurses refresh modal_win

    ch=""
    key=""
    mouse=""
    zcurses timeout modal_win -1
    zcurses input modal_win ch key mouse
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
      state_save_session
      break
    elif [[ "$cur_ch" == $'\x1b' || "$cur_ch" == "q" || "$cur_ch" == $'\x03' ]]; then
      break
    fi
  done

  zcurses delwin modal_win 2>/dev/null
}

# Modal 2: Edit System Prompt
modal_system_prompt() {
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
  (( m_h > SCREEN_H - 4 )) && m_h=$(( SCREEN_H - 4 ))
  (( m_w > SCREEN_W - 4 )) && m_w=$(( SCREEN_W - 4 ))

  local m_y=$(( (SCREEN_H - m_h) / 2 ))
  local m_x=$(( (SCREEN_W - m_w) / 2 ))

  zcurses addwin modal_win $m_h $m_w $m_y $m_x 2>/dev/null || return

  local ch="" key="" mouse="" cur_ch="" cur_key=""
  local row=2 i=1 p="" padded="" cur_preview=""

  while true; do
    _modal_frame modal_win "System Prompt Presets (↑/↓: Nav, Enter: Set, Esc: Cancel)" "magenta/black"

    row=2
    for (( i=1; i<=total; i++ )); do
      zcurses move modal_win $row 2
      p="${presets[i]}"
      zchat_pad_right "  $p" $(( m_w - 4 ))
      padded="$REPLY"
      if (( i == sel )); then
        zcurses attr modal_win reverse bold magenta/black
        zcurses string modal_win "$padded"
        zcurses attr modal_win -reverse default/default
      else
        zcurses attr modal_win white/black
        zcurses string modal_win "$padded"
      fi
      (( row++ ))
    done

    zcurses move modal_win $(( m_h - 3 )) 2
    zcurses attr modal_win dim white/black
    cur_preview="${SESSION_SYSTEM_PROMPT[1,$(( m_w - 14 ))]}"
    zcurses string modal_win "Active: \"${cur_preview}...\""

    zcurses refresh modal_win

    ch=""
    key=""
    mouse=""
    zcurses timeout modal_win -1
    zcurses input modal_win ch key mouse
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
      state_save_session
      break
    elif [[ "$cur_ch" == $'\x1b' || "$cur_ch" == "q" || "$cur_ch" == $'\x03' ]]; then
      break
    fi
  done

  zcurses delwin modal_win 2>/dev/null
}

# Modal 3: Help / Keybindings
modal_show_help() {
  local m_h=20
  local m_w=62
  (( m_h > SCREEN_H - 4 )) && m_h=$(( SCREEN_H - 4 ))
  (( m_w > SCREEN_W - 4 )) && m_w=$(( SCREEN_W - 4 ))

  local m_y=$(( (SCREEN_H - m_h) / 2 ))
  local m_x=$(( (SCREEN_W - m_w) / 2 ))

  zcurses addwin modal_win $m_h $m_w $m_y $m_x 2>/dev/null || return

  _modal_frame modal_win "Keyboard Shortcuts & Help (Press any key to close)" "yellow/black"

  local -a help_items=(
    "Enter         : Send message"
    "Shift/Alt+Enter: Insert a prompt newline"
    "Ctrl+R        : Toggle Reasoning expand/collapse"
    "Ctrl+N        : Start a new chat session"
    "Ctrl+O        : Open model picker (switch Ollama model)"
    "/host URL     : Change and save the Ollama URL"
    "/compact      : Create a conversation checkpoint"
    "/context      : Show the active context budget"
    "Ctrl+S        : Change system prompt preset"
    "Ctrl+C        : Cancel active streaming / Clear input"
    "Tab           : Switch focus between Chat and Sidebar"
    "PgUp / PgDn   : Scroll chat history"
    "Home / End    : Jump to start / end of chat"
    "Ctrl+U        : Clear input line"
    "Ctrl+W        : Delete previous word"
    "Up / Down     : Navigate input history (when input empty)"
    "Ctrl+Q / ^D   : Quit zchat.zsh"
  )

  local row=2
  local item=""
  for item in "${help_items[@]}"; do
    zcurses move modal_win $row 2
    zcurses attr modal_win white/black
    zcurses string modal_win "  $item"
    (( row++ ))
    (( row >= m_h - 1 )) && break
  done

  zcurses refresh modal_win

  local ch="" key="" mouse=""
  zcurses timeout modal_win -1
  zcurses input modal_win ch key mouse

  zcurses delwin modal_win 2>/dev/null
}
