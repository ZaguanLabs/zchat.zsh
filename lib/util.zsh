# lib/util.zsh - Native Zsh utility helpers

typeset -ga ZCHAT_WRAPPED=() ZCHAT_WRAPPED_LENGTHS=()

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
  local value_safe="$REPLY"
  local -a position=()
  if zchat_draw position "$win" position 2>/dev/null && (( ${#position} == 6 )); then
    # Leave the right border intact; the footer has no border.
    local -i budget=$(( position[6] - position[2] - 1 ))
    # position reports cursor y/x first, then window origin y/x and size.
    [[ "$win" == foot_win ]] && (( budget++ ))
    (( budget > 0 )) || return 0
    zchat_clip "$value_safe" "$budget"
    value_safe="$REPLY"
  fi
  zchat_draw string "$win" "$value_safe"
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

# Clip to terminal cells without separating a base from its combining marks.
# REPLY retains original text; callers which require padding add it separately.
zchat_clip() {
  local value="$1" ch=""
  local -i width=${2:-0} cells=0 size=0
  REPLY=""
  (( width >= 0 )) || return 0
  if [[ "$value" != *[^\ -~]* ]]; then REPLY="${value[1,width]}"; return 0; fi
  if (( ${(m)#value} <= width )); then REPLY="$value"; return 0; fi
  for ch in "${(@s::)value}"; do
    size=${(m)#ch}
    (( cells + size <= width )) || break
    REPLY+="$ch"
    (( cells += size ))
  done
  return 0
}

# Shared hard/word wrapper. Output lengths count original characters, while
# limits count display cells. Printable ASCII keeps the arithmetic fast path.
# A glyph wider than the entire window is represented by '?' to make progress
# without overflowing curses; its original character still counts as consumed.
zchat_hard_wrap() { _zchat_wrap_cells "$1" "${2:-1}" 0; }
zchat_wrap() { _zchat_wrap_cells "$1" "${2:-1}" 1; }

_zchat_wrap_cells() {
  local text="$1" probe="" prefix="" ch=""
  local -i width=${2:-1} word_wrap=${3:-0} pos=1 total end cells size consumed ascii=0 cut
  local -a chars=()
  ZCHAT_WRAPPED=(); ZCHAT_WRAPPED_LENGTHS=()
  (( width < 1 )) && width=1
  [[ -z "$text" ]] && { ZCHAT_WRAPPED=(""); ZCHAT_WRAPPED_LENGTHS=(0); return 0; }
  [[ "$text" != *[^\ -~]* ]] && ascii=1
  chars=("${(@s::)text}"); total=${#chars}
  while (( pos <= total )); do
    if (( ascii )); then
      end=$(( pos + width )); (( end > total + 1 )) && end=$(( total + 1 ))
      probe="${(j::)chars[pos,end-1]}"
    else
      end=$pos; cells=0; probe=""
      while (( end <= total )); do
        ch="${chars[end]}"; size=${(m)#ch}
        if (( cells + size > width )); then
          if (( end == pos )); then probe='?'; (( end++ )); fi
          break
        fi
        probe+="$ch"; (( cells += size, end++ ))
      done
    fi
    if (( word_wrap && end <= total )); then
      prefix="${probe%[[:space:]]*}"
      if [[ "${chars[end]}" == [[:space:]] ]]; then
        while (( end <= total )) && [[ "${chars[end]}" == [[:space:]] ]]; do (( end++ )); done
      elif [[ -n "$prefix" && "$prefix" != "$probe" ]]; then
        cut=${#prefix}; probe="$prefix"; end=$(( pos + cut ))
        while (( end <= total )) && [[ "${chars[end]}" == [[:space:]] ]]; do (( end++ )); done
      fi
    fi
    consumed=$(( end - pos ))
    ZCHAT_WRAPPED+=("$probe"); ZCHAT_WRAPPED_LENGTHS+=("$consumed")
    pos=$end
  done
  return 0
}

zchat_pad_right() {
  local value="$1"
  local -i width=${2:-0} padding=0
  zchat_clip "$value" "$width"
  padding=$(( width - ${(m)#REPLY} ))
  (( padding > 0 )) && REPLY+="${(pl:padding:: :)}"
  return 0
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
