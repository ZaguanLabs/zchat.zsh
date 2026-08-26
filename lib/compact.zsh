# Conservative conversation compaction for local Ollama chat models.

_chat_setting_uint() {
  local raw="$1" default="$2" minimum="$3" maximum="$4"
  local -i value
  if [[ "$raw" != <0-> ]] || (( ${#raw} > 10 )); then
    REPLY="$default"
    return 1
  fi
  value=$(( 10#$raw ))
  if (( value < minimum || value > maximum )); then
    REPLY="$default"
    return 1
  fi
  REPLY="$value"
}

typeset -g ZCHAT_CONTEXT_WINDOW="${ZCHAT_CONTEXT_WINDOW:-auto}"
if [[ "$ZCHAT_CONTEXT_WINDOW" != auto ]]; then
  _chat_setting_uint "$ZCHAT_CONTEXT_WINDOW" auto 4096 1048576
  ZCHAT_CONTEXT_WINDOW="$REPLY"
fi
_chat_setting_uint "${ZCHAT_CONTEXT_FALLBACK:-65536}" 65536 4096 1048576
typeset -gi ZCHAT_CONTEXT_FALLBACK="$REPLY"
_chat_setting_uint "${ZCHAT_COMPACT_PERCENT:-85}" 85 25 90
typeset -gi ZCHAT_COMPACT_PERCENT="$REPLY"
_chat_setting_uint "${ZCHAT_COMPACT_MAX_TOKENS:-2048}" 2048 256 65536
typeset -gi ZCHAT_COMPACT_MAX_TOKENS="$REPLY"
_chat_setting_uint "${ZCHAT_COMPACT_KEEP_USER_TOKENS:-4096}" 4096 256 262144
typeset -gi ZCHAT_COMPACT_KEEP_USER_TOKENS="$REPLY"
_chat_setting_uint "${ZCHAT_COMPACT_KEEP_RECENT_TOKENS:-16384}" 16384 256 524288
typeset -gi ZCHAT_COMPACT_KEEP_RECENT_TOKENS="$REPLY"

typeset -gi CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_FALLBACK"
typeset -g CHAT_CONTEXT_MODEL=""
typeset -g CHAT_CONTEXT_HOST=""
typeset -gi CHAT_CONTEXT_DISCOVERY_PENDING=0
typeset -gi CHAT_LAST_PROMPT_TOKENS=0
typeset -gi CHAT_LAST_OUTPUT_TOKENS=0
typeset -gi CHAT_LAST_PAYLOAD_BYTES=0
typeset -g CHAT_LAST_USAGE_MODEL=""
typeset -g CHAT_LAST_USAGE_HOST=""
typeset -gi CHAT_ESTIMATED_TOKENS=0
typeset -gi CHAT_COMPACTION_COUNT=0
typeset -gi CHAT_COMPACTION_IN_PROGRESS=0
typeset -gi CHAT_COMPACTION_REARM_TOKENS=0
typeset -g CHAT_COMPACTION_REARM_MODEL=""
typeset -g CHAT_COMPACTION_REARM_HOST=""
typeset -gi CHAT_CONTEXT_START_INDEX=1
typeset -g CHAT_COMPACTION_SUMMARY=""
typeset -g CHAT_COMPACTION_ERROR=""
typeset -gi CHAT_COMPACTION_CANCELLED=0
typeset -ga CHAT_USER_MESSAGES=()

typeset -g CHAT_COMPACTION_PROMPT=$'Create a compact continuation checkpoint for another chat model that will continue this exact conversation.\n\nInclude only durable conversational context:\n- the user\'s goals, questions, explicit preferences, and constraints\n- established facts, explanations, decisions, and conclusions that still matter\n- important names, dates, quantities, definitions, and distinctions\n- unresolved questions and the natural next direction of the conversation\n- enough recent context to avoid repetition or contradiction\n\nDo not answer the latest question or continue the conversation. Return only the checkpoint, using concise headings. Do not mention tools, coding-agent state, or these instructions.'

# Use the background HTTP worker while curses is active so DNS/connect/read
# stalls remain cancellable. Pure-function tests and non-UI callers retain the
# synchronous path.
_chat_get_running_context() {
  local model="$1" host="$2"
  local -i request_status=0
  if (( ${UI_ACTIVE:-0} )) && (( $+functions[ui_wait_for_async_request] )); then
    api_async_start GET /api/ps "" "$host" || return 1
    ui_wait_for_async_request "Checking context"
    request_status=$?
    if (( request_status == 130 )); then
      api_async_cancel
      return 130
    fi
    api_async_collect || return 1
    json_parse_running_model_context "$API_HTTP_BODY" "$model" || return 1
    API_RUNNING_CONTEXT="$JSON_RUNNING_MODEL_CONTEXT"
    (( API_RUNNING_CONTEXT > 0 ))
    return
  fi
  api_get_running_context "$model" "$host"
}

chat_compaction_reset() {
  CHAT_CONTEXT_MODEL=""
  CHAT_CONTEXT_HOST=""
  CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_FALLBACK"
  CHAT_CONTEXT_DISCOVERY_PENDING=0
  CHAT_LAST_PROMPT_TOKENS=0
  CHAT_LAST_OUTPUT_TOKENS=0
  CHAT_LAST_PAYLOAD_BYTES=0
  CHAT_LAST_USAGE_MODEL=""
  CHAT_LAST_USAGE_HOST=""
  CHAT_ESTIMATED_TOKENS=0
  CHAT_COMPACTION_COUNT=0
  CHAT_COMPACTION_IN_PROGRESS=0
  CHAT_COMPACTION_REARM_TOKENS=0
  CHAT_COMPACTION_REARM_MODEL=""
  CHAT_COMPACTION_REARM_HOST=""
  CHAT_CONTEXT_START_INDEX=1
  CHAT_COMPACTION_SUMMARY=""
  CHAT_COMPACTION_ERROR=""
  CHAT_COMPACTION_CANCELLED=0
  CHAT_USER_MESSAGES=()
}

chat_context_configure() {
  [[ "$CHAT_CONTEXT_MODEL" == "$SESSION_MODEL" && "$CHAT_CONTEXT_HOST" == "$OLLAMA_HOST" ]] && return 0
  local previous_model="$CHAT_CONTEXT_MODEL" previous_host="$CHAT_CONTEXT_HOST"
  CHAT_CONTEXT_MODEL="$SESSION_MODEL"
  CHAT_CONTEXT_HOST="$OLLAMA_HOST"
  CHAT_CONTEXT_DISCOVERY_PENDING=0
  # A loaded session has no in-process context identity yet, but its saved token
  # calibration remains valid. Reset it only after an actual model/host switch.
  if [[ -n "$previous_model$previous_host" ]]; then
    CHAT_LAST_PROMPT_TOKENS=0
    CHAT_LAST_OUTPUT_TOKENS=0
    CHAT_LAST_PAYLOAD_BYTES=0
    CHAT_COMPACTION_REARM_TOKENS=0
    CHAT_LAST_USAGE_MODEL=""
    CHAT_LAST_USAGE_HOST=""
    CHAT_COMPACTION_REARM_MODEL=""
    CHAT_COMPACTION_REARM_HOST=""
  fi

  if [[ "$ZCHAT_CONTEXT_WINDOW" == <4096-> ]]; then
    CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_WINDOW"
    return 0
  fi

  CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_FALLBACK"
  _chat_get_running_context "$SESSION_MODEL" "$OLLAMA_HOST"
  local -i discovery_status=$?
  if (( discovery_status == 0 )); then
    CHAT_CONTEXT_WINDOW="$API_RUNNING_CONTEXT"
  elif (( discovery_status == 130 )); then
    CHAT_COMPACTION_ERROR="Context discovery stopped"
    return 130
  else
    # An unloaded model is absent from /api/ps. Refresh after its first reply.
    CHAT_CONTEXT_DISCOVERY_PENDING=1
  fi
  API_HTTP_ERROR=""
}

chat_context_refresh_after_response() {
  (( CHAT_CONTEXT_DISCOVERY_PENDING )) || return 0
  if _chat_get_running_context "$SESSION_MODEL" "$OLLAMA_HOST"; then
    CHAT_CONTEXT_WINDOW="$API_RUNNING_CONTEXT"
    CHAT_CONTEXT_DISCOVERY_PENDING=0
  fi
  API_HTTP_ERROR=""
}

chat_compaction_limit() {
  local -i limit=$(( CHAT_CONTEXT_WINDOW * ZCHAT_COMPACT_PERCENT / 100 ))
  if [[ "$CHAT_COMPACTION_REARM_MODEL" == "$SESSION_MODEL" && "$CHAT_COMPACTION_REARM_HOST" == "$OLLAMA_HOST" ]] \
    && (( CHAT_COMPACTION_REARM_TOKENS > limit )); then
    limit=$CHAT_COMPACTION_REARM_TOKENS
  fi
  (( limit > CHAT_CONTEXT_WINDOW * 95 / 100 )) && limit=$(( CHAT_CONTEXT_WINDOW * 95 / 100 ))
  REPLY="$limit"
}

chat_compaction_output_limit() {
  local -i window_limit=$(( CHAT_CONTEXT_WINDOW / 10 ))
  (( window_limit < 256 )) && window_limit=256
  (( window_limit > ZCHAT_COMPACT_MAX_TOKENS )) && window_limit=$ZCHAT_COMPACT_MAX_TOKENS
  REPLY="$window_limit"
}

chat_estimate_payload_tokens() {
  local payload="$1"
  local -i bytes estimate
  _api_byte_length "$payload"
  bytes=$REPLY
  if (( CHAT_LAST_PROMPT_TOKENS > 0 && CHAT_LAST_PAYLOAD_BYTES > 0 )) \
    && [[ "$CHAT_LAST_USAGE_MODEL" == "$SESSION_MODEL" && "$CHAT_LAST_USAGE_HOST" == "$OLLAMA_HOST" ]]; then
    estimate=$(( (bytes * CHAT_LAST_PROMPT_TOKENS + CHAT_LAST_PAYLOAD_BYTES - 1) / CHAT_LAST_PAYLOAD_BYTES ))
    estimate=$(( (estimate * 110 + 99) / 100 ))
  else
    # Three bytes per token plus chat-template headroom is conservative for
    # multilingual prose and JSON before Ollama provides a real usage sample.
    estimate=$(( (bytes + 2) / 3 + 512 ))
  fi
  CHAT_ESTIMATED_TOKENS="$estimate"
  REPLY="$estimate"
}

chat_context_options_json() {
  # When an auto-selected model is not loaded yet, let Ollama apply its
  # Modelfile/server default. The fallback remains accounting-only until /api/ps
  # reports the allocation after the first response.
  if [[ "$ZCHAT_CONTEXT_WINDOW" == auto ]] && (( CHAT_CONTEXT_DISCOVERY_PENDING )); then
    REPLY=""
    return 0
  fi
  # Pin a discovered or explicitly requested allocation so accounting agrees.
  REPLY="\"num_ctx\":${CHAT_CONTEXT_WINDOW},"
}

chat_build_compaction_payload() {
  local -i start="${1:-$CHAT_CONTEXT_START_INDEX}" i length remaining raw_user_count=0 ledger_end
  local -i user_budget=$(( CHAT_CONTEXT_WINDOW / 10 ))
  local records="[" comma="" ledger="[" ledger_comma="" source_text="" role_json="" content_json="" message="" record_json=""
  local system_json="" user_json="" model_json="" options=""

  for (( i=start; i<=${#MSG_ROLES}; i++ )); do
    [[ "${MSG_ROLES[i]}" == user || "${MSG_ROLES[i]}" == assistant ]] || continue
    [[ -n "${MSG_CONTENTS[i]}" ]] || continue
    [[ "${MSG_ROLES[i]}" == user ]] && (( raw_user_count++ ))
    if (( ${+parameters[CHAT_COMPACT_RECORD_CACHE]} && ${+CHAT_COMPACT_RECORD_CACHE[$i]} )); then
      record_json="${CHAT_COMPACT_RECORD_CACHE[$i]}"
    else
      json_quote "${MSG_ROLES[i]}"; role_json="$REPLY"
      json_quote "${MSG_CONTENTS[i]}"; content_json="$REPLY"
      record_json="{\"role\":${role_json},\"content\":${content_json}}"
      (( ${+parameters[CHAT_COMPACT_RECORD_CACHE]} )) && CHAT_COMPACT_RECORD_CACHE[$i]="$record_json"
    fi
    records+="${comma}${record_json}"
    comma=","
  done
  records+="]"

  # Preserve a separately bounded ledger of the user's exact wording. This is
  # useful when the raw tail starts after an older request referenced later.
  (( user_budget < 256 )) && user_budget=256
  (( user_budget > ZCHAT_COMPACT_KEEP_USER_TOKENS )) && user_budget=$ZCHAT_COMPACT_KEEP_USER_TOKENS
  remaining=$(( user_budget * 3 ))
  local -a ledger_items=()
  # The raw tail already carries its user messages verbatim. Reserve the exact
  # ledger for older requests instead of paying for the same text twice.
  ledger_end=$(( ${#CHAT_USER_MESSAGES} - raw_user_count ))
  (( ledger_end < 0 )) && ledger_end=0
  for (( i=ledger_end; i>=1 && remaining>0; i-- )); do
    message="${CHAT_USER_MESSAGES[i]}"
    length=${#message}
    if (( length > remaining )); then
      zchat_truncate "$message" "$remaining"
      message="$REPLY"
      remaining=0
    else
      (( remaining -= length ))
    fi
    if (( ${+parameters[CHAT_COMPACT_LEDGER_CACHE]} && ${+CHAT_COMPACT_LEDGER_CACHE[$i]} )) \
      && [[ "$message" == "${CHAT_USER_MESSAGES[i]}" ]]; then
      REPLY="${CHAT_COMPACT_LEDGER_CACHE[$i]}"
    else
      json_quote "$message"
      [[ "$message" == "${CHAT_USER_MESSAGES[i]}" ]] \
        && (( ${+parameters[CHAT_COMPACT_LEDGER_CACHE]} )) \
        && CHAT_COMPACT_LEDGER_CACHE[$i]="$REPLY"
    fi
    ledger_items=("$REPLY" "${ledger_items[@]}")
  done
  for message in "${ledger_items[@]}"; do
    ledger+="${ledger_comma}${message}"
    ledger_comma=","
  done
  ledger+="]"

  [[ -n "$CHAT_COMPACTION_SUMMARY" ]] && source_text=$'Previous checkpoint:\n'"$CHAT_COMPACTION_SUMMARY"$'\n\n'
  source_text+=$'Recent exact user-message ledger, oldest to newest, as JSON:\n'"$ledger"$'\n\nConversation records, oldest to newest, as JSON:\n'"$records"$'\n\n'"$CHAT_COMPACTION_PROMPT"
  json_quote "You create loss-minimizing continuation checkpoints for an ordinary AI chat. Follow the checkpoint instructions exactly."; system_json="$REPLY"
  json_quote "$source_text"; user_json="$REPLY"
  json_quote "$SESSION_MODEL"; model_json="$REPLY"
  chat_context_options_json; options="$REPLY"
  chat_compaction_output_limit
  REPLY="{\"model\":${model_json},\"messages\":[{\"role\":\"system\",\"content\":${system_json}},{\"role\":\"user\",\"content\":${user_json}}],\"stream\":false,\"think\":false,\"options\":{${options}\"num_predict\":${REPLY},\"temperature\":0}}"
}

chat_compaction_replace_history() {
  local summary="$1" message=""
  local -i user_budget=$(( CHAT_CONTEXT_WINDOW / 10 ))
  local -i recent_budget=$(( CHAT_CONTEXT_WINDOW / 6 )) i length remaining start=$(( ${#MSG_ROLES} + 1 ))
  local -a kept_users=()

  (( recent_budget < 256 )) && recent_budget=256
  (( recent_budget > ZCHAT_COMPACT_KEEP_RECENT_TOKENS )) && recent_budget=$ZCHAT_COMPACT_KEEP_RECENT_TOKENS
  remaining=$(( recent_budget * 3 ))
  for (( i=${#MSG_ROLES}; i>=1 && remaining>0; i-- )); do
    [[ "${MSG_ROLES[i]}" == user || "${MSG_ROLES[i]}" == assistant ]] || continue
    [[ -n "${MSG_CONTENTS[i]}" ]] || continue
    message="${MSG_CONTENTS[i]}"
    length=$(( ${#message} + ${#MSG_ROLES[i]} + 32 ))
    (( length <= remaining )) || break
    start=$i
    (( remaining -= length ))
  done
  while (( start <= ${#MSG_ROLES} )) && [[ "${MSG_ROLES[start]}" != user ]]; do
    (( start++ ))
  done

  (( user_budget < 256 )) && user_budget=256
  (( user_budget > ZCHAT_COMPACT_KEEP_USER_TOKENS )) && user_budget=$ZCHAT_COMPACT_KEEP_USER_TOKENS
  remaining=$(( user_budget * 3 ))
  for (( i=${#CHAT_USER_MESSAGES}; i>=1 && remaining>0; i-- )); do
    message="${CHAT_USER_MESSAGES[i]}"
    length=${#message}
    if (( length <= remaining )); then
      kept_users=("$message" "${kept_users[@]}")
      (( remaining -= length ))
    else
      zchat_truncate "$message" "$remaining"
      kept_users=("$REPLY" "${kept_users[@]}")
      remaining=0
    fi
  done

  CHAT_COMPACTION_SUMMARY="$summary"
  CHAT_CONTEXT_START_INDEX="$start"
  CHAT_USER_MESSAGES=("${kept_users[@]}")
  (( $+functions[_state_mark_users_dirty] )) && _state_mark_users_dirty 1
  return 0
}

chat_compact_history() {
  local trigger="${1:-manual}" payload="" best_payload="" response="" summary="" dropped_note="" size_note=""
  local -i start=$CHAT_CONTEXT_START_INDEX original_start=$CHAT_CONTEXT_START_INDEX
  local -i count=${#MSG_ROLES} hard_limit estimate request_status before after
  local -i i low high midpoint candidate best_start
  local -a candidate_starts=()
  # Dynamic local caches are visible to the builder during this one search and
  # disappear afterward. Each message is JSON-escaped at most once even though
  # the binary search evaluates several candidate cutoffs.
  local -A CHAT_COMPACT_RECORD_CACHE=() CHAT_COMPACT_LEDGER_CACHE=()
  CHAT_COMPACTION_ERROR=""
  CHAT_COMPACTION_CANCELLED=0
  (( count > 0 || ${#CHAT_COMPACTION_SUMMARY} > 0 )) || return 2
  (( CHAT_COMPACTION_IN_PROGRESS )) && { CHAT_COMPACTION_ERROR="Compaction is already running"; return 1; }
  CHAT_COMPACTION_IN_PROGRESS=1
  chat_context_configure
  request_status=$?
  if (( request_status != 0 )); then
    (( request_status == 130 )) && CHAT_COMPACTION_CANCELLED=1
    CHAT_COMPACTION_IN_PROGRESS=0
    return "$request_status"
  fi

  state_build_payload
  chat_estimate_payload_tokens "$REPLY"
  before=$REPLY
  hard_limit=$(( CHAT_CONTEXT_WINDOW * 85 / 100 ))

  # A chat checkpoint must begin at a complete user turn. Search only those
  # boundaries, preserving the earliest fitting tail while avoiding one full
  # payload rebuild and JSON-escape pass per discarded exchange.
  while (( start <= count )) && [[ "${MSG_ROLES[start]}" != user ]]; do
    (( start++ ))
  done
  candidate_starts=("$start")
  for (( i=start+1; i<=count; i++ )); do
    [[ "${MSG_ROLES[i]}" == user ]] && candidate_starts+=("$i")
  done
  low=1
  high=${#candidate_starts}
  best_start="${candidate_starts[-1]}"
  while (( low <= high )); do
    midpoint=$(( (low + high) / 2 ))
    candidate="${candidate_starts[midpoint]}"
    chat_build_compaction_payload "$candidate"
    payload="$REPLY"
    chat_estimate_payload_tokens "$payload"
    estimate=$REPLY
    if (( estimate <= hard_limit )); then
      best_start=$candidate
      best_payload="$payload"
      high=$(( midpoint - 1 ))
    else
      low=$(( midpoint + 1 ))
    fi
  done
  start=$best_start
  if [[ -n "$best_payload" ]]; then
    payload="$best_payload"
    chat_estimate_payload_tokens "$payload"
    estimate=$REPLY
  else
    chat_build_compaction_payload "$start"
    payload="$REPLY"
    chat_estimate_payload_tokens "$payload"
    estimate=$REPLY
  fi

  if (( ${UI_ACTIVE:-0} )) && (( $+functions[ui_wait_for_compaction] )); then
    api_async_start POST /api/chat "$payload" "$OLLAMA_HOST" || {
      CHAT_COMPACTION_ERROR="$API_HTTP_ERROR"
      CHAT_COMPACTION_IN_PROGRESS=0
      return 1
    }
    ui_wait_for_compaction
    request_status=$?
    if (( request_status == 130 )); then
      api_async_cancel
      CHAT_COMPACTION_CANCELLED=1
      CHAT_COMPACTION_ERROR="Compaction stopped"
      CHAT_COMPACTION_IN_PROGRESS=0
      return 130
    fi
    api_async_collect
    request_status=$?
  else
    api_chat_sync "$payload" "$OLLAMA_HOST"
    request_status=$?
  fi
  if (( request_status != 0 )); then
    CHAT_COMPACTION_ERROR="${API_HTTP_ERROR:-Compaction request failed}"
    CHAT_COMPACTION_IN_PROGRESS=0
    return "$request_status"
  fi
  response="$API_HTTP_BODY"
  if ! json_parse_ollama_event "$response"; then
    CHAT_COMPACTION_ERROR="Could not parse compaction response: ${JSON_ERROR:-invalid JSON}"
    CHAT_COMPACTION_IN_PROGRESS=0
    return 1
  fi
  if [[ -n "$JSON_MESSAGE_ERROR" ]]; then
    CHAT_COMPACTION_ERROR="$JSON_MESSAGE_ERROR"
    CHAT_COMPACTION_IN_PROGRESS=0
    return 1
  fi
  summary="$JSON_MESSAGE_CONTENT"
  if [[ -z "$summary" ]]; then
    CHAT_COMPACTION_ERROR="Ollama returned an empty compaction checkpoint"
    CHAT_COMPACTION_IN_PROGRESS=0
    return 1
  fi

  chat_compaction_output_limit
  zchat_truncate "$summary" $(( REPLY * 4 ))
  summary="$REPLY"
  chat_compaction_replace_history "$summary"
  (( CHAT_COMPACTION_COUNT++ ))
  CHAT_LAST_PROMPT_TOKENS=0
  CHAT_LAST_OUTPUT_TOKENS=0
  CHAT_LAST_PAYLOAD_BYTES=0
  CHAT_COMPACTION_IN_PROGRESS=0

  state_build_payload
  chat_estimate_payload_tokens "$REPLY"
  after=$REPLY
  CHAT_COMPACTION_REARM_TOKENS=$(( after + CHAT_CONTEXT_WINDOW / 10 ))
  CHAT_COMPACTION_REARM_MODEL="$SESSION_MODEL"
  CHAT_COMPACTION_REARM_HOST="$OLLAMA_HOST"
  (( start > original_start )) && dropped_note="; omitted old detailed records from the checkpoint request to fit the window"
  (( after >= before )) && size_note="; the conversation was already small, so the checkpoint did not reduce its estimated size"
  if ! state_append_message system "♻ Compacted context (${trigger}): approximately ${before} → ${after} tokens; checkpoint ${CHAT_COMPACTION_COUNT}${dropped_note}${size_note}."; then
    CHAT_COMPACTION_ERROR="${STATE_ERROR:-Could not persist the compaction checkpoint}"
    return 1
  fi
  return 0
}

chat_prepare_payload() {
  local payload=""
  local -i estimate limit compact_status
  chat_context_configure || return $?
  state_build_payload
  payload="$REPLY"
  chat_estimate_payload_tokens "$payload"
  estimate=$REPLY
  chat_compaction_limit
  limit=$REPLY
  if (( estimate >= limit && (${#MSG_ROLES} > 0 || ${#CHAT_COMPACTION_SUMMARY} > 0) )); then
    chat_compact_history auto
    compact_status=$?
    (( compact_status == 0 )) || return "$compact_status"
    state_build_payload
    payload="$REPLY"
    chat_estimate_payload_tokens "$payload"
  fi
  REPLY="$payload"
}

chat_record_response_usage() {
  local payload="$1"
  local -i prompt_tokens="${2:-0}" output_tokens="${3:-0}"
  _api_byte_length "$payload"
  CHAT_LAST_PAYLOAD_BYTES="$REPLY"
  CHAT_LAST_PROMPT_TOKENS="$prompt_tokens"
  CHAT_LAST_OUTPUT_TOKENS="$output_tokens"
  CHAT_LAST_USAGE_MODEL="$SESSION_MODEL"
  CHAT_LAST_USAGE_HOST="$OLLAMA_HOST"
  chat_context_refresh_after_response
}

chat_context_summary() {
  local last_prompt="unknown" context_status=""
  local -i estimate limit
  chat_context_configure
  state_build_payload
  chat_estimate_payload_tokens "$REPLY"
  estimate=$REPLY
  chat_compaction_limit
  limit=$REPLY
  (( CHAT_LAST_PROMPT_TOKENS > 0 )) && last_prompt="$CHAT_LAST_PROMPT_TOKENS"
  if [[ "$ZCHAT_CONTEXT_WINDOW" == <4096-> ]]; then
    context_status="explicit setting"
  elif (( CHAT_CONTEXT_DISCOVERY_PENDING )); then
    context_status="provisional accounting fallback; first request unpinned"
  else
    context_status="active Ollama allocation"
  fi
  REPLY="Context: ${CHAT_CONTEXT_WINDOW} tokens (${context_status}); estimated next prompt: ${estimate} tokens; automatic compaction near ${limit} tokens (${ZCHAT_COMPACT_PERCENT}%); checkpoints: ${CHAT_COMPACTION_COUNT}; last Ollama prompt: ${last_prompt}."
}
