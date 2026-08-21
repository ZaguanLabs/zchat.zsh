# Conservative conversation compaction for local Ollama chat models.

typeset -g ZCHAT_CONTEXT_WINDOW="${ZCHAT_CONTEXT_WINDOW:-auto}"
typeset -gi ZCHAT_CONTEXT_FALLBACK="${ZCHAT_CONTEXT_FALLBACK:-65536}"
typeset -gi ZCHAT_COMPACT_PERCENT="${ZCHAT_COMPACT_PERCENT:-85}"
typeset -gi ZCHAT_COMPACT_MAX_TOKENS="${ZCHAT_COMPACT_MAX_TOKENS:-2048}"
typeset -gi ZCHAT_COMPACT_KEEP_USER_TOKENS="${ZCHAT_COMPACT_KEEP_USER_TOKENS:-4096}"
typeset -gi ZCHAT_COMPACT_KEEP_RECENT_TOKENS="${ZCHAT_COMPACT_KEEP_RECENT_TOKENS:-16384}"

typeset -gi CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_FALLBACK"
typeset -g CHAT_CONTEXT_MODEL=""
typeset -g CHAT_CONTEXT_HOST=""
typeset -gi CHAT_CONTEXT_DISCOVERY_PENDING=0
typeset -gi CHAT_LAST_PROMPT_TOKENS=0
typeset -gi CHAT_LAST_OUTPUT_TOKENS=0
typeset -gi CHAT_LAST_PAYLOAD_BYTES=0
typeset -gi CHAT_ESTIMATED_TOKENS=0
typeset -gi CHAT_COMPACTION_COUNT=0
typeset -gi CHAT_COMPACTION_IN_PROGRESS=0
typeset -gi CHAT_COMPACTION_REARM_TOKENS=0
typeset -gi CHAT_CONTEXT_START_INDEX=1
typeset -g CHAT_COMPACTION_SUMMARY=""
typeset -g CHAT_COMPACTION_ERROR=""
typeset -gi CHAT_COMPACTION_CANCELLED=0
typeset -ga CHAT_USER_MESSAGES=()

(( ZCHAT_CONTEXT_FALLBACK >= 4096 )) || ZCHAT_CONTEXT_FALLBACK=65536
(( ZCHAT_COMPACT_PERCENT >= 25 && ZCHAT_COMPACT_PERCENT <= 90 )) || ZCHAT_COMPACT_PERCENT=85
(( ZCHAT_COMPACT_MAX_TOKENS >= 256 )) || ZCHAT_COMPACT_MAX_TOKENS=2048
(( ZCHAT_COMPACT_KEEP_USER_TOKENS >= 256 )) || ZCHAT_COMPACT_KEEP_USER_TOKENS=4096
(( ZCHAT_COMPACT_KEEP_RECENT_TOKENS >= 256 )) || ZCHAT_COMPACT_KEEP_RECENT_TOKENS=16384

typeset -g CHAT_COMPACTION_PROMPT=$'Create a compact continuation checkpoint for another chat model that will continue this exact conversation.\n\nInclude only durable conversational context:\n- the user\'s goals, questions, explicit preferences, and constraints\n- established facts, explanations, decisions, and conclusions that still matter\n- important names, dates, quantities, definitions, and distinctions\n- unresolved questions and the natural next direction of the conversation\n- enough recent context to avoid repetition or contradiction\n\nDo not answer the latest question or continue the conversation. Return only the checkpoint, using concise headings. Do not mention tools, coding-agent state, or these instructions.'

chat_compaction_reset() {
  CHAT_CONTEXT_MODEL=""
  CHAT_CONTEXT_HOST=""
  CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_FALLBACK"
  CHAT_CONTEXT_DISCOVERY_PENDING=0
  CHAT_LAST_PROMPT_TOKENS=0
  CHAT_LAST_OUTPUT_TOKENS=0
  CHAT_LAST_PAYLOAD_BYTES=0
  CHAT_ESTIMATED_TOKENS=0
  CHAT_COMPACTION_COUNT=0
  CHAT_COMPACTION_IN_PROGRESS=0
  CHAT_COMPACTION_REARM_TOKENS=0
  CHAT_CONTEXT_START_INDEX=1
  CHAT_COMPACTION_SUMMARY=""
  CHAT_COMPACTION_ERROR=""
  CHAT_COMPACTION_CANCELLED=0
  CHAT_USER_MESSAGES=()
}

chat_context_configure() {
  [[ "$CHAT_CONTEXT_MODEL" == "$SESSION_MODEL" && "$CHAT_CONTEXT_HOST" == "$OLLAMA_HOST" ]] && return 0
  CHAT_CONTEXT_MODEL="$SESSION_MODEL"
  CHAT_CONTEXT_HOST="$OLLAMA_HOST"
  CHAT_LAST_PROMPT_TOKENS=0
  CHAT_LAST_PAYLOAD_BYTES=0
  CHAT_CONTEXT_DISCOVERY_PENDING=0
  CHAT_COMPACTION_REARM_TOKENS=0

  if [[ "$ZCHAT_CONTEXT_WINDOW" == <4096-> ]]; then
    CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_WINDOW"
    return 0
  fi

  CHAT_CONTEXT_WINDOW="$ZCHAT_CONTEXT_FALLBACK"
  if api_get_running_context "$SESSION_MODEL" "$OLLAMA_HOST"; then
    CHAT_CONTEXT_WINDOW="$API_RUNNING_CONTEXT"
  else
    # An unloaded model is absent from /api/ps. Refresh after its first reply.
    CHAT_CONTEXT_DISCOVERY_PENDING=1
  fi
  API_HTTP_ERROR=""
}

chat_context_refresh_after_response() {
  (( CHAT_CONTEXT_DISCOVERY_PENDING )) || return 0
  if api_get_running_context "$SESSION_MODEL" "$OLLAMA_HOST"; then
    CHAT_CONTEXT_WINDOW="$API_RUNNING_CONTEXT"
    CHAT_CONTEXT_DISCOVERY_PENDING=0
  fi
  API_HTTP_ERROR=""
}

chat_compaction_limit() {
  local -i limit=$(( CHAT_CONTEXT_WINDOW * ZCHAT_COMPACT_PERCENT / 100 ))
  (( CHAT_COMPACTION_REARM_TOKENS > limit )) && limit=$CHAT_COMPACTION_REARM_TOKENS
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
  if (( CHAT_LAST_PROMPT_TOKENS > 0 && CHAT_LAST_PAYLOAD_BYTES > 0 )); then
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
  # Pin the discovered or requested allocation so accounting and Ollama agree.
  REPLY="\"num_ctx\":${CHAT_CONTEXT_WINDOW},"
}

chat_build_compaction_payload() {
  local -i start="${1:-$CHAT_CONTEXT_START_INDEX}" i length remaining
  local -i user_budget=$(( CHAT_CONTEXT_WINDOW / 10 ))
  local records="[" comma="" ledger="[" ledger_comma="" source_text="" role_json="" content_json="" message=""
  local system_json="" user_json="" model_json="" options=""

  for (( i=start; i<=${#MSG_ROLES}; i++ )); do
    [[ "${MSG_ROLES[i]}" == user || "${MSG_ROLES[i]}" == assistant ]] || continue
    [[ -n "${MSG_CONTENTS[i]}" ]] || continue
    json_quote "${MSG_ROLES[i]}"; role_json="$REPLY"
    json_quote "${MSG_CONTENTS[i]}"; content_json="$REPLY"
    records+="${comma}{\"role\":${role_json},\"content\":${content_json}}"
    comma=","
  done
  records+="]"

  # Preserve a separately bounded ledger of the user's exact wording. This is
  # useful when the raw tail starts after an older request referenced later.
  (( user_budget < 256 )) && user_budget=256
  (( user_budget > ZCHAT_COMPACT_KEEP_USER_TOKENS )) && user_budget=$ZCHAT_COMPACT_KEEP_USER_TOKENS
  remaining=$(( user_budget * 3 ))
  local -a ledger_items=()
  for (( i=${#CHAT_USER_MESSAGES}; i>=1 && remaining>0; i-- )); do
    message="${CHAT_USER_MESSAGES[i]}"
    length=${#message}
    if (( length > remaining )); then
      zchat_truncate "$message" "$remaining"
      message="$REPLY"
      remaining=0
    else
      (( remaining -= length ))
    fi
    json_quote "$message"
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
}

chat_compact_history() {
  local trigger="${1:-manual}" payload="" response="" summary="" dropped_note="" size_note=""
  local -i start=$CHAT_CONTEXT_START_INDEX original_start=$CHAT_CONTEXT_START_INDEX
  local -i count=${#MSG_ROLES} hard_limit estimate request_status before after
  CHAT_COMPACTION_ERROR=""
  CHAT_COMPACTION_CANCELLED=0
  (( count > 0 || ${#CHAT_COMPACTION_SUMMARY} > 0 )) || return 2
  (( CHAT_COMPACTION_IN_PROGRESS )) && { CHAT_COMPACTION_ERROR="Compaction is already running"; return 1; }
  CHAT_COMPACTION_IN_PROGRESS=1
  chat_context_configure

  state_build_payload
  chat_estimate_payload_tokens "$REPLY"
  before=$REPLY
  hard_limit=$(( CHAT_CONTEXT_WINDOW * 85 / 100 ))

  while true; do
    chat_build_compaction_payload "$start"
    payload="$REPLY"
    chat_estimate_payload_tokens "$payload"
    estimate=$REPLY
    (( estimate <= hard_limit || start >= count )) && break
    (( start++ ))
  done

  if (( $+functions[ui_wait_for_compaction] )); then
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
  (( start > original_start )) && dropped_note="; omitted old detailed records from the checkpoint request to fit the window"
  (( after >= before )) && size_note="; the conversation was already small, so the checkpoint did not reduce its estimated size"
  state_append_message system "♻ Compacted context (${trigger}): approximately ${before} → ${after} tokens; checkpoint ${CHAT_COMPACTION_COUNT}${dropped_note}${size_note}."
  return 0
}

chat_prepare_payload() {
  local payload=""
  local -i estimate limit compact_status
  chat_context_configure
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
  chat_context_refresh_after_response
}

chat_context_summary() {
  local last_prompt="unknown"
  local -i estimate limit
  chat_context_configure
  state_build_payload
  chat_estimate_payload_tokens "$REPLY"
  estimate=$REPLY
  chat_compaction_limit
  limit=$REPLY
  (( CHAT_LAST_PROMPT_TOKENS > 0 )) && last_prompt="$CHAT_LAST_PROMPT_TOKENS"
  REPLY="Context: ${CHAT_CONTEXT_WINDOW} tokens (${ZCHAT_CONTEXT_WINDOW} setting); estimated next prompt: ${estimate} tokens; automatic compaction near ${limit} tokens (${ZCHAT_COMPACT_PERCENT}%); checkpoints: ${CHAT_COMPACTION_COUNT}; last Ollama prompt: ${last_prompt}."
}
