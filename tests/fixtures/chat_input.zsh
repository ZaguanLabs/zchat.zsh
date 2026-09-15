#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset root=$1 base=$2 backend=$3
source "$root/lib/draw.zsh"
ZCHAT_DRAW=$backend zchat_draw_load "$root" || exit 1
zmodload zsh/datetime zsh/files zsh/mapfile zsh/system zsh/terminfo zsh/zselect
for lib in util json input render ui; do source "$root/lib/$lib.zsh"; done
typeset ZCHAT_CONFIG_DIR=$base-config ZCHAT_NAME=zchat.zsh ZCHAT_VERSION=test
SESSION_MODEL=test OLLAMA_HOST=localhost CURRENT_SESSION_ID=test
MSG_ROLES=() MSG_CONTENTS=() MSG_THINKINGS=() SESSION_IDS=()
typeset STREAM_PID=''
command stty rows 24 cols 100 </dev/tty
trap 'fixture_result=$?; ui_end; print -rn -- "$fixture_result" >| "$base.exit"' EXIT
input_init
ui_init || exit 2
(( SIDE_W > 0 )) || exit 3
FOCUS_PANE=sidebar
ui_toggle_sidebar
(( SIDE_W == 0 )) && [[ $FOCUS_PANE == input ]] || exit 4
ui_toggle_sidebar
(( SIDE_W > 0 )) || exit 5
INPUT_BUF=/co; INPUT_POS=3
ui_input_changed
(( UI_SLASH_ROWS == 4 )) || exit 6
typeset -a geometry cell
zchat_draw position input_win geometry
(( geometry[3] + geometry[5] < SCREEN_H )) || exit 7
ui_slash_input '' DOWN
ui_slash_input $'\t' ''
[[ $INPUT_BUF == /compact && -z $INPUT_SUBMITTED ]] || exit 8
(( UI_SLASH_ROWS == 0 )) || exit 9
input_reset
ui_input_changed
mapfile[$base.ui]=1
# Reply to the native synchronized-output capability probe separately in other
# scenarios; this test isolates bracketed paste on both input implementations.
mapfile[$base.ready]=1
typeset ch='' key='' mouse=''
typeset -i pasted=0
typeset -F deadline=$(( EPOCHREALTIME + 8 ))
while (( EPOCHREALTIME < deadline )); do
  zchat_draw timeout input_win 50
  terminal_read_event input_win ch key mouse
  if input_decode_terminal_event "$ch" "$key"; then
    if [[ $INPUT_EVENT_ACTION == paste ]]; then
      input_insert "$INPUT_EVENT_TEXT"
      (( pasted++ ))
      break
    fi
  elif [[ -n $ch$key ]]; then
    exit 10
  fi
done
(( pasted == 1 )) || exit 11
mapfile[$base.text]=$INPUT_BUF
mapfile[$base.sync]="$TERMINAL_SYNC_STATE:$TERMINAL_NATIVE_SYNC"
ui_input_changed
ui_copy_view || exit 15
[[ $INPUT_BUF == $'first\nsecond    e\u0301👩‍💻' ]] || exit 16
(( UI_ACTIVE )) || exit 17
mapfile[$base.copy]=1
ui_end
(( TERMINAL_NATIVE_PASTE == 0 && TERMINAL_FRAME_ACTIVE == 0 )) || exit 12
ui_init || exit 13
(( UI_SIDEBAR_HIDDEN == 0 )) || exit 14
