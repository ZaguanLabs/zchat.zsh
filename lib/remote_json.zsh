# JSON pointer index for remote configuration and protocol events. Values are
# data only; no evaluation. The existing tokenizer retains its size limits.
typeset -gA REMOTE_JSON=() REMOTE_JSON_TYPE=() REMOTE_JSON_RAW=()
remote_json_parse() {
  REMOTE_JSON=() REMOTE_JSON_TYPE=() REMOTE_JSON_RAW=()
  json_begin "$1" || return 1
  _remote_json_node '' 0 || return 1
  [[ "$JSON_TOKEN_TYPE" == eof ]]
}
_remote_json_node() {
  local pointer="$1" key="" close='}' kind="$JSON_TOKEN_TYPE"
  local -i depth=$2 start=$(( JSON_POS - 1 )) index=0
  (( depth <= JSON_MAX_DEPTH )) || return 1
  (( ${+REMOTE_JSON_TYPE[$pointer]} )) && return 1
  REMOTE_JSON_TYPE[$pointer]="$kind"
  [[ "$kind" == '[' ]] && close=']'
  case "$kind" in
    '{'|'[')
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != "$close" ]]; do
        if [[ "$kind" == '{' ]]; then
          [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
          key="${JSON_TOKEN_VALUE//\~/~0}"
          key="${key//\//~1}"
          json_next || return 1
          [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
          json_next || return 1
        else
          key=$index
          (( index++ ))
        fi
        _remote_json_node "${pointer}/${key}" $(( depth + 1 )) || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
          [[ "$JSON_TOKEN_TYPE" != '}' && "$JSON_TOKEN_TYPE" != ']' ]] || return 1
        elif [[ "$JSON_TOKEN_TYPE" != "$close" ]]; then
          return 1
        fi
      done
      REMOTE_JSON_RAW[$pointer]="${JSON_SOURCE[start,JSON_POS-1]}"
      ;;
    null) REMOTE_JSON[$pointer]='' ;;
    string|number|true|false) REMOTE_JSON[$pointer]="$JSON_TOKEN_VALUE" ;;
    *) return 1 ;;
  esac
  json_next
}
