zmodload zsh/zpty zsh/zselect || exit 1
typeset drawing_available
drawing_available=$(ZCHAT_DRAW=auto zsh -dfc 'source "$1/lib/draw.zsh"; zchat_draw_load "$1"; print -r -- "$ZCHAT_DRAW_BACKEND"' zchat-test "$PROJECT_DIR")
# The fixture has no Ollama dependency and compares actual curses cell contents.
drawing_wait() {
  local -F deadline=$(( EPOCHREALTIME + 15 ))
  local chunk=''
  local -i sent=0
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r drawing-ui chunk 2>/dev/null; do drawing_output+="$chunk"; done
    if [[ -f $drawing_base.ready ]] && (( ! sent )); then
      zpty -w -n drawing-ui x
      sent=1
    fi
    if [[ -f $drawing_base.exit ]]; then
      [[ ${mapfile[$drawing_base.done]:-} == 1 ]]
      return $?
    fi
    zselect -t 1
  done
  return 1
}
drawing_run() {
  trap - EXIT INT TERM
  export TERM=$drawing_term ZCHAT_COLOR=$drawing_policy ZCHAT_SPANS=true ZCHAT_BORDERS=auto
  exec zsh -df "$TEST_DIR/fixtures/drawing_ui.zsh" "$PROJECT_DIR" "$drawing_base" "$drawing_backend"
}
typeset -a drawing_backends=(stock)
[[ $drawing_available == bundled ]] && drawing_backends+=(auto)
typeset -a drawing_scenarios=(auto xterm-256color mono xterm-256color basic xterm-256color auto vt100)
if (( ${+commands[infocmp]} )) && command infocmp xterm-direct >/dev/null 2>&1; then
  drawing_scenarios+=(auto xterm-direct)
fi
typeset drawing_backend drawing_policy drawing_term drawing_base drawing_output
for drawing_backend in "${drawing_backends[@]}"; do
  for drawing_policy drawing_term in "${drawing_scenarios[@]}"; do
    drawing_base="$TEST_STATE_DIR/drawing-$drawing_backend-$drawing_policy-$drawing_term"
    drawing_output=''
    zpty -b drawing-ui drawing_run
    drawing_wait
    assert_status_ok "$drawing_backend/$drawing_policy draws real themed windows and restores curses" $?
    assert_eq 1 "${mapfile[$drawing_base.equivalent]:-}" "$drawing_backend/$drawing_policy row cells match the legacy renderer"
    assert_eq 1 "${mapfile[$drawing_base.clipped_equivalent]:-}" "$drawing_backend/$drawing_policy clipped rows preserve styles, Unicode, padding and borders"
    assert_eq 1 "${mapfile[$drawing_base.bounded_fallback]:-}" "$drawing_backend/$drawing_policy rejected spans stay inside the row budget"
    drawing_expected_clip=0
    [[ $drawing_backend == auto ]] && drawing_expected_clip=1
    assert_eq "$drawing_expected_clip" "${mapfile[$drawing_base.clipping]:-}" "$drawing_backend/$drawing_policy discovers native row clipping"
    assert_eq 1 "${mapfile[$drawing_base.spans_disabled]:-}" "$drawing_backend/$drawing_policy respects the spans opt-out for native clipping"
    [[ $drawing_backend == auto ]] && assert_eq 1 "${mapfile[$drawing_base.fallback]:-}" 'a rejected combining-mark span falls back without losing text'
    drawing_expected=256
    [[ $drawing_policy == mono || $drawing_term == vt100 ]] && drawing_expected=mono
    [[ $drawing_policy == basic ]] && drawing_expected=basic
    if [[ $drawing_term == xterm-direct ]]; then
      drawing_expected=basic
      [[ ${mapfile[$drawing_base.rgb]:-} == 1 ]] && drawing_expected=rgb
    fi
    assert_contains "${mapfile[$drawing_base.mode]:-}" "$drawing_expected:" "$drawing_backend/$drawing_policy selects its requested palette"
    assert_not_contains "$drawing_output" 'spans:' 'batch rejection diagnostics never leak onto the terminal'
    assert_not_contains "$drawing_output" 'spansclip:' 'clipping rejection diagnostics never leak onto the terminal'
    assert_eq 1 "${mapfile[$drawing_base.safe]:-}" "$drawing_backend/$drawing_policy sanitizes text before drawing"
    assert_eq 1 "${mapfile[$drawing_base.modal]:-}" "$drawing_backend/$drawing_policy clips modal titles and closes overlays on resize"
    assert_eq 1 "${mapfile[$drawing_base.resize]:-}" "$drawing_backend/$drawing_policy resizes narrow, tiny and restored windows"
    assert_eq 0 "${mapfile[$drawing_base.exit]:-}" "$drawing_backend/$drawing_policy exits cleanly"
    zpty -d drawing-ui
  done
done
unfunction drawing_wait drawing_run
