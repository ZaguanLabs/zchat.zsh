# lib/util.zsh - Native Zsh utility helpers

typeset -ga ZCHAT_WRAPPED=()

# Make arbitrary text safe to hand to curses or a terminal. Raw conversation
# text remains untouched everywhere else; only the display boundary replaces
# control characters that can move the cursor, emit OSC commands, ring the
# bell, or otherwise alter terminal state. Newlines are optionally retained for
# the plain-text transcript view, while tabs become spaces in both modes.
zchat_terminal_safe() {
  local input="$1"
  local -i preserve_newlines="${2:-0}"
  local output="" ch=""

  if [[ "$input" != *[$'\x01'-$'\x1f'$'\x7f'$'\u0080'-$'\u009f']* ]]; then
    REPLY="$input"
    return 0
  fi

  for ch in ${(s::)input}; do
    case "$ch" in
      $'\n') (( preserve_newlines )) && output+=$'\n' || output+=' ' ;;
      $'\t') output+='    ' ;;
      $'\e') output+='␛' ;;
      $'\a') output+='␇' ;;
      $'\r') output+='␍' ;;
      $'\b') output+='␈' ;;
      [$'\x01'-$'\x1f'$'\x7f'$'\u0080'-$'\u009f']) output+='�' ;;
      *) output+="$ch" ;;
    esac
  done
  REPLY="$output"
}

# Centralized curses output boundary. Keeping sanitization here prevents a new
# dynamic label or pane from accidentally writing active terminal controls.
zchat_curses_string() {
  local win="$1" value="$2"
  zchat_terminal_safe "$value" 0
  zcurses string "$win" "$REPLY"
}

# Repeat a character without spawning printf in a command substitution.
# Result is returned in REPLY.
zchat_repeat() {
  local char="$1"
  local count="${2:-0}"
  local empty=""
  (( count < 1 )) && { REPLY=""; return 0; }
  REPLY="${(pl:$count::$char:)empty}"
}

# Right-pad text to a fixed character width. Result is returned in REPLY.
zchat_pad_right() {
  local value="$1"
  local width="${2:-0}"
  REPLY="${(r:$width:)value}"
}

# Word-wrap one logical line using Zsh character indexing. Long words are
# split at the requested width. Results are returned in ZCHAT_WRAPPED.
zchat_wrap() {
  local rest="$1"
  local width="${2:-1}"
  local probe="" line="" prefix=""
  local cut=0

  ZCHAT_WRAPPED=()
  (( width < 1 )) && width=1

  if [[ -z "$rest" ]]; then
    ZCHAT_WRAPPED+=("")
    return 0
  fi

  while (( ${#rest} > width )); do
    probe="${rest[1,$width]}"
    prefix="${probe%[[:space:]]*}"

    if [[ "${rest[$(( width + 1 ))]}" == [[:space:]] ]]; then
      line="$probe"
      rest="${rest[$(( width + 2 )),-1]}"
      rest="${rest##[[:space:]]#}"
    elif [[ "$prefix" != "$probe" && -n "$prefix" ]]; then
      cut=${#prefix}
      line="${rest[1,$cut]}"
      rest="${rest[$(( cut + 1 )),-1]}"
      rest="${rest##[[:space:]]#}"
    else
      line="$probe"
      rest="${rest[$(( width + 1 )),-1]}"
    fi

    ZCHAT_WRAPPED+=("$line")
  done

  ZCHAT_WRAPPED+=("$rest")
}

# Query the caller's umask once per process. Every zchat writer restores the
# umask it sets, so the cached value stays valid and later writers avoid one
# $(umask) subshell fork per save. Result is returned in REPLY.
typeset -g ZCHAT_UMASK=""
zchat_umask() {
  [[ -n "$ZCHAT_UMASK" ]] || ZCHAT_UMASK="$(umask)"
  REPLY="$ZCHAT_UMASK"
}

# Write the complete byte string to an already-open descriptor. syswrite may
# legally report a short successful write, including for TCP sockets, so callers
# must advance through the unwritten suffix until every byte is committed.
zchat_write_all() {
  setopt localoptions nomultibyte
  local fd="$1" remaining="$2"
  local -i written=0 total=0
  REPLY=0

  while (( ${#remaining} > 0 )); do
    written=0
    syswrite -c written -o "$fd" "$remaining" 2>/dev/null || {
      REPLY=$total
      return 1
    }
    (( written > 0 )) || {
      REPLY=$total
      return 1
    }
    (( total += written ))
    remaining="${remaining[$(( written + 1 )),-1]}"
  done
  REPLY=$total
}

# Atomically replace one regular file using checked native descriptor I/O. The
# same-directory temporary file makes rename atomic and prevents leaf-symlink
# writes. Parent directories must already exist and must not be symlinks.
zchat_atomic_write() {
  setopt localoptions nomultibyte
  local target="$1" value="$2" mode="${3:-0600}"
  local parent="${target:h}" tmp="${target}.tmp.${sysparams[pid]:-$$}.${RANDOM}"
  local -i fd=-1 written=0 expected=${#value} write_status=0

  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  sysopen -w -m "$mode" -o creat,excl,nofollow,cloexec -u fd "$tmp" 2>/dev/null || return 1
  {
    if (( expected > 0 )); then
      zchat_write_all "$fd" "$value" || write_status=$?
      written=$REPLY
    fi
  } always {
    (( fd >= 0 )) && exec {fd}>&- 2>/dev/null
  }
  if (( write_status != 0 || written != expected )); then
    zf_rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
  zf_mv -f -- "$tmp" "$target" 2>/dev/null || {
    zf_rm -f -- "$tmp" 2>/dev/null
    return 1
  }
  zf_chmod "$mode" "$target" 2>/dev/null || return 1
}

# Read a bounded regular file through a native descriptor. Leaf symlinks and
# special files are rejected. Result is returned in REPLY.
zchat_read_file() {
  setopt localoptions nomultibyte
  local path="$1" limit="${2:-16777216}" chunk="" output=""
  local -i fd=-1 read_status=0
  REPLY=""
  [[ -f "$path" && ! -L "$path" ]] || return 1
  sysopen -r -o nofollow,cloexec -u fd "$path" 2>/dev/null || return 1
  {
    while true; do
      sysread -i "$fd" -s 65536 chunk 2>/dev/null
      read_status=$?
      (( read_status == 0 )) || break
      output+="$chunk"
      (( ${#output} <= limit )) || { read_status=6; break; }
    done
  } always {
    (( fd >= 0 )) && exec {fd}<&- 2>/dev/null
  }
  (( read_status == 5 )) || return 1
  REPLY="$output"
}

# Current local time without invoking date(1). Result is returned in REPLY.
zchat_time() {
  strftime -s REPLY '%H:%M'
}

# Bound model-generated checkpoints without an external text utility.
zchat_truncate() {
  local value="$1" limit="${2:-8192}"
  if (( ${#value} > limit )); then
    REPLY="${value[1,$limit]}"$'\n'"[checkpoint truncated at ${limit} characters]"
  else
    REPLY="$value"
  fi
}
