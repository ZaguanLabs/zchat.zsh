# Optional remote backends. Ollama calls remain in their original libraries.
source "${${(%):-%x}:A:h}/remote_json.zsh"
typeset -g REMOTE_LIB_DIR="${${(%):-%x}:A:h}"
typeset -g ZCHAT_ZCURL_LOADER="${ZCHAT_ZCURL_LOADER:-${REMOTE_LIB_DIR:h}/vendor/zcurl/zcurl.zsh}"
typeset -g ZCHAT_REMOTE_CONFIG="${ZCHAT_REMOTE_CONFIG:-${ZCHAT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zchat}/remotes.json}"
typeset -g REMOTE_ERROR='' REMOTE_PROTOCOL='' REMOTE_URL='' REMOTE_MODEL=''
typeset -g REMOTE_PARAMETERS='' REMOTE_CONFIG_TEXT=''
typeset -gi REMOTE_CONTEXT=65536 REMOTE_MAX_OUTPUT=4096
typeset -ga REMOTE_MODELS=() REMOTE_HEADERS=() REMOTE_OPTIONS=()
typeset -gA REMOTE_CONFIG=() REMOTE_CONFIG_TYPE=() REMOTE_CONFIG_RAW=()

remote_load_config() {
  emulate -L zsh
  setopt extendedglob
  REMOTE_MODELS=() REMOTE_ERROR='' REMOTE_CONFIG_TEXT=''
  REMOTE_CONFIG=() REMOTE_CONFIG_TYPE=() REMOTE_CONFIG_RAW=()
  [[ -e "$ZCHAT_REMOTE_CONFIG" ]] || return 0
  zchat_read_file "$ZCHAT_REMOTE_CONFIG" 1048576 || { REMOTE_ERROR='Cannot read remote configuration'; return 1; }
  REMOTE_CONFIG_TEXT="$REPLY"
  remote_json_parse "$REPLY" || { REMOTE_ERROR='Invalid remote configuration JSON'; return 1; }
  [[ "${REMOTE_JSON_TYPE[/models]}" == '{' ]] || { REMOTE_ERROR='Remote configuration requires a models object'; return 1; }
  local pointer alias
  for pointer in ${(k)REMOTE_JSON_TYPE}; do
    [[ "$pointer" == /models/* && "${pointer#/models/}" != */* ]] || continue
    alias="${pointer#/models/}"
    [[ "$alias" == [a-zA-Z0-9][a-zA-Z0-9_.-]# && "${REMOTE_JSON_TYPE[$pointer]}" == '{' ]] || {
      REMOTE_ERROR='Remote aliases must start with a letter or digit and contain only letters, digits, dots, underscores or hyphens'; return 1
    }
    REMOTE_MODELS+=("remote:${alias}")
  done
  REMOTE_MODELS=("${(@o)REMOTE_MODELS}")
  REMOTE_CONFIG=("${(@kv)REMOTE_JSON}")
  REMOTE_CONFIG_TYPE=("${(@kv)REMOTE_JSON_TYPE}")
  REMOTE_CONFIG_RAW=("${(@kv)REMOTE_JSON_RAW}")
}

remote_selected() { [[ "$SESSION_MODEL" == remote:* ]]; }

remote_profile() {
  emulate -L zsh
  setopt extendedglob
  local name="${1:-$SESSION_MODEL}" prefix key value env auth field
  prefix="/models/${name#remote:}"
  REMOTE_ERROR='' REMOTE_HEADERS=() REMOTE_OPTIONS=()
  [[ "${REMOTE_CONFIG_TYPE[$prefix]}" == '{' ]] || { REMOTE_ERROR="Unknown remote model: $name"; return 1; }
  for field in protocol url model; do
    [[ "${REMOTE_CONFIG_TYPE[$prefix/$field]}" == string ]] || { REMOTE_ERROR="Remote $field must be a string"; return 1; }
  done
  REMOTE_PROTOCOL="${REMOTE_CONFIG[$prefix/protocol]}"
  REMOTE_URL="${REMOTE_CONFIG[$prefix/url]}"
  REMOTE_MODEL="${REMOTE_CONFIG[$prefix/model]}"
  [[ "$REMOTE_PROTOCOL" == chat-completions || "$REMOTE_PROTOCOL" == responses || "$REMOTE_PROTOCOL" == messages ]] || {
    REMOTE_ERROR="Invalid protocol for $name"; return 1
  }
  [[ "$REMOTE_URL" == https://?* || "$REMOTE_URL" == http://?* ]] && [[ "$REMOTE_URL" != *[[:space:][:cntrl:]]* && -n "$REMOTE_MODEL" ]] || {
    REMOTE_ERROR="Remote model requires an HTTP(S) URL and model ID"; return 1
  }
  _json_safe_uint "${REMOTE_CONFIG[$prefix/context_window]:-65536}" 1048576 && (( REPLY >= 4096 )) || { REMOTE_ERROR='Invalid remote context_window'; return 1; }
  REMOTE_CONTEXT=$REPLY
  _json_safe_uint "${REMOTE_CONFIG[$prefix/max_output_tokens]:-4096}" 1048576 && (( REPLY > 0 && REPLY < REMOTE_CONTEXT )) || { REMOTE_ERROR='Invalid remote max_output_tokens'; return 1; }
  REMOTE_MAX_OUTPUT=$REPLY
  REMOTE_PARAMETERS="${REMOTE_CONFIG_RAW[$prefix/parameters]}"
  [[ -n "$REMOTE_PARAMETERS" ]] || REMOTE_PARAMETERS='{}'
  [[ -z "${REMOTE_CONFIG_TYPE[$prefix/parameters]}" || "${REMOTE_CONFIG_TYPE[$prefix/parameters]}" == '{' ]] || { REMOTE_ERROR='parameters must be an object'; return 1; }
  for field in model messages input instructions system stream tools tool_choice n background previous_response_id conversation max_tokens max_completion_tokens max_output_tokens; do
    (( ${+REMOTE_CONFIG_TYPE[$prefix/parameters/$field]} )) && { REMOTE_ERROR="Use profile fields, not parameters.$field (tools and multiple choices are unsupported)"; return 1; }
  done
  auth="${REMOTE_CONFIG[$prefix/auth]:-bearer}"
  env="${REMOTE_CONFIG[$prefix/api_key_env]}"
  if [[ "$auth" != none ]]; then
    [[ "$env" == [a-zA-Z_][a-zA-Z0-9_]# && -n "${(P)env}" ]] || { REMOTE_ERROR="Missing API key environment variable for $name"; return 1; }
    value="${(P)env}"
    [[ "$value" != *[[:cntrl:]]* ]] || { REMOTE_ERROR='Invalid API key'; return 1; }
    case "$auth" in
      bearer) REMOTE_HEADERS+=(--header "Authorization: Bearer $value") ;;
      api-key) REMOTE_HEADERS+=(--header "x-api-key: $value") ;;
      *) REMOTE_ERROR='auth must be bearer, api-key or none'; return 1 ;;
    esac
  fi
  value="${REMOTE_CONFIG[$prefix/ca_file]}"
  if [[ -n "$value" ]]; then
    [[ "$value" == /* && -r "$value" ]] || { REMOTE_ERROR='ca_file must be an absolute readable PEM file'; return 1; }
    REMOTE_OPTIONS+=(--cacert "$value")
  fi
  for field in headers header_env; do
    [[ -z "${REMOTE_CONFIG_TYPE[$prefix/$field]}" || "${REMOTE_CONFIG_TYPE[$prefix/$field]}" == '{' ]] || { REMOTE_ERROR="$field must be an object"; return 1; }
    for key in ${(k)REMOTE_CONFIG_TYPE}; do
      [[ "$key" == "$prefix/$field/"* ]] || continue
      value="${REMOTE_CONFIG[$key]}"
      [[ "${REMOTE_CONFIG_TYPE[$key]}" == string ]] || { REMOTE_ERROR='Headers must be strings'; return 1; }
      if [[ "$field" == header_env ]]; then
        [[ "$value" == [a-zA-Z_][a-zA-Z0-9_]# && -n "${(P)value}" ]] || { REMOTE_ERROR='Missing header environment variable'; return 1; }
        value="${(P)value}"
      fi
      key="${key#$prefix/$field/}"
      [[ "$key" == [a-zA-Z0-9-]## && "$value" != *[[:cntrl:]]* ]] || { REMOTE_ERROR='Invalid remote header'; return 1; }
      [[ "${(L)key}" != (host|content-length|transfer-encoding|content-type|accept) ]] || { REMOTE_ERROR="Reserved header: $key"; return 1; }
      REMOTE_HEADERS+=(--header "$key: $value")
    done
  done
  return 0
}

# Convert the existing conversation/checkpoint representation at the boundary;
# no Ollama request is sent or modified by this adapter.
remote_payload() {
  local source="$1" model system='' messages='' comma='' role content key limit_field
  local -i i=0 limit=${2:-$REMOTE_MAX_OUTPUT}
  remote_json_parse "$source" || return 1
  while [[ -n "${REMOTE_JSON_TYPE[/messages/$i]}" ]]; do
    role="${REMOTE_JSON[/messages/$i/role]}"
    content="${REMOTE_JSON[/messages/$i/content]}"
    if [[ "$role" == system && "$REMOTE_PROTOCOL" != chat-completions ]]; then
      [[ -n "$system" ]] && system+=$'\n\n'
      system+="$content"
    else
      json_quote "$content"; content="$REPLY"
      json_quote "$role"; role="$REPLY"
      messages+="${comma}{\"role\":${role},\"content\":${content}}"
      comma=,
    fi
    (( i++ ))
  done
  json_quote "$REMOTE_MODEL"; model="$REPLY"
  REPLY="{\"model\":${model},\"stream\":true"
  local payload="$REPLY"
  case "$REMOTE_PROTOCOL" in
    responses)
      json_quote "$system"
      payload+=",\"instructions\":${REPLY},\"input\":[${messages}]"
      limit_field=max_output_tokens ;;
    messages)
      json_quote "$system"
      payload+=",\"system\":${REPLY},\"messages\":[${messages}]"
      limit_field=max_tokens ;;
    chat-completions)
      payload+=",\"messages\":[${messages}]"
      limit_field="${REMOTE_CONFIG[/models/${SESSION_MODEL#remote:}/token_field]:-max_tokens}"
      [[ "$limit_field" == max_tokens || "$limit_field" == max_completion_tokens ]] || { REMOTE_ERROR='Invalid token_field'; return 1; } ;;
  esac
  payload+=",\"${limit_field}\":${limit}"
  local extra="${REMOTE_PARAMETERS[2,-2]}"
  [[ -n "${extra//[[:space:]]/}" ]] && payload+=",${extra}"
  REPLY="${payload}}"
}

# Mark the context identity when entering a remote profile so returning to the
# same Ollama model still runs its original context discovery/configuration.
remote_context_configure() {
  if [[ "$CHAT_CONTEXT_MODEL" != "$SESSION_MODEL" || "$CHAT_CONTEXT_HOST" != "$OLLAMA_HOST" ]]; then
    CHAT_LAST_PROMPT_TOKENS=0 CHAT_LAST_OUTPUT_TOKENS=0 CHAT_LAST_PAYLOAD_BYTES=0
    CHAT_COMPACTION_REARM_TOKENS=0
    CHAT_CONTEXT_MODEL="$SESSION_MODEL" CHAT_CONTEXT_HOST="$OLLAMA_HOST"
  fi
  CHAT_CONTEXT_WINDOW=$REMOTE_CONTEXT
  CHAT_CONTEXT_DISCOVERY_PENDING=0
}

backend_prepare_payload() {
  remote_selected || { chat_prepare_payload; return $?; }
  remote_profile || { CHAT_COMPACTION_ERROR="$REMOTE_ERROR"; return 1; }
  remote_context_configure
  state_build_payload
  local source="$REPLY"
  chat_estimate_payload_tokens "$source"
  if (( REPLY >= REMOTE_CONTEXT * ZCHAT_COMPACT_PERCENT / 100 || REPLY + REMOTE_MAX_OUTPUT >= REMOTE_CONTEXT )); then
    backend_compact_history auto || return $?
    state_build_payload
    source="$REPLY"
  fi
  remote_payload "$source" || { CHAT_COMPACTION_ERROR="${REMOTE_ERROR:-Could not build remote payload}"; return 1; }
  local payload="$REPLY"
  chat_estimate_payload_tokens "$payload"
  if (( REPLY + REMOTE_MAX_OUTPUT >= REMOTE_CONTEXT )); then
    CHAT_COMPACTION_ERROR='Remote prompt plus output allowance exceeds the configured context window; shorten the prompt or increase context_window'
    return 1
  fi
  REPLY="$payload"
}

backend_start_stream() {
  remote_selected || { api_start_stream "$@"; return $?; }
  remote_start_stream "$2" "$3"
}

remote_start_stream() {
  local payload="$1" base="$2" suffix
  API_STREAM_ERROR=''
  if [[ -n "$API_STREAM_PID" ]] && kill -0 "$API_STREAM_PID" 2>/dev/null; then
    API_STREAM_ERROR='A response is already running'; return 1
  fi
  remote_profile || { API_STREAM_ERROR="$REMOTE_ERROR"; return 1; }
  [[ -n "$ZCHAT_ZCURL_LOADER" && -r "$ZCHAT_ZCURL_LOADER" ]] || {
    API_STREAM_ERROR='zcurl loader unavailable. Initialize vendor/zcurl and run make zcurl, or set ZCHAT_ZCURL_LOADER'; return 1
  }
  if [[ "$ZCHAT_ZCURL_LOADER" == "${REMOTE_LIB_DIR:h}/vendor/zcurl/zcurl.zsh" && ! -r "${REMOTE_LIB_DIR:h}/vendor/zcurl/build/zcurl.so" ]]; then
    API_STREAM_ERROR='Local zcurl is not built. Run make zcurl from the zchat directory'; return 1
  fi
  for suffix in thinking content err usage; do
    zchat_atomic_write "$base.$suffix" '' 0600 || return 1
  done
  zchat_atomic_write "$base.status" 1 0600 || return 1
  zchat_atomic_write "$base.request" "$payload" 0600 || return 1
  zchat_atomic_write "$base.config" "$REMOTE_CONFIG_TEXT" 0600 || return 1
  zf_rm -f -- "$base.done"
  zsh -df "$REMOTE_LIB_DIR/remote_worker.zsh" "$base" "$SESSION_MODEL" "$ZCHAT_ZCURL_LOADER" </dev/null >/dev/null 2>/dev/null &
  API_STREAM_PID=$!
}

backend_record_response_usage() {
  remote_selected || { chat_record_response_usage "$@"; return $?; }
  _api_byte_length "$1"
  CHAT_LAST_PAYLOAD_BYTES=$REPLY
  CHAT_LAST_PROMPT_TOKENS=${2:-0}
  CHAT_LAST_OUTPUT_TOKENS=${3:-0}
  CHAT_LAST_USAGE_MODEL="$SESSION_MODEL"
  CHAT_LAST_USAGE_HOST="$OLLAMA_HOST"
}

backend_context_summary() {
  remote_selected || { chat_context_summary; return $?; }
  remote_profile || { REPLY="$REMOTE_ERROR"; return 1; }
  state_build_payload
  chat_estimate_payload_tokens "$REPLY"
  REPLY="Remote context: ${REMOTE_CONTEXT} tokens (configured); estimated next prompt: ${REPLY}; output limit: ${REMOTE_MAX_OUTPUT}; checkpoints: ${CHAT_COMPACTION_COUNT}."
}

backend_compact_history() {
  remote_selected || { chat_compact_history "$@"; return $?; }
  CHAT_COMPACTION_ERROR='' CHAT_COMPACTION_CANCELLED=0
  (( ${#MSG_ROLES} )) || return 2
  remote_profile || { CHAT_COMPACTION_ERROR="$REMOTE_ERROR"; return 1; }
  remote_context_configure
  local base="${API_RUNTIME_DIR}/remote_checkpoint" payload summary pid
  local -i request_status=0 start=$CHAT_CONTEXT_START_INDEX
  # Reduce only the checkpoint input when necessary, at user-turn boundaries.
  while true; do
    chat_build_compaction_payload "$start"
    payload="$REPLY"
    chat_estimate_payload_tokens "$payload"
    (( (REPLY < REMOTE_CONTEXT * 85 / 100 && REPLY + ZCHAT_COMPACT_MAX_TOKENS < REMOTE_CONTEXT) || start >= ${#MSG_ROLES} )) && break
    (( start++ ))
    while (( start < ${#MSG_ROLES} )) && [[ "${MSG_ROLES[start]}" != user ]]; do (( start++ )); done
  done
  chat_compaction_output_limit
  remote_payload "$payload" "$REPLY" || return 1
  remote_start_stream "$REPLY" "$base" || { CHAT_COMPACTION_ERROR="$API_STREAM_ERROR"; return 1; }
  pid="$API_STREAM_PID"
  # Reuse the UI's cancellable wait, with its existing handoff contract.
  API_ASYNC_PID="$pid" API_ASYNC_BASE="$base"
  if (( ${UI_ACTIVE:-0} )); then
    ui_wait_for_compaction
    request_status=$?
  else
    wait "$pid" || request_status=$?
  fi
  if (( request_status == 130 )); then
    api_stop_stream "$pid"
    CHAT_COMPACTION_CANCELLED=1
    CHAT_COMPACTION_ERROR='Compaction stopped'
  else
    api_stream_collect "$pid" "$base" || request_status=$?
    CHAT_COMPACTION_ERROR="$API_STREAM_ERROR"
    if (( request_status == 0 )); then
      zchat_read_file "$base.content" 16777216
      summary="$REPLY"
      if [[ -n "$summary" ]]; then
        chat_compaction_replace_history "$summary"
        (( CHAT_COMPACTION_COUNT++ ))
        CHAT_LAST_PROMPT_TOKENS=0 CHAT_LAST_OUTPUT_TOKENS=0 CHAT_LAST_PAYLOAD_BYTES=0
        state_append_message system "♻ Compacted remote context ($1); checkpoint ${CHAT_COMPACTION_COUNT}." || request_status=1
      else
        CHAT_COMPACTION_ERROR='Remote model returned an empty checkpoint'
        request_status=1
      fi
    fi
  fi
  API_STREAM_PID='' API_ASYNC_PID='' API_ASYNC_BASE=''
  zf_rm -f -- "$base".*(N)
  return "$request_status"
}
