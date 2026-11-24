# Incremental SSE framing and protocol adapters. Worker-owned state; UTF-8
# sequences may cross transport chunks and are retained until an event ends.
typeset -g REMOTE_SSE_BUFFER='' REMOTE_SSE_DATA='' REMOTE_SSE_EVENT=''
typeset -gi REMOTE_SSE_STARTED=0 REMOTE_DONE=0 REMOTE_INPUT_TOKENS=0 REMOTE_OUTPUT_TOKENS=0

# HTTP errors use error.{message,code,param}; Responses SSE errors put these
# fields at the top level, while response.failed nests them under response.
remote_error_detail() {
  local prefix="$1" detail="${REMOTE_JSON[$1/message]}" field value
  [[ -n "$detail" ]] || detail="${REMOTE_JSON[$prefix]}"
  [[ -n "$detail" ]] || detail='Remote API error'
  for field in code param; do
    value="${REMOTE_JSON[$prefix/$field]}"
    [[ -z "$value" ]] || detail+=" (${field}: ${value})"
  done
  zchat_terminal_safe "${detail[1,2048]}"
}

remote_http_error() {
  local http_status="$1" transport_error="$2" body_file="$3" detail=''
  # Read only bounded JSON error envelopes, never expose arbitrary HTML/body
  # dumps in the transcript. Preserve HTTP status when JSON parsing fails.
  if zchat_read_file "$body_file" 1048576 && remote_json_parse "$REPLY"; then
    if [[ -n "${REMOTE_JSON_TYPE[/error]}" && "${REMOTE_JSON_TYPE[/error]}" != null ]]; then
      remote_error_detail /error
      detail="$REPLY"
    elif [[ -n "${REMOTE_JSON[/message]}" ]]; then
      remote_error_detail ''
      detail="$REPLY"
    fi
  fi
  [[ -n "$detail" ]] || detail="${transport_error:-request failed}"
  REMOTE_ERROR="Remote HTTP ${http_status:-0}: ${detail}"
}

remote_usage() {
  local prefix="$1" input="${2:-input_tokens}" output="${3:-output_tokens}"
  if _json_safe_uint "${REMOTE_JSON[$prefix/$input]}"; then
    REMOTE_INPUT_TOKENS=$REPLY
    if [[ "$REMOTE_PROTOCOL" == messages ]]; then
      # Messages reports cached prompt tokens separately from uncached input.
      local field
      for field in cache_creation_input_tokens cache_read_input_tokens; do
        _json_safe_uint "${REMOTE_JSON[$prefix/$field]}" && (( REMOTE_INPUT_TOKENS += REPLY ))
      done
    fi
  fi
  _json_safe_uint "${REMOTE_JSON[$prefix/$output]}" && REMOTE_OUTPUT_TOKENS=$REPLY
  return 0
}

remote_event() {
  local empty_pointer=''
  local data="$1" kind text='' thinking='' finish=''
  [[ -n "$data" ]] || return 0
  # Responses ends with response.completed, not [DONE]. Some compatible
  # gateways append the Chat Completions sentinel; tolerate it only after a
  # verified Responses completion, never as a substitute for that event.
  if [[ "$REMOTE_PROTOCOL" == responses && "$data" == '[DONE]' ]]; then
    (( REMOTE_DONE )) && return 0
    REMOTE_ERROR='Responses stream ended with [DONE] before response.completed'; return 1
  fi
  if (( REMOTE_DONE )); then
    REMOTE_ERROR='Data after the final remote stream event'; return 1
  fi
  if [[ "$REMOTE_PROTOCOL" == chat-completions && "$data" == '[DONE]' ]]; then
    REMOTE_DONE=1
    return 0
  fi
  remote_json_parse "$data" || { REMOTE_ERROR='Invalid JSON in remote stream'; return 1; }
  [[ "${REMOTE_JSON_TYPE[$empty_pointer]}" == '{' ]] || { REMOTE_ERROR='Remote event must be an object'; return 1; }
  kind="${REMOTE_JSON[/type]:-$REMOTE_SSE_EVENT}"
  if [[ -n "${REMOTE_JSON_TYPE[/error]}" && "${REMOTE_JSON_TYPE[/error]}" != null ]] || [[ "$kind" == error ]]; then
    if [[ -n "${REMOTE_JSON_TYPE[/error]}" && "${REMOTE_JSON_TYPE[/error]}" != null ]]; then
      remote_error_detail /error
    else
      remote_error_detail ''
    fi
    REMOTE_ERROR="$REPLY"
    return 1
  fi
  case "$REMOTE_PROTOCOL" in
    chat-completions)
      text="${REMOTE_JSON[/choices/0/delta/content]}${REMOTE_JSON[/choices/0/delta/refusal]}"
      thinking="${REMOTE_JSON[/choices/0/delta/reasoning_content]:-${REMOTE_JSON[/choices/0/delta/reasoning]}}"
      finish="${REMOTE_JSON[/choices/0/finish_reason]}"
      [[ "$finish" != tool_calls && "$finish" != function_call ]] || { REMOTE_ERROR='Remote model requested unsupported tool execution'; return 1; }
      [[ "$finish" != content_filter ]] || { REMOTE_ERROR='Remote response blocked by content filter'; return 1; }
      remote_usage /usage prompt_tokens completion_tokens
      ;;
    responses)
      case "$kind" in
        response.output_text.delta|response.refusal.delta) text="${REMOTE_JSON[/delta]}" ;;
        response.reasoning_summary_text.delta|response.reasoning_text.delta) thinking="${REMOTE_JSON[/delta]}" ;;
        response.failed)
          remote_usage /response/usage
          remote_error_detail /response/error
          REMOTE_ERROR="Responses failed: $REPLY"; return 1 ;;
        response.incomplete)
          remote_usage /response/usage
          finish="${REMOTE_JSON[/response/incomplete_details/reason]:-unknown reason}"
          REMOTE_ERROR="Responses incomplete: $finish"
          [[ "$finish" != max_output_tokens ]] || REMOTE_ERROR+=' (the output budget includes reasoning tokens; increase max_output_tokens or reduce reasoning effort)'
          return 1 ;;
        response.completed)
          [[ "${REMOTE_JSON_TYPE[/response]}" == '{' && "${REMOTE_JSON[/response/status]}" == completed ]] || { REMOTE_ERROR='Invalid response.completed event: expected response.status=completed'; return 1; }
          remote_usage /response/usage
          REMOTE_DONE=1 ;;
        response.output_item.added)
          [[ "${REMOTE_JSON[/item/type]}" != function_call ]] || { REMOTE_ERROR='Remote model requested unsupported tool execution'; return 1; } ;;
      esac
      ;;
    messages)
      case "$kind" in
        message_start) remote_usage /message/usage ;;
        content_block_start)
          case "${REMOTE_JSON[/content_block/type]}" in
            text) text="${REMOTE_JSON[/content_block/text]}" ;;
            thinking) thinking="${REMOTE_JSON[/content_block/thinking]}" ;;
            tool_use|server_tool_use) REMOTE_ERROR='Remote model requested unsupported tool execution'; return 1 ;;
          esac ;;
        content_block_delta)
          case "${REMOTE_JSON[/delta/type]}" in
            text_delta) text="${REMOTE_JSON[/delta/text]}" ;;
            thinking_delta) thinking="${REMOTE_JSON[/delta/thinking]}" ;;
          esac ;;
        message_delta)
          remote_usage /usage
          [[ "${REMOTE_JSON[/delta/stop_reason]}" != tool_use ]] || { REMOTE_ERROR='Remote model requested unsupported tool execution'; return 1; } ;;
        message_stop) REMOTE_DONE=1 ;;
      esac
      ;;
  esac
  [[ -z "$text" ]] || print -rn -u "$remote_content_fd" -- "$text" || return 1
  [[ -z "$thinking" ]] || print -rn -u "$remote_thinking_fd" -- "$thinking" || return 1
  return 0
}

remote_sse_feed() {
  setopt localoptions nomultibyte
  local line='' field='' value=''
  REMOTE_SSE_BUFFER+="$1"
  if (( ! REMOTE_SSE_STARTED )); then
    [[ "$REMOTE_SSE_BUFFER" == $'\xef' || "$REMOTE_SSE_BUFFER" == $'\xef\xbb' ]] && return 0
    REMOTE_SSE_BUFFER="${REMOTE_SSE_BUFFER#$'\xef\xbb\xbf'}"
    REMOTE_SSE_STARTED=1
  fi
  # CR, LF and CRLF are all legal SSE line endings. Retain a final CR until
  # the next chunk to avoid treating a split CRLF as two line endings.
  while [[ "$REMOTE_SSE_BUFFER" == *[$'\r\n']* ]]; do
    line="${REMOTE_SSE_BUFFER%%[$'\r\n']*}"
    local -i pos=$(( ${#line} + 1 ))
    [[ "${REMOTE_SSE_BUFFER[pos]}" == $'\r' && $pos == ${#REMOTE_SSE_BUFFER} ]] && break
    if [[ "${REMOTE_SSE_BUFFER[pos,pos+1]}" == $'\r\n' ]]; then (( pos++ )); fi
    REMOTE_SSE_BUFFER="${REMOTE_SSE_BUFFER[pos+1,-1]}"
    if [[ -z "$line" ]]; then
      remote_event "${REMOTE_SSE_DATA%$'\n'}" || return 1
      REMOTE_SSE_DATA='' REMOTE_SSE_EVENT=''
    elif [[ "$line" != :* ]]; then
      field="${line%%:*}" value="${line#*:}"
      [[ "$line" == *:* ]] || value=''
      value="${value# }"
      case "$field" in
        data) REMOTE_SSE_DATA+="${value}"$'\n' ;;
        event) REMOTE_SSE_EVENT="$value" ;;
      esac
    fi
    (( ${#REMOTE_SSE_DATA} <= 8388608 )) || { REMOTE_ERROR='Remote SSE event exceeds 8 MiB'; return 1; }
  done
  (( ${#REMOTE_SSE_BUFFER} <= 8388608 )) || { REMOTE_ERROR='Remote SSE line exceeds 8 MiB'; return 1; }
  return 0
}
