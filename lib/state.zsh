# lib/state.zsh - State and Session Management for zchat

typeset -g ZCHAT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zchat"
typeset -g ZCHAT_SESSIONS_DIR="${ZCHAT_CONFIG_DIR}/sessions"
typeset -g ZCHAT_CONFIG_FILE="${ZCHAT_CONFIG_DIR}/config.json"

# Active session variables
typeset -g CURRENT_SESSION_ID=""
typeset -g SESSION_TITLE="New Chat"
typeset -g SESSION_MODEL="gemma4:12b"
typeset -g SESSION_SYSTEM_PROMPT="You are a helpful, knowledgeable, and concise AI assistant."
typeset -g SESSION_TEMPERATURE=0.7

# Messages arrays (parallel indexed)
typeset -ga MSG_ROLES=()
typeset -ga MSG_CONTENTS=()
typeset -ga MSG_THINKINGS=()
typeset -ga MSG_THINKING_EXPANDED=()
typeset -ga MSG_TIMES=()

# Available sessions cache
typeset -ga SESSION_IDS=()
typeset -ga SESSION_TITLES=()
typeset -ga SESSION_MODELS=()

# Initialize configuration directories and load initial session
state_init() {
  zf_mkdir -p "$ZCHAT_SESSIONS_DIR" 2>/dev/null

  if [[ -f "$ZCHAT_CONFIG_FILE" ]]; then
    if json_parse_config "${mapfile[$ZCHAT_CONFIG_FILE]}"; then
      if (( ! ZCHAT_HOST_OVERRIDE )) && [[ -n "${JSON_CONFIG[host]:-}" ]]; then
        if api_normalize_host "${JSON_CONFIG[host]}"; then
          OLLAMA_HOST="$REPLY"
        fi
      fi
      if (( ! ZCHAT_MODEL_OVERRIDE )) && [[ -n "${JSON_CONFIG[default_model]:-}" ]]; then
        SESSION_MODEL="${JSON_CONFIG[default_model]}"
      fi
      [[ -n "${JSON_CONFIG[system_prompt]:-}" ]] && SESSION_SYSTEM_PROMPT="${JSON_CONFIG[system_prompt]}"
      [[ -n "${JSON_CONFIG[temperature]:-}" ]] && SESSION_TEMPERATURE="${JSON_CONFIG[temperature]}"
    fi
  else
    _state_write_config
  fi

  state_migrate_legacy_sessions
  state_refresh_sessions_list

  # If there are existing sessions, load the latest one, otherwise create a new one
  if (( ${#SESSION_IDS} > 0 )); then
    state_load_session "${SESSION_IDS[1]}"
  else
    state_new_session "$SESSION_MODEL" "$SESSION_SYSTEM_PROMPT"
  fi
  if (( ZCHAT_MODEL_OVERRIDE )) && [[ -n "$ZCHAT_REQUESTED_MODEL" ]]; then
    SESSION_MODEL="$ZCHAT_REQUESTED_MODEL"
  fi
}

_state_write_config() {
  local host_json model_json system_json
  json_quote "$OLLAMA_HOST"; host_json="$REPLY"
  json_quote "$SESSION_MODEL"; model_json="$REPLY"
  json_quote "$SESSION_SYSTEM_PROMPT"; system_json="$REPLY"
  mapfile[$ZCHAT_CONFIG_FILE]=$'{\n  "host": '"$host_json"$',\n  "default_model": '"$model_json"$',\n  "temperature": '"$SESSION_TEMPERATURE"$',\n  "system_prompt": '"$system_json"$'\n}\n'
}

# Convert legacy JSON sessions once, retaining the originals as backups.
state_migrate_legacy_sessions() {
  local legacy id
  for legacy in "${ZCHAT_SESSIONS_DIR}"/*.json(N); do
    id="${legacy:t:r}"
    [[ -d "${ZCHAT_SESSIONS_DIR}/${id}.session" ]] && continue
    json_parse_session "${mapfile[$legacy]}" || continue

    CURRENT_SESSION_ID="${JSON_SESSION_ID:-$id}"
    SESSION_TITLE="${JSON_SESSION_TITLE:-New Chat}"
    SESSION_MODEL="${JSON_SESSION_MODEL:-$SESSION_MODEL}"
    SESSION_SYSTEM_PROMPT="$JSON_SESSION_SYSTEM"
    SESSION_TEMPERATURE="${JSON_SESSION_TEMPERATURE:-0.7}"
    MSG_ROLES=("${JSON_SESSION_ROLES[@]}")
    MSG_CONTENTS=("${JSON_SESSION_CONTENTS[@]}")
    MSG_THINKINGS=("${JSON_SESSION_THINKINGS[@]}")
    MSG_THINKING_EXPANDED=("${JSON_SESSION_EXPANDED[@]}")
    MSG_TIMES=("${JSON_SESSION_TIMES[@]}")
    state_save_session
  done
}

# Scan session directory and populate cache
state_refresh_sessions_list() {
  SESSION_IDS=()
  SESSION_TITLES=()
  SESSION_MODELS=()

  local s_file s_id s_title s_model
  # Session IDs begin with their creation timestamp. Sort filenames in reverse
  # order so the newest chat is always shown first in the sidebar.
  for s_file in "${ZCHAT_SESSIONS_DIR}"/*.session(N/On); do
    s_id="${s_file:t:r}"
    s_title="${mapfile[$s_file/title]:-Untitled}"
    s_model="${mapfile[$s_file/model]:-unknown}"

    SESSION_IDS+=("$s_id")
    SESSION_TITLES+=("${s_title[1,20]}")
    SESSION_MODELS+=("$s_model")
  done
}

# Start a new chat session
state_new_session() {
  local model="${1:-$SESSION_MODEL}"
  local sys="${2:-$SESSION_SYSTEM_PROMPT}"

  CURRENT_SESSION_ID="${EPOCHSECONDS}_$RANDOM"
  SESSION_TITLE="New Chat"
  SESSION_MODEL="$model"
  SESSION_SYSTEM_PROMPT="$sys"
  SESSION_TEMPERATURE=0.7

  MSG_ROLES=()
  MSG_CONTENTS=()
  MSG_THINKINGS=()
  MSG_THINKING_EXPANDED=()
  MSG_TIMES=()
  chat_compaction_reset

  state_save_session
  state_refresh_sessions_list
}

# Save the current session using raw, directory-backed fields. No parsing or
# escaping is required, and zsh/mapfile performs all file I/O in-process.
state_save_session() {
  [[ -z "$CURRENT_SESSION_ID" ]] && return

  local session_dir="${ZCHAT_SESSIONS_DIR}/${CURRENT_SESSION_ID}.session"
  local messages_dir="${session_dir}/messages"
  local users_dir="${session_dir}/context_users"
  local seq prefix
  local -i i count=${#MSG_ROLES}
  zf_mkdir -p "$messages_dir" "$users_dir" 2>/dev/null || return 1

  mapfile[$session_dir/id]="$CURRENT_SESSION_ID"
  mapfile[$session_dir/title]="$SESSION_TITLE"
  mapfile[$session_dir/model]="$SESSION_MODEL"
  mapfile[$session_dir/system_prompt]="$SESSION_SYSTEM_PROMPT"
  mapfile[$session_dir/temperature]="$SESSION_TEMPERATURE"
  mapfile[$session_dir/updated_at]="$EPOCHSECONDS"
  mapfile[$session_dir/message_count]="$count"
  mapfile[$session_dir/compaction_summary]="$CHAT_COMPACTION_SUMMARY"
  mapfile[$session_dir/compaction_count]="$CHAT_COMPACTION_COUNT"
  mapfile[$session_dir/context_start_index]="$CHAT_CONTEXT_START_INDEX"
  mapfile[$session_dir/context_user_count]="${#CHAT_USER_MESSAGES}"

  for (( i=1; i<=count; i++ )); do
    printf -v seq '%06d' "$i"
    prefix="$messages_dir/$seq"
    mapfile[$prefix.role]="${MSG_ROLES[i]:-user}"
    mapfile[$prefix.content]="${MSG_CONTENTS[i]:-}"
    mapfile[$prefix.thinking]="${MSG_THINKINGS[i]:-}"
    mapfile[$prefix.expanded]="${MSG_THINKING_EXPANDED[i]:-0}"
    mapfile[$prefix.time]="${MSG_TIMES[i]:-}"
  done

  for (( i=1; i<=${#CHAT_USER_MESSAGES}; i++ )); do
    printf -v seq '%06d' "$i"
    mapfile[$users_dir/$seq]="${CHAT_USER_MESSAGES[i]}"
  done
}

# Load a session by ID
state_load_session() {
  local id="$1"
  local session_dir="${ZCHAT_SESSIONS_DIR}/${id}.session"
  [[ -d "$session_dir" ]] || return 1

  CURRENT_SESSION_ID="$id"
  SESSION_TITLE="${mapfile[$session_dir/title]:-Untitled}"
  SESSION_MODEL="${mapfile[$session_dir/model]:-gemma4:12b}"
  SESSION_SYSTEM_PROMPT="${mapfile[$session_dir/system_prompt]}"
  SESSION_TEMPERATURE="${mapfile[$session_dir/temperature]:-0.7}"
  chat_compaction_reset

  MSG_ROLES=()
  MSG_CONTENTS=()
  MSG_THINKINGS=()
  MSG_THINKING_EXPANDED=()
  MSG_TIMES=()

  local -i len=${mapfile[$session_dir/message_count]:-0} i
  local seq prefix
  for (( i=1; i<=len; i++ )); do
    printf -v seq '%06d' "$i"
    prefix="$session_dir/messages/$seq"
    MSG_ROLES+=("${mapfile[$prefix.role]:-user}")
    MSG_CONTENTS+=("${mapfile[$prefix.content]}")
    MSG_THINKINGS+=("${mapfile[$prefix.thinking]}")
    MSG_THINKING_EXPANDED+=("${mapfile[$prefix.expanded]:-0}")
    MSG_TIMES+=("${mapfile[$prefix.time]}")
  done
  CHAT_COMPACTION_SUMMARY="${mapfile[$session_dir/compaction_summary]}"
  CHAT_COMPACTION_COUNT="${mapfile[$session_dir/compaction_count]:-0}"
  CHAT_CONTEXT_START_INDEX="${mapfile[$session_dir/context_start_index]:-1}"
  [[ "$CHAT_COMPACTION_COUNT" == <0-> ]] || CHAT_COMPACTION_COUNT=0
  [[ "$CHAT_CONTEXT_START_INDEX" == <1-> ]] || CHAT_CONTEXT_START_INDEX=1
  (( CHAT_CONTEXT_START_INDEX <= len + 1 )) || CHAT_CONTEXT_START_INDEX=1

  local -i user_count="${mapfile[$session_dir/context_user_count]:-0}"
  [[ "$user_count" == <0-> ]] || user_count=0
  if (( user_count > 0 )); then
    for (( i=1; i<=user_count; i++ )); do
      printf -v seq '%06d' "$i"
      CHAT_USER_MESSAGES+=("${mapfile[$session_dir/context_users/$seq]}")
    done
  else
    for (( i=1; i<=len; i++ )); do
      [[ "${MSG_ROLES[i]}" == user ]] && CHAT_USER_MESSAGES+=("${MSG_CONTENTS[i]}")
    done
  fi
}

# Delete a session
state_delete_session() {
  local id="$1"
  zf_rm -rf "${ZCHAT_SESSIONS_DIR}/${id}.session" 2>/dev/null
  zf_rm -f "${ZCHAT_SESSIONS_DIR}/${id}.json" 2>/dev/null
  state_refresh_sessions_list

  if [[ "$CURRENT_SESSION_ID" == "$id" ]]; then
    if (( ${#SESSION_IDS} > 0 )); then
      state_load_session "${SESSION_IDS[1]}"
    else
      state_new_session
    fi
  fi
}

# Append a message to current session
state_append_message() {
  local role="$1"
  local content="$2"
  local thinking="${3:-}"
  local thinking_expanded="${4:-0}"
  local time_str="${5:-}"
  if [[ -z "$time_str" ]]; then
    zchat_time
    time_str="$REPLY"
  fi

  MSG_ROLES+=("$role")
  MSG_CONTENTS+=("$content")
  MSG_THINKINGS+=("$thinking")
  MSG_THINKING_EXPANDED+=("$thinking_expanded")
  MSG_TIMES+=("$time_str")
  [[ "$role" == user ]] && CHAT_USER_MESSAGES+=("$content")

  # Auto-generate title from first user message if still "New Chat"
  if [[ "$role" == "user" && "$SESSION_TITLE" == "New Chat" ]]; then
    local clean_title="${content[1,22]}"
    clean_title="${clean_title//$'\n'/ }"
    SESSION_TITLE="$clean_title"
  fi

  state_save_session
  state_refresh_sessions_list
}

# Fast in-memory update during streaming (no disk write)
state_update_streaming_message() {
  local content="$1"
  local thinking="${2:-}"
  local count=${#MSG_ROLES}

  if (( count > 0 )) && [[ "${MSG_ROLES[count]}" == "assistant" ]]; then
    MSG_CONTENTS[count]="$content"
    MSG_THINKINGS[count]="$thinking"
  else
    MSG_ROLES+=("assistant")
    MSG_CONTENTS+=("$content")
    MSG_THINKINGS+=("$thinking")
    MSG_THINKING_EXPANDED+=(0)
    zchat_time
    MSG_TIMES+=("$REPLY")
  fi
}

# Update or append the last assistant message and save session to disk
state_set_last_assistant_message() {
  local content="$1"
  local thinking="${2:-}"
  local count=${#MSG_ROLES}

  if (( count > 0 )) && [[ "${MSG_ROLES[count]}" == "assistant" ]]; then
    MSG_CONTENTS[count]="$content"
    MSG_THINKINGS[count]="$thinking"
  else
    MSG_ROLES+=("assistant")
    MSG_CONTENTS+=("$content")
    MSG_THINKINGS+=("$thinking")
    MSG_THINKING_EXPANDED+=(0)
    zchat_time
    MSG_TIMES+=("$REPLY")
  fi

  state_save_session
}

# Toggle reasoning expansion on the latest assistant message with reasoning
state_toggle_last_reasoning() {
  local count=${#MSG_ROLES}
  local i
  for (( i=count; i>=1; i-- )); do
    if [[ "${MSG_ROLES[i]}" == "assistant" && -n "${MSG_THINKINGS[i]}" ]]; then
      if (( ${MSG_THINKING_EXPANDED[i]:-0} == 1 )); then
        MSG_THINKING_EXPANDED[i]=0
      else
        MSG_THINKING_EXPANDED[i]=1
      fi
      state_save_session
      return 0
    fi
  done
  return 1
}

# Build the bounded model payload. The complete MSG_* transcript remains intact
# for rendering and persistence after older model context has been compacted.
state_build_payload() {
  local -i count=${#MSG_ROLES} i
  local payload="" model_json="" role_json="" content_json="" system_prompt="$SESSION_SYSTEM_PROMPT"
  local temperature="$SESSION_TEMPERATURE"
  local comma="" options=""

  [[ "$temperature" =~ '^-?[0-9]+([.][0-9]+)?$' ]] || temperature="0.7"
  if [[ -n "$CHAT_COMPACTION_SUMMARY" ]]; then
    [[ -n "$system_prompt" ]] && system_prompt+=$'\n\n'
    system_prompt+=$'<compacted_context>\n'"$CHAT_COMPACTION_SUMMARY"$'\n</compacted_context>'
  fi
  json_quote "$SESSION_MODEL"; model_json="$REPLY"
  payload="{\"model\":${model_json},\"messages\":["

  if [[ -n "$system_prompt" ]]; then
    json_quote "$system_prompt"; content_json="$REPLY"
    payload+="{\"role\":\"system\",\"content\":${content_json}}"
    comma=","
  fi

  for (( i=CHAT_CONTEXT_START_INDEX; i<=count; i++ )); do
    [[ "${MSG_ROLES[i]}" == user || "${MSG_ROLES[i]}" == assistant ]] || continue
    [[ -n "${MSG_CONTENTS[i]}" ]] || continue
    json_quote "${MSG_ROLES[i]}"; role_json="$REPLY"
    json_quote "${MSG_CONTENTS[i]}"; content_json="$REPLY"
    payload+="${comma}{\"role\":${role_json},\"content\":${content_json}}"
    comma=","
  done

  chat_context_options_json
  options="$REPLY"
  REPLY="${payload}],\"options\":{${options}\"temperature\":${temperature}},\"stream\":true}"
}
