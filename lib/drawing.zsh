# Application styles and bounded row drawing; curses retains screen ownership.
typeset -g UI_COLOR_MODE=basic UI_BORDER_MODE=plain
typeset -gi UI_STYLED_SPANS=0 UI_WIDE_SPANS=0 UI_CLIPPED_SPANS=0 UI_SPAN_FALLBACKS=0
typeset -gA UI_COLOR_INFO=() UI_THEME_COLORS=() UI_STYLE_CACHE=()
typeset -gA UI_COLOR_ROLES=(white text black surface cyan accent green success
  yellow warning red error magenta syntax blue info)

ui_theme_palette() {
  # Charcoal and sage: a warmer, quieter identity for conversation.
  case "$1" in
    rgb) UI_THEME_COLORS=(surface '#232722' text '#deddd5' accent '#a0b994'
      success '#bdc29a' warning '#d2b48c' error '#ca9290' syntax '#b5a1b8'
      info '#9bb8b2' muted '#939b90' border '#4b5749') ;;
    256) UI_THEME_COLORS=(surface 235 text 252 accent 108 success 144 warning 180
      error 174 syntax 139 info 109 muted 245 border 239) ;;
    *) UI_THEME_COLORS=(surface black text white accent green success green
      warning yellow error red syntax magenta info cyan muted white border white) ;;
  esac
  UI_STYLE_CACHE=()
}

# Existing transcript style records stay terminal-independent. Resolve their
# color names (and new semantic roles) only at the drawing boundary.
ui_style() {
  local style="$1" token fg bg
  if (( ${+UI_STYLE_CACHE[$style]} )); then
    REPLY="${UI_STYLE_CACHE[$style]}"
    return 0
  fi
  local -a result=()
  for token in ${=style}; do
    if [[ "$token" == */* ]]; then
      [[ "$UI_COLOR_MODE" == mono ]] && continue
      fg=${token%%/*}; bg=${token#*/}
      fg=${UI_COLOR_ROLES[$fg]:-$fg}; bg=${UI_COLOR_ROLES[$bg]:-$bg}
      [[ "$fg" == default ]] && fg=text
      [[ "$bg" == default ]] && bg=surface
      token="${UI_THEME_COLORS[$fg]:-$fg}/${UI_THEME_COLORS[$bg]:-$bg}"
    fi
    result+=("$token")
  done
  REPLY="${(j: :)result}"
  # An empty style needs no cache entry (Zsh associations require nonempty keys).
  [[ -n "$style" ]] && UI_STYLE_CACHE[$style]="$REPLY"
  return 0
}

ui_attr() {
  local window="$1" REPLY
  shift
  ui_style "$*"
  [[ -n "$REPLY" ]] || return 0
  zchat_draw attr "$window" ${=REPLY}
}

ui_theme_init() {
  emulate -L zsh
  UI_COLOR_INFO=(); UI_STYLE_CACHE=(); UI_SPAN_FALLBACKS=0
  UI_STYLED_SPANS=0; UI_WIDE_SPANS=0; UI_CLIPPED_SPANS=0; UI_BORDER_MODE=plain
  UI_COLOR_MODE=basic
  zchat_draw_capabilities
  if (( ${#ZCHAT_DRAW_FEATURES} )); then
    if [[ ${ZCHAT_SPANS:-true} != false ]]; then
      (( ${ZCHAT_DRAW_FEATURES[(Ie)styled_spans]} )) && UI_STYLED_SPANS=1
      (( ${ZCHAT_DRAW_FEATURES[(Ie)wide_spans]} )) && UI_WIDE_SPANS=1
      (( ${ZCHAT_DRAW_FEATURES[(Ie)clipped_spans]} )) && UI_CLIPPED_SPANS=1
    fi
    if [[ ${ZCHAT_BORDERS:-auto} != plain && -o multibyte ]] &&
       (( ${ZCHAT_DRAW_FEATURES[(Ie)wide_borders]} )); then
      UI_BORDER_MODE=rounded
    fi
    if (( ${ZCHAT_DRAW_FEATURES[(Ie)colorinfo]} )); then
      zchat_draw colorinfo UI_COLOR_INFO 2>/dev/null || UI_COLOR_INFO=()
    fi
  fi
  if [[ ${ZCHAT_COLOR:-auto} == mono ]] ||
     [[ ${UI_COLOR_INFO[has_colors]:-1} == 0 || ${UI_COLOR_INFO[color_started]:-1} == 0 ]] ||
     (( ${ZCHAT_DRAW_COLORS:-0} < 8 )); then
    UI_COLOR_MODE=mono
  elif [[ ${ZCHAT_COLOR:-auto} != basic ]]; then
    if [[ ${UI_COLOR_INFO[truecolor_supported]:-0} == 1 ]] &&
       zchat_draw truecolor on 2>/dev/null; then
      UI_COLOR_MODE=rgb
    # Direct-color entries interpret numeric values differently from the
    # indexed cube. Never apply our 256-color palette to those descriptions.
    elif (( ${ZCHAT_DRAW_COLORS:-0} == 256 )); then
      UI_COLOR_MODE=256
    fi
  fi
  ui_theme_palette "$UI_COLOR_MODE"
  # Reserve the finite palette before painting. Failed allocations do not
  # recycle retained pairs; degrade before any application cells are drawn.
  local role
  if [[ "$UI_COLOR_MODE" != mono ]]; then
    for role in text accent success warning error syntax info muted border surface; do
      if ! ui_attr stdscr "$role/surface" 2>/dev/null; then
        UI_COLOR_MODE=basic; ui_theme_palette basic
        if ! ui_attr stdscr text/surface 2>/dev/null; then UI_COLOR_MODE=mono; UI_STYLE_CACHE=(); fi
        break
      fi
    done
  fi
  ui_attr stdscr -bold -dim -reverse -underline text/surface 2>/dev/null
  return 0
}

ui_window_background() {
  [[ "$UI_COLOR_MODE" == mono ]] && return 0
  local REPLY
  ui_style text/surface
  zchat_draw bg "$1" "$REPLY" 2>/dev/null
}

ui_border() {
  if [[ "$UI_BORDER_MODE" == rounded ]]; then
    zchat_draw border "$1" '│' '│' '─' '─' '╭' '╮' '╰' '╯' 2>/dev/null && return 0
  fi
  zchat_draw border "$1"
}

# Draw a prefix across all styles within one cell budget. Callers clear the
# window first and supply padding spans when blank cells need explicit styles.
# A rejected native clip is repainted using the Zsh clipper and legacy calls.
ui_draw_row() {
  local window="$1" row="$2" col="$3" style text REPLY
  local -i width=$4 remaining=$4
  shift 4
  (( width > 0 )) || return 0
  # Sanitize before either native batching or the stock drawing path. Raw
  # transcript text never reaches a terminal command, even after clipping fails.
  local -a safe=()
  for style text in "$@"; do
    zchat_terminal_safe "$text"
    safe+=("$style" "$REPLY")
  done
  set -- "${safe[@]}"
  local -a batch=() clipped=()
  local -i can_batch=$UI_STYLED_SPANS
  if (( can_batch )); then
    for style text in "$@"; do
      if (( ! UI_WIDE_SPANS )) && [[ "$text" == *[^\ -\~]* ]]; then can_batch=0; break; fi
    done
  fi
  if (( can_batch && UI_CLIPPED_SPANS )); then
    for style text in "$@"; do
      ui_style "$style"
      batch+=("${REPLY// /,}" "$text")
    done
    zchat_draw spansclip "$window" "$row" "$col" "$width" "${batch[@]}" 2>/dev/null && return 0
    (( UI_SPAN_FALLBACKS++ ))
    can_batch=0
  fi
  for style text in "$@"; do
    zchat_clip "$text" "$remaining"
    clipped+=("$style" "$REPLY")
    (( remaining -= ${(m)#REPLY} ))
    [[ "$REPLY" == "$text" ]] || break
  done
  if (( can_batch )); then
    for style text in "${clipped[@]}"; do
      ui_style "$style"
      batch+=("${REPLY// /,}" "$text")
    done
    zchat_draw spans "$window" "$row" "$col" "${batch[@]}" 2>/dev/null && return 0
    (( UI_SPAN_FALLBACKS++ ))
  fi
  zchat_draw move "$window" "$row" "$col"
  for style text in "${clipped[@]}"; do
    ui_attr "$window" -bold -dim -reverse -underline default/default
    ui_attr "$window" ${=style}
    zchat_draw string "$window" "$text"
  done
  return 0
}

ui_theme_palette basic
