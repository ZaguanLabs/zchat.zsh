#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset -g fixture_root=$1 fixture_base=$2 fixture_backend=$3
source "$fixture_root/lib/draw.zsh"
ZCHAT_DRAW=$fixture_backend zchat_draw_load "$fixture_root" || exit 1
if [[ $fixture_backend == auto ]]; then
  [[ $ZCHAT_DRAW_COMMAND == zdraw ]] || exit 28
  zmodload -e zdraw || exit 29
  zmodload -e zsh/curses && exit 30
else
  [[ $ZCHAT_DRAW_COMMAND == zcurses ]] || exit 31
  zmodload -e zdraw && exit 32
fi
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
for fixture_lib in util json render input ui modal; do
  source "$fixture_root/lib/$fixture_lib.zsh"
done
typeset -g ZCHAT_NAME=zchat.zsh ZCHAT_VERSION=preview SESSION_MODEL=gemma4:12b
typeset -g OLLAMA_HOST=localhost:11434 CURRENT_SESSION_ID=preview
typeset -a SESSION_IDS=(preview earlier) SESSION_TITLES=('A quiet conversation' 'Weekend plans')
typeset -a MSG_ROLES=(user assistant) MSG_CONTENTS=(
  'Why does the sky turn pink at sunset?'
  $'Sunlight travels through more air at sunset. Blue light scatters away, leaving warmer colors.\n\n**Try this:** watch the sky just after the sun dips below the horizon.\n\n• Look for soft pink clouds.\n• Notice how the colors change.\n\n日本語も表示できます。'
) MSG_THINKINGS=('' '') MSG_TIMES=('18:42' '18:42') MSG_MODELS=('' gemma4:12b) MSG_THINKING_EXPANDED=(0 0)
INPUT_BUF='Does the same thing happen at sunrise?'; INPUT_POS=${#INPUT_BUF}
command stty rows 30 cols 110 </dev/tty || exit 1
trap 'fixture_result=$?; ui_end; print -rn -- "$fixture_result" >| "$fixture_base.exit"' EXIT
ui_init || exit 1
mapfile[$fixture_base.mode]="$UI_COLOR_MODE:$UI_BORDER_MODE:$UI_STYLED_SPANS"
mapfile[$fixture_base.rgb]="${UI_COLOR_INFO[truecolor_supported]:-0}"
mapfile[$fixture_base.clipping]="$UI_CLIPPED_SPANS"
ZCHAT_SPANS=false ui_theme_init
(( UI_STYLED_SPANS == 0 && UI_CLIPPED_SPANS == 0 )) || exit 13
mapfile[$fixture_base.spans_disabled]=1
ui_theme_init
typeset -i row col
typeset -a cell before after
typeset -a fixture_spans=('bold cyan/black' 'const ' 'magenta/black' 'value ' 'white/black' '= ' 'yellow/black' '"hello"' 'white/black' '        ')
zchat_draw addwin sample 3 50 0 0 || exit 1
ui_window_background sample
UI_STYLED_SPANS=0
ui_draw_row sample 1 1 48 "${fixture_spans[@]}"
for ((col=1; col<28; col++)); do
  zchat_draw move sample 1 $col
  zchat_draw querychar sample cell || exit 1
  before+=("${(j: :)cell}")
done
zchat_draw clear sample
[[ $fixture_backend == auto ]] && UI_STYLED_SPANS=1
ui_draw_row sample 1 1 48 "${fixture_spans[@]}"
for ((col=1; col<28; col++)); do
  zchat_draw move sample 1 $col
  zchat_draw querychar sample cell || exit 1
  after+=("${(j: :)cell}")
done
[[ "${(j:|:)before}" == "${(j:|:)after}" ]] || exit 2
mapfile[$fixture_base.equivalent]=1
if [[ $fixture_backend == auto ]]; then
  # A syntax boundary can leave a combining mark at the start of a span.
  # The batch must reject it; the existing renderer still displays the row.
  ui_draw_row sample 1 1 48 'white/black' e 'white/black' $'\u0301' 'green/black' Z
  (( UI_SPAN_FALLBACKS == 1 )) || exit 3
  zchat_draw move sample 1 1
  zchat_draw querychar sample cell || exit 1
  [[ $cell[1] == e ]] || exit 4
  zchat_draw move sample 1 2
  zchat_draw querychar sample cell || exit 1
  [[ $cell[1] == Z ]] || exit 5
  mapfile[$fixture_base.fallback]=1
fi
# Exercise untrimmed rows under native clipping, old span batching, and stock
# drawing. Include both border cells in the comparison to catch any overflow.
fixture_compare_clipped() {
  local -i budget=$1 mode col clip_calls=0
  shift
  local -a modes=(0) expected=() actual=() cursor_before cursor_after
  [[ $fixture_backend == auto ]] && modes+=(1 2)
  local -i UI_STYLED_SPANS UI_CLIPPED_SPANS
  for mode in $modes; do
    UI_STYLED_SPANS=$(( mode > 0 )); UI_CLIPPED_SPANS=$(( mode == 2 ))
    zchat_draw clear sample
    ui_attr sample -bold -dim -reverse -underline text/surface
    zchat_draw move sample 1 0; zchat_draw string sample '|'
    zchat_draw move sample 1 8; zchat_draw string sample '|'
    zchat_draw position sample cursor_before
    clip_calls=0
    ui_draw_row sample 1 1 "$budget" "$@"
    zchat_draw position sample cursor_after
    if (( mode == 2 && budget > 0 )); then
      (( clip_calls == 0 )) || return 7
      [[ "$cursor_before" == "$cursor_after" ]] || return 8
    fi
    actual=()
    for (( col=0; col<=8; col++ )); do
      zchat_draw move sample 1 $col
      zchat_draw querychar sample cell || return 1
      actual+=("${(j: :)cell}")
      if (( col == 0 || col == 8 )); then [[ $cell[1] == '|' ]] || return 9; fi
    done
    if (( mode == 0 )); then
      expected=("${actual[@]}")
    else
      [[ "${(j:|:)expected}" == "${(j:|:)actual}" ]] || return 10
    fi
  done
}
functions[fixture_original_clip]="${functions[zchat_clip]}"
zchat_clip() { (( clip_calls++ )); fixture_original_clip "$@"; }
for fixture_budget in 0 1 2 3 4 7; do
  fixture_compare_clipped "$fixture_budget" 'bold cyan/black' abc 'yellow/black' 'defghijk' || exit $?
  fixture_compare_clipped "$fixture_budget" 'bold cyan/black' $'e\u0301' 'green/black' 界 'yellow/black' 'Z      ' || exit $?
  fixture_compare_clipped "$fixture_budget" 'reverse bold cyan/black' 'X       ' || exit $?
done
functions[zchat_clip]="${functions[fixture_original_clip]}"
unfunction fixture_original_clip fixture_compare_clipped
mapfile[$fixture_base.clipped_equivalent]=1
# A rejected batch must still respect its row budget when falling back.
zchat_draw clear sample
zchat_draw move sample 1 2; zchat_draw string sample '|'
ui_draw_row sample 1 1 1 'white/black' e 'white/black' $'\u0301' 'green/black' Z
zchat_draw move sample 1 1; zchat_draw querychar sample cell
[[ $cell[1] == e ]] || exit 11
zchat_draw move sample 1 2; zchat_draw querychar sample cell
[[ $cell[1] == '|' ]] || exit 12
mapfile[$fixture_base.bounded_fallback]=1
# Untrusted content must stay visible text on both paths, including tabs and ESC.
ui_draw_row sample 1 1 7 'white/black' $'A\e[2JB'
zchat_draw move sample 1 1; zchat_draw querychar sample cell
[[ $cell[1] == A ]] || exit 14
zchat_draw move sample 1 2; zchat_draw querychar sample cell
[[ $cell[1] == '␛' ]] || exit 15
mapfile[$fixture_base.safe]=1
zchat_draw delwin sample
render_invalidate
ui_refresh_all 0
# Export the actual curses cells, including resolved pair spelling, for visual QA.
typeset window out='' ch pair x y
typeset -a geometry
for window in top_win side_win chat_win input_win foot_win; do
  zchat_draw position "$window" geometry || exit 1
  for ((row=0; row<geometry[5]; row++)); do
    for ((col=0; col<geometry[6]; col++)); do
      zchat_draw move "$window" $row $col
      zchat_draw querychar "$window" cell || exit 1
      x=$(( geometry[4]+col )); y=$(( geometry[3]+row ))
      out+="$x"$'\t'"$y"$'\t'"$cell[2]"$'\t'"$cell[1]"$'\n'
    done
  done
done
mapfile[$fixture_base.cells]="$out"
# A long overlay title must not overwrite its right border, and overlay input
# must yield when the terminal changes size.
zchat_draw addwin modal_win 10 36 4 4 || exit 24
_modal_frame modal_win Short
zchat_draw move modal_win 0 35; zchat_draw querychar modal_win cell
typeset corner=$cell[1]
_modal_frame modal_win 'A very long model picker title that needs clipping'
zchat_draw move modal_win 0 35; zchat_draw querychar modal_win cell
[[ $cell[1] == $corner ]] || exit 25
command stty rows 18 cols 60 </dev/tty || exit 26
UI_NEXT_RESIZE_CHECK=0
ch=''; key=''; mouse=''
_modal_input
[[ $ch == $'\e' && $SCREEN_W == 60 ]] || exit 27
zchat_draw delwin modal_win
mapfile[$fixture_base.modal]=1
# Resize through both implementations, including a terminal too small for panes.
for fixture_size in '18 60' '6 20' '30 110'; do
  command stty rows ${${=fixture_size}[1]} cols ${${=fixture_size}[2]} </dev/tty || exit 16
  UI_NEXT_RESIZE_CHECK=0
  ui_poll_resize
  [[ "$SCREEN_H $SCREEN_W" == "$fixture_size" ]] || exit 17
  if (( SCREEN_W < 32 )); then
    (( UI_SMALL_SCREEN )) && [[ $UI_INPUT_WINDOW == stdscr ]] || exit 18
  else
    (( ! UI_SMALL_SCREEN )) || exit 19
    zchat_draw position input_win geometry || exit 20
    (( geometry[3] + geometry[5] <= SCREEN_H )) || exit 21
  fi
done
mapfile[$fixture_base.resize]=1
# Read a real key after reconstruction, and restore curses once more as /copy does.
mapfile[$fixture_base.ready]=1
typeset -F input_deadline=$(( EPOCHREALTIME + 5 ))
while (( EPOCHREALTIME < input_deadline )); do
  ch=''; key=''
  zchat_draw timeout input_win 50
  terminal_read_event input_win ch key mouse
  [[ $ch == x ]] && break
done
[[ $ch == x ]] || exit 22
ui_end
ui_init || exit 23
ui_end
mapfile[$fixture_base.done]=1
