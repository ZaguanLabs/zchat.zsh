# lib/util.zsh - Native Zsh utility helpers

typeset -ga ZCHAT_WRAPPED=()

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

# Read an entire file through zsh/mapfile. Result is returned in REPLY.
zchat_read_file() {
  REPLY="${mapfile[$1]}"
}

# Current local time without invoking date(1). Result is returned in REPLY.
zchat_time() {
  strftime -s REPLY '%H:%M'
}
