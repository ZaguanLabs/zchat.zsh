# Chat-only inline command discovery, adapted from zcoder's command catalog.
# Matching is literal; completion only edits the prompt and never evaluates it.
typeset -ga COMMAND_TEXTS=() COMMAND_LABELS=() UI_SLASH_TEXTS=() UI_SLASH_LABELS=()
typeset -g UI_SLASH_BUFFER='' UI_SLASH_DISMISSED='' UI_SLASH_CACHE_KEY=''
typeset -gF UI_SLASH_ESCAPE_AT=0

commands_init() {
  COMMAND_TEXTS=(/model /host /new /copy /think /system /compact /context /sidebar /help /quit)
  COMMAND_LABELS=('Switch model' 'Change Ollama server' 'Start a new chat'
    'Copy transcript' 'Toggle reasoning' 'Change system prompt'
    'Compact conversation' 'Show context budget' 'Toggle sessions sidebar'
    'Show shortcuts' 'Quit zchat')
}

ui_slash_update() {
  emulate -L zsh
  UI_SLASH_ROWS=0
  if [[ "$INPUT_BUF" != "$UI_SLASH_BUFFER" ]]; then
    UI_SLASH_BUFFER=$INPUT_BUF; UI_SLASH_DISMISSED=''; UI_SLASH_CACHE_KEY=''
    UI_SLASH_SELECTED=1
  fi
  [[ "$FOCUS_PANE" == input && "$INPUT_BUF" == /* && "$INPUT_BUF" != *[[:space:]]* &&
     "$INPUT_BUF" != "$UI_SLASH_DISMISSED" ]] || return 0
  (( INPUT_POS == ${#INPUT_BUF} && ${#STREAM_PID} == 0 )) || return 0
  local cache_key="$INPUT_BUF"
  local -i i available=$(( SCREEN_H - TOP_H - FOOT_H - INPUT_VISIBLE_ROWS - 5 ))
  if [[ "$cache_key" != "$UI_SLASH_CACHE_KEY" ]]; then
    commands_init
    UI_SLASH_TEXTS=(); UI_SLASH_LABELS=(); UI_SLASH_SELECTED=1
    for (( i=1; i<=${#COMMAND_TEXTS}; i++ )); do
      [[ "${COMMAND_TEXTS[i]:l}" == "${INPUT_BUF:l}"* ]] || continue
      UI_SLASH_TEXTS+=("${COMMAND_TEXTS[i]}"); UI_SLASH_LABELS+=("${COMMAND_LABELS[i]}")
      [[ "${COMMAND_TEXTS[i]}" == "$INPUT_BUF" ]] && UI_SLASH_SELECTED=${#UI_SLASH_TEXTS}
    done
    UI_SLASH_CACHE_KEY=$cache_key
  fi
  (( ${#UI_SLASH_TEXTS} > 0 && available >= 2 )) || return 0
  UI_SLASH_ROWS=$(( ${#UI_SLASH_TEXTS} + 1 ))
  (( UI_SLASH_ROWS > 6 )) && UI_SLASH_ROWS=6
  (( UI_SLASH_ROWS > available )) && UI_SLASH_ROWS=$available
  return 0
}

ui_slash_input() {
  emulate -L zsh
  local ch="$1" key="$2" command_text=''
  (( UI_SLASH_ROWS > 0 && ${#STREAM_PID} == 0 && ! ${UI_MODAL_ACTIVE:-0} )) || return 1
  [[ "$FOCUS_PANE" == input ]] || return 1
  # Enhanced newline and structured paste events belong to the editor decoder.
  [[ "$key" == SENTER || "$key" == PASTE* ]] && return 1
  # Let the shared decoder distinguish paste/newline sequences from bare Esc.
  if [[ "$INPUT_TERM_STATE" == escape && "$INPUT_ESCAPE_BUF" == $'\e' && -z "$ch$key" ]] &&
     (( EPOCHREALTIME - UI_SLASH_ESCAPE_AT >= 0.05 )); then
    INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=''
    UI_SLASH_DISMISSED=$INPUT_BUF
    ui_input_changed
    return 0
  fi
  [[ "$INPUT_TERM_STATE" == normal ]] || return 1
  if [[ "$ch" == $'\e' ]]; then UI_SLASH_ESCAPE_AT=$EPOCHREALTIME; return 1; fi
  if [[ "$key" == UP ]]; then
    (( UI_SLASH_SELECTED-- ))
    (( UI_SLASH_SELECTED < 1 )) && UI_SLASH_SELECTED=${#UI_SLASH_TEXTS}
  elif [[ "$key" == DOWN ]]; then
    (( UI_SLASH_SELECTED++ ))
    (( UI_SLASH_SELECTED > ${#UI_SLASH_TEXTS} )) && UI_SLASH_SELECTED=1
  elif [[ "$key" == TAB || "$ch" == $'\t' || "$key" == ENTER || "$key" == PADENTER || "$ch" == $'\r' || "$ch" == $'\n' ]]; then
    command_text=${UI_SLASH_TEXTS[UI_SLASH_SELECTED]}
    # A fully typed command keeps the ordinary single-Enter dispatch behavior.
    [[ "$INPUT_BUF" == "$command_text" && "$key" != TAB && "$ch" != $'\t' ]] && return 1
    INPUT_BUF=$command_text; INPUT_POS=${#INPUT_BUF}; INPUT_GOAL_COL=-1
    UI_SLASH_BUFFER=$INPUT_BUF; UI_SLASH_DISMISSED=$INPUT_BUF
  else
    return 1
  fi
  ui_input_changed
  return 0
}

ui_slash_draw() {
  emulate -L zsh
  (( UI_SLASH_ROWS > 0 )) || return 0
  local -i capacity=$(( UI_SLASH_ROWS - 1 )) first=1 row i y width=$(( SCREEN_W - 4 ))
  local marker style
  (( UI_SLASH_SELECTED > capacity )) && first=$(( UI_SLASH_SELECTED - capacity + 1 ))
  local legend='↑/↓ Select  Tab Complete  Esc Close'
  (( width < ${#legend} )) && legend='↑/↓ Select  Tab  Esc'
  ui_draw_row input_win $(( INPUT_VISIBLE_ROWS + 1 )) 2 "$width" 'muted/editor' "$legend"
  for (( row=0; row<capacity; row++ )); do
    i=$(( first + row ))
    y=$(( INPUT_VISIBLE_ROWS + 2 + row ))
    marker='  '
    style='text/editor'
    if (( i == UI_SLASH_SELECTED )); then
      marker='› '
      style='bold text/selection'
      [[ $UI_COLOR_MODE == mono || $UI_COLOR_MODE == basic ]] && style='reverse bold text/editor'
      ui_fill input_win "$y" 2 1 "$width" "$style" ' '
    fi
    ui_draw_row input_win "$y" 2 "$width" "$style" "$marker${UI_SLASH_TEXTS[i]}  ${UI_SLASH_LABELS[i]}"
  done
}
