# lib/api.zsh - Native Zsh HTTP and Ollama streaming integration

typeset -g OLLAMA_HOST="${OLLAMA_HOST:-${ZCHAT_DEFAULT_OLLAMA_HOST:-localhost:11434}}"
typeset -g API_STREAM_PID=""
typeset -g API_HTTP_BODY=""
typeset -g API_NET_HOST=""
typeset -g API_NET_PORT="11434"
typeset -g API_HOST_ERROR=""
typeset -ga API_MODELS=()

# Accept either host:port or an http:// URL and return a canonical endpoint in
# REPLY. The native transport intentionally supports plain HTTP only.
api_normalize_host() {
  local endpoint="$1"
  API_HOST_ERROR=""
  endpoint="${endpoint##[[:space:]]#}"
  endpoint="${endpoint%%[[:space:]]#}"

  if [[ "$endpoint" == https://* ]]; then
    API_HOST_ERROR="HTTPS is not supported by the native Zsh TCP transport. Use an http:// Ollama URL."
    return 1
  fi
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%/}"

  if [[ -z "$endpoint" || "$endpoint" == */* || "$endpoint" == *[[:space:]]* ]]; then
    API_HOST_ERROR="expected http://hostname:port or hostname:port"
    return 1
  fi

  if [[ "$endpoint" == \[*\] ]]; then
    endpoint+=":11434"
  elif [[ "$endpoint" == \[*\]:<-> || "$endpoint" == *:<-> ]]; then
    :
  elif [[ "$endpoint" == *:* ]]; then
    API_HOST_ERROR="IPv6 addresses must be enclosed in brackets"
    return 1
  else
    endpoint+=":11434"
  fi

  REPLY="$endpoint"
}

_api_split_host() {
  local endpoint="${1#http://}"
  endpoint="${endpoint%%/*}"

  if [[ "$endpoint" == \[*\]:<-> ]]; then
    API_NET_HOST="${endpoint#\[}"
    API_NET_HOST="${API_NET_HOST%%\]*}"
    API_NET_PORT="${endpoint##*:}"
  elif [[ "$endpoint" == *:<-> ]]; then
    API_NET_HOST="${endpoint%:*}"
    API_NET_PORT="${endpoint##*:}"
  else
    API_NET_HOST="$endpoint"
    API_NET_PORT="11434"
  fi
}

_api_byte_length() {
  setopt localoptions nomultibyte
  REPLY=${#1}
}

# Decode a complete HTTP/1.1 chunked body. Input indexing is deliberately byte
# based because chunk sizes count octets, not Unicode characters.
_api_dechunk() {
  setopt localoptions extendedglob nomultibyte
  local wire="$1" output="" size_line="" hex="" data=""
  local -i size

  while [[ -n "$wire" ]]; do
    [[ "$wire" == *$'\r\n'* ]] || return 1
    size_line="${wire%%$'\r\n'*}"
    wire="${wire[$(( ${#size_line} + 3 )),-1]}"
    hex="${size_line%%;*}"
    [[ "$hex" == [[:xdigit:]]## ]] || return 1
    size=$(( 16#$hex ))
    (( size == 0 )) && break
    (( ${#wire} >= size + 2 )) || return 1
    data="${wire[1,$size]}"
    output+="$data"
    wire="${wire[$(( size + 3 )),-1]}"
  done

  REPLY="$output"
}

# Perform a small synchronous HTTP GET. Used only by the model picker.
_api_http_get() {
  local endpoint="$1" path="$2"
  local fd="" request="" chunk="" raw="" header="" body=""
  local status_line=""

  _api_split_host "$endpoint"
  ztcp "$API_NET_HOST" "$API_NET_PORT" 2>/dev/null || return 1
  fd=$REPLY

  request=$'GET '"$path"$' HTTP/1.1\r\nHost: '"$endpoint"$'\r\nAccept: application/json\r\nConnection: close\r\n\r\n'
  if ! syswrite -o "$fd" "$request" 2>/dev/null; then
    ztcp -c "$fd" 2>/dev/null
    return 1
  fi

  while sysread -i "$fd" -s 16384 -t 3 chunk 2>/dev/null; do
    raw+="$chunk"
  done
  ztcp -c "$fd" 2>/dev/null

  [[ "$raw" == *$'\r\n\r\n'* ]] || return 1
  header="${raw%%$'\r\n\r\n'*}"
  body="${raw[$(( ${#header} + 5 )),-1]}"
  status_line="${header%%$'\r\n'*}"
  [[ "$status_line" == 'HTTP/'*' 2'* ]] || return 1

  if [[ "${(L)header}" == *$'transfer-encoding: chunked'* ]]; then
    _api_dechunk "$body" || return 1
    API_HTTP_BODY="$REPLY"
  else
    API_HTTP_BODY="$body"
  fi
}

# Fetch model names from Ollama without curl or jq.
api_get_models() {
  local host="${1:-$OLLAMA_HOST}"
  API_MODELS=()
  _api_http_get "$host" "/api/tags" || return 1
  json_parse_models "$API_HTTP_BODY" || return 1
  API_MODELS=("${JSON_MODEL_NAMES[@]}")
}

_api_process_event_line() {
  local line="$1" tfd="$2" cfd="$3" efd="$4"
  local t="" c="" rest="" t_part="" c_part=""

  [[ -z "$line" ]] && return 0
  if ! json_parse_ollama_event "$line"; then
    print -r -u "$efd" -- "Invalid Ollama JSON event: ${JSON_ERROR:-parse error}"
    return 1
  fi
  if [[ -n "$JSON_MESSAGE_ERROR" ]]; then
    print -r -u "$efd" -- "$JSON_MESSAGE_ERROR"
    return 1
  fi

  t="$JSON_MESSAGE_THINKING"
  c="$JSON_MESSAGE_CONTENT"
  [[ -n "$t" ]] && print -rn -u "$tfd" -- "$t"

  if [[ -n "$c" ]]; then
    if [[ "$c" == *'<think>'* ]]; then
      print -rn -u "$cfd" -- "${c%%'<think>'*}"
      rest="${c#*'<think>'}"
      if [[ "$rest" == *'</think>'* ]]; then
        t_part="${rest%%'</think>'*}"
        c_part="${rest#*'</think>'}"
        print -rn -u "$tfd" -- "$t_part"
        print -rn -u "$cfd" -- "$c_part"
        API_IN_THINK_TAG=0
      else
        print -rn -u "$tfd" -- "$rest"
        API_IN_THINK_TAG=1
      fi
    elif (( API_IN_THINK_TAG )); then
      if [[ "$c" == *'</think>'* ]]; then
        t_part="${c%%'</think>'*}"
        c_part="${c#*'</think>'}"
        print -rn -u "$tfd" -- "$t_part"
        print -rn -u "$cfd" -- "$c_part"
        API_IN_THINK_TAG=0
      else
        print -rn -u "$tfd" -- "$c"
      fi
    else
      print -rn -u "$cfd" -- "$c"
    fi
  fi
}

_api_consume_ndjson() {
  local data="$1" tfd="$2" cfd="$3" efd="$4"
  local line=""
  API_NDJSON_BUFFER+="$data"
  while [[ "$API_NDJSON_BUFFER" == *$'\n'* ]]; do
    line="${API_NDJSON_BUFFER%%$'\n'*}"
    API_NDJSON_BUFFER="${API_NDJSON_BUFFER[$(( ${#line} + 2 )),-1]}"
    line="${line%$'\r'}"
    _api_process_event_line "$line" "$tfd" "$cfd" "$efd"
  done
}

# Stream HTTP chunks directly into the reasoning/content descriptors. Transfer
# framing uses byte indexing; emitted UTF-8 bytes remain unchanged.
_api_http_stream() {
  setopt localoptions extendedglob nomultibyte
  local endpoint="$1" payload="$2" t_file="$3" c_file="$4" err_file="$5"
  local fd="" tfd="" cfd="" efd=""
  local request="" chunk="" header="" status_line="" size_line="" hex="" data=""
  local wire=""
  local -i headers_done=0 chunked=0 expected=-1 payload_bytes

  API_NDJSON_BUFFER=""
  API_IN_THINK_TAG=0
  exec {tfd}>"$t_file" {cfd}>"$c_file" {efd}>>"$err_file" || return 1

  _api_split_host "$endpoint"
  if ! ztcp "$API_NET_HOST" "$API_NET_PORT" 2>/dev/null; then
    print -r -u "$efd" -- "Failed to connect to Ollama at $endpoint"
    return 1
  fi
  fd=$REPLY
  _api_byte_length "$payload"
  payload_bytes=$REPLY
  request=$'POST /api/chat HTTP/1.1\r\nHost: '"$endpoint"$'\r\nContent-Type: application/json\r\nAccept: application/x-ndjson\r\nConnection: close\r\nContent-Length: '"$payload_bytes"$'\r\n\r\n'"$payload"

  if ! syswrite -o "$fd" "$request" 2>/dev/null; then
    print -r -u "$efd" -- "Failed to send request to Ollama"
    ztcp -c "$fd" 2>/dev/null
    return 1
  fi

  while sysread -i "$fd" -s 16384 -t 300 chunk 2>/dev/null; do
    wire+="$chunk"

    if (( ! headers_done )); then
      [[ "$wire" == *$'\r\n\r\n'* ]] || continue
      header="${wire%%$'\r\n\r\n'*}"
      wire="${wire[$(( ${#header} + 5 )),-1]}"
      status_line="${header%%$'\r\n'*}"
      if [[ "$status_line" != 'HTTP/'*' 2'* ]]; then
        print -r -u "$efd" -- "Ollama HTTP error: $status_line"
        ztcp -c "$fd" 2>/dev/null
        return 1
      fi
      [[ "${(L)header}" == *$'transfer-encoding: chunked'* ]] && chunked=1
      headers_done=1
    fi

    if (( chunked )); then
      while true; do
        if (( expected < 0 )); then
          [[ "$wire" == *$'\r\n'* ]] || break
          size_line="${wire%%$'\r\n'*}"
          wire="${wire[$(( ${#size_line} + 3 )),-1]}"
          hex="${size_line%%;*}"
          if [[ "$hex" != [[:xdigit:]]## ]]; then
            print -r -u "$efd" -- "Invalid HTTP chunk size"
            ztcp -c "$fd" 2>/dev/null
            return 1
          fi
          expected=$(( 16#$hex ))
          (( expected == 0 )) && break 2
        fi

        (( ${#wire} >= expected + 2 )) || break
        data="${wire[1,$expected]}"
        wire="${wire[$(( expected + 3 )),-1]}"
        expected=-1
        _api_consume_ndjson "$data" "$tfd" "$cfd" "$efd"
      done
    else
      data="$wire"
      wire=""
      _api_consume_ndjson "$data" "$tfd" "$cfd" "$efd"
    fi
  done

  ztcp -c "$fd" 2>/dev/null
  if [[ -n "$API_NDJSON_BUFFER" ]]; then
    _api_process_event_line "${API_NDJSON_BUFFER%$'\r'}" "$tfd" "$cfd" "$efd"
  fi
  exec {tfd}>&- {cfd}>&- {efd}>&-
}

# Start a background chat stream. The PID is returned through API_STREAM_PID.
api_start_stream() {
  local host="${1:-$OLLAMA_HOST}"
  local payload="$2"
  local base_file="$3"
  local t_file="${base_file}.thinking"
  local c_file="${base_file}.content"
  local done_file="${base_file}.done"
  local err_file="${base_file}.err"

  : > "$t_file"
  : > "$c_file"
  zf_rm -f "$done_file"
  : > "$err_file"

  (
    _api_http_stream "$host" "$payload" "$t_file" "$c_file" "$err_file"
    print -r -- "DONE" > "$done_file"
  ) </dev/null >/dev/null &

  API_STREAM_PID=$!
}

api_stop_stream() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  fi
}
