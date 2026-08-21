# lib/api.zsh - Native Zsh HTTP and Ollama streaming integration

typeset -g OLLAMA_HOST="${OLLAMA_HOST:-${ZCHAT_DEFAULT_OLLAMA_HOST:-localhost:11434}}"
typeset -g API_STREAM_PID=""
typeset -g API_HTTP_BODY=""
typeset -g API_NET_HOST=""
typeset -g API_NET_PORT="11434"
typeset -g API_HOST_ERROR=""
typeset -g API_HTTP_ERROR=""
typeset -gi API_RUNNING_CONTEXT=0
typeset -g API_ASYNC_PID=""
typeset -g API_ASYNC_BASE=""
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

# Perform a complete HTTP GET for Ollama model metadata.
_api_http_get() {
  _api_http_request GET "$2" "" "$1"
}

# Perform one complete HTTP request for model metadata and non-streaming
# checkpoint generation. Interactive replies continue to use the stream path.
_api_http_request() {
  setopt localoptions nomultibyte
  local method="$1" path="$2" payload="${3:-}" endpoint="${4:-$OLLAMA_HOST}"
  local fd="" request="" chunk="" raw="" header="" body=""
  local status_line=""
  local -i payload_bytes

  API_HTTP_BODY=""
  API_HTTP_ERROR=""

  _api_split_host "$endpoint"
  if ! ztcp "$API_NET_HOST" "$API_NET_PORT" 2>/dev/null; then
    API_HTTP_ERROR="Could not connect to Ollama at ${endpoint}"
    return 1
  fi
  fd=$REPLY

  _api_byte_length "$payload"
  payload_bytes=$REPLY
  request="${method} ${path} HTTP/1.1"$'\r\n'"Host: ${endpoint}"$'\r\n'\
"Content-Type: application/json"$'\r\n'"Accept: application/json"$'\r\n'\
"Connection: close"$'\r\n'"Content-Length: ${payload_bytes}"$'\r\n\r\n'"${payload}"
  if ! syswrite -o "$fd" "$request" 2>/dev/null; then
    API_HTTP_ERROR="Failed to send request to Ollama"
    ztcp -c "$fd" 2>/dev/null
    return 1
  fi

  while sysread -i "$fd" -s 32768 -t 300 chunk 2>/dev/null; do
    raw+="$chunk"
  done
  ztcp -c "$fd" 2>/dev/null

  [[ "$raw" == *$'\r\n\r\n'* ]] || {
    API_HTTP_ERROR="Ollama returned an incomplete HTTP response"
    return 1
  }
  header="${raw%%$'\r\n\r\n'*}"
  body="${raw[$(( ${#header} + 5 )),-1]}"
  status_line="${header%%$'\r\n'*}"
  if [[ "$status_line" != 'HTTP/'*' 2'* ]]; then
    API_HTTP_ERROR="Ollama HTTP error: ${status_line}"
    API_HTTP_BODY="$body"
    return 1
  fi

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

api_get_running_context() {
  local model="$1" host="${2:-$OLLAMA_HOST}"
  API_RUNNING_CONTEXT=0
  _api_http_get "$host" "/api/ps" || return 1
  if ! json_parse_running_model_context "$API_HTTP_BODY" "$model"; then
    API_HTTP_ERROR="Could not parse Ollama running-model metadata"
    return 1
  fi
  API_RUNNING_CONTEXT="$JSON_RUNNING_MODEL_CONTEXT"
  (( API_RUNNING_CONTEXT > 0 ))
}

api_chat_sync() {
  _api_http_request POST "/api/chat" "$1" "${2:-$OLLAMA_HOST}"
}

api_async_cleanup() {
  local base="${1:-$API_ASYNC_BASE}"
  [[ -n "$base" ]] && zf_rm -f -- "${base}.body" "${base}.error" \
    "${base}.status" "${base}.done" 2>/dev/null
  if [[ -z "$1" || "$base" == "$API_ASYNC_BASE" ]]; then
    API_ASYNC_PID=""
    API_ASYNC_BASE=""
  fi
}

# Non-streaming checkpoint requests still run in a child while curses is
# active, allowing Escape/Ctrl+C, scrolling, and resize handling to continue.
api_async_start() {
  local method="$1" path="$2" payload="${3:-}" endpoint="${4:-$OLLAMA_HOST}"
  local base="${TMPDIR:-/tmp}/zchat_http_${$}_${EPOCHREALTIME//./_}_${RANDOM}"
  API_HTTP_ERROR=""
  if [[ -n "$API_ASYNC_PID" ]] && kill -0 "$API_ASYNC_PID" 2>/dev/null; then
    API_HTTP_ERROR="An Ollama request is already running"
    return 1
  fi
  api_async_cleanup
  API_ASYNC_BASE="$base"
  (
    trap - EXIT
    local -i request_status=0
    API_HTTP_BODY=""
    API_HTTP_ERROR=""
    _api_http_request "$method" "$path" "$payload" "$endpoint" || request_status=$?
    mapfile[${base}.body]="$API_HTTP_BODY"
    mapfile[${base}.error]="$API_HTTP_ERROR"
    mapfile[${base}.status]="$request_status"
    mapfile[${base}.done]="done"
    exit "$request_status"
  ) </dev/null >/dev/null 2>&1 &
  API_ASYNC_PID=$!
}

api_async_ready() {
  [[ -n "$API_ASYNC_BASE" && -f "${API_ASYNC_BASE}.done" ]] && return 0
  [[ -n "$API_ASYNC_PID" ]] && kill -0 "$API_ASYNC_PID" 2>/dev/null && return 1
  return 0
}

api_async_collect() {
  local pid="$API_ASYNC_PID" base="$API_ASYNC_BASE" request_status=1
  API_HTTP_BODY=""
  API_HTTP_ERROR=""
  [[ -n "$base" ]] || { API_HTTP_ERROR="No Ollama request is running"; return 1; }
  if [[ -f "${base}.done" ]]; then
    API_HTTP_BODY="${mapfile[${base}.body]-}"
    API_HTTP_ERROR="${mapfile[${base}.error]-}"
    request_status="${mapfile[${base}.status]-1}"
  else
    API_HTTP_ERROR="Ollama request worker exited before returning a result"
  fi
  [[ -n "$pid" ]] && wait "$pid" 2>/dev/null
  api_async_cleanup "$base"
  [[ "$request_status" == <0-255> ]] || request_status=1
  return "$request_status"
}

api_async_cancel() {
  local pid="$API_ASYNC_PID" base="$API_ASYNC_BASE"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    zselect -t 2 2>/dev/null
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  api_async_cleanup "$base"
  API_HTTP_BODY=""
  API_HTTP_ERROR="Ollama request cancelled"
}

_api_process_event_line() {
  local line="$1" tfd="$2" cfd="$3" efd="$4" ufd="$5"
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
  if (( JSON_MESSAGE_DONE )); then
    print -r -u "$ufd" -- "${JSON_MESSAGE_PROMPT_TOKENS} ${JSON_MESSAGE_OUTPUT_TOKENS}"
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
  local data="$1" tfd="$2" cfd="$3" efd="$4" ufd="$5"
  local line=""
  API_NDJSON_BUFFER+="$data"
  while [[ "$API_NDJSON_BUFFER" == *$'\n'* ]]; do
    line="${API_NDJSON_BUFFER%%$'\n'*}"
    API_NDJSON_BUFFER="${API_NDJSON_BUFFER[$(( ${#line} + 2 )),-1]}"
    line="${line%$'\r'}"
    _api_process_event_line "$line" "$tfd" "$cfd" "$efd" "$ufd"
  done
}

# Stream HTTP chunks directly into the reasoning/content descriptors. Transfer
# framing uses byte indexing; emitted UTF-8 bytes remain unchanged.
_api_http_stream() {
  setopt localoptions extendedglob nomultibyte
  local endpoint="$1" payload="$2" t_file="$3" c_file="$4" err_file="$5" usage_file="$6"
  local fd="" tfd="" cfd="" efd="" ufd=""
  local request="" chunk="" header="" status_line="" size_line="" hex="" data=""
  local wire=""
  local -i headers_done=0 chunked=0 expected=-1 payload_bytes

  API_NDJSON_BUFFER=""
  API_IN_THINK_TAG=0
  exec {tfd}>"$t_file" {cfd}>"$c_file" {efd}>>"$err_file" {ufd}>"$usage_file" || return 1

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
        _api_consume_ndjson "$data" "$tfd" "$cfd" "$efd" "$ufd"
      done
    else
      data="$wire"
      wire=""
      _api_consume_ndjson "$data" "$tfd" "$cfd" "$efd" "$ufd"
    fi
  done

  ztcp -c "$fd" 2>/dev/null
  if [[ -n "$API_NDJSON_BUFFER" ]]; then
    _api_process_event_line "${API_NDJSON_BUFFER%$'\r'}" "$tfd" "$cfd" "$efd" "$ufd"
  fi
  exec {tfd}>&- {cfd}>&- {efd}>&- {ufd}>&-
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
  local usage_file="${base_file}.usage"

  : > "$t_file"
  : > "$c_file"
  zf_rm -f "$done_file"
  : > "$err_file"
  : > "$usage_file"

  (
    _api_http_stream "$host" "$payload" "$t_file" "$c_file" "$err_file" "$usage_file"
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
