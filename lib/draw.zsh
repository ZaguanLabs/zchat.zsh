# Select one drawing module before the application starts a terminal session.
# Never replace an already loaded module or modify the system installation.
typeset -g ZCHAT_DRAW_BACKEND=unloaded
typeset -g ZCHAT_DRAW_MODULE=zsh/curses ZCHAT_DRAW_COMMAND=zcurses
typeset -ga ZCHAT_DRAW_FEATURES=()
typeset -gi ZCHAT_DRAW_COLORS=0

zchat_draw_load() {
  emulate -L zsh
  local root="${1:-$ZCHAT_DIR}/vendor/zdraw/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  # Retain the old environment override for existing launchers.
  local policy=${ZCHAT_DRAW:-${ZCHAT_CURSES:-auto}}
  case "$policy" in
    auto|stock) ;;
    *) print -u2 -r -- 'Error: ZCHAT_DRAW expects auto or stock'; return 1 ;;
  esac
  if zmodload -e zsh/curses; then
    ZCHAT_DRAW_MODULE=zsh/curses; ZCHAT_DRAW_COMMAND=zcurses
    [[ $ZCHAT_DRAW_BACKEND == unloaded ]] && ZCHAT_DRAW_BACKEND=preloaded
    return 0
  fi
  if zmodload -e zdraw; then
    ZCHAT_DRAW_MODULE=zdraw; ZCHAT_DRAW_COMMAND=zdraw
    [[ $ZCHAT_DRAW_BACKEND == unloaded ]] && ZCHAT_DRAW_BACKEND=preloaded
    return 0
  fi
  # The build stamp is host-specific data, never sourced as shell code.
  if [[ $policy == auto && -r $root/zchat-abi &&
        -f $root/modules/zdraw.so && $(<"$root/zchat-abi") == "$signature" ]]; then
    local -a module_path=("$root/modules" "${module_path[@]}")
    if zmodload zdraw 2>/dev/null; then
      ZCHAT_DRAW_MODULE=zdraw; ZCHAT_DRAW_COMMAND=zdraw
      ZCHAT_DRAW_BACKEND=bundled
      return 0
    fi
    module_path=("${module_path[@]:1}")
  fi
  zmodload zsh/curses || return 1
  ZCHAT_DRAW_MODULE=zsh/curses; ZCHAT_DRAW_COMMAND=zcurses
  ZCHAT_DRAW_BACKEND=stock
}

# The application shares the inherited command API, not either module's
# namespace. A builtin dispatch leaves stock zcurses and zdraw independent.
zchat_draw() { builtin "$ZCHAT_DRAW_COMMAND" "$@"; }

# Refresh after init: color counts describe the current terminal session.
zchat_draw_capabilities() {
  emulate -L zsh
  local features_name="${ZCHAT_DRAW_COMMAND}_features"
  local colors_name="${(U)ZCHAT_DRAW_COMMAND}_COLORS"
  ZCHAT_DRAW_FEATURES=()
  if zmodload -F -e "$ZCHAT_DRAW_MODULE" "+p:$features_name"; then
    ZCHAT_DRAW_FEATURES=("${(@P)features_name}")
  fi
  ZCHAT_DRAW_COLORS=${${(P)colors_name}:-0}
  return 0
}

# Headless-safe feature discovery for editor and terminal capability gates.
zchat_draw_features() {
  emulate -L zsh
  local features_name="${ZCHAT_DRAW_COMMAND}_features"
  reply=()
  zmodload -F -e "$ZCHAT_DRAW_MODULE" "+p:$features_name" || return 1
  reply=("${(@P)features_name}")
}
