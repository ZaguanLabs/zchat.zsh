#!/usr/bin/env zsh

setopt EXTENDED_GLOB NO_NOMATCH
zmodload zsh/datetime zsh/files zsh/mapfile zsh/net/tcp zsh/stat zsh/system || exit 1

typeset -gr TEST_DIR="${0:A:h}"
typeset -gr PROJECT_DIR="${TEST_DIR:h}"
typeset -gr TEST_STATE_DIR="${TMPDIR:-/tmp}/zchat-tests-$$"
typeset -gi TESTS=0
typeset -gi FAILURES=0

cleanup_tests() {
  zf_rm -rf -- "$TEST_STATE_DIR" 2>/dev/null
}
trap cleanup_tests EXIT INT TERM HUP

pass() {
  (( TESTS++ ))
  print -r -- "ok ${TESTS} - $1"
}

fail() {
  (( TESTS++ ))
  (( FAILURES++ ))
  print -r -- "not ok ${TESTS} - $1"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] && pass "$label" || {
    fail "$label"
    print -r -- "  expected: ${(qqq)expected}"
    print -r -- "  actual:   ${(qqq)actual}"
  }
}

assert_contains() {
  local value="$1" expected="$2" label="$3"
  [[ "$value" == *"$expected"* ]] && pass "$label" || fail "$label"
}

assert_not_contains() {
  local value="$1" unexpected="$2" label="$3"
  [[ "$value" != *"$unexpected"* ]] && pass "$label" || fail "$label"
}

typeset -g ZCHAT_DEFAULT_OLLAMA_HOST="localhost:11434"
typeset -g ZCHAT_HOST_OVERRIDE=0
typeset -g ZCHAT_MODEL_OVERRIDE=0
typeset -g ZCHAT_REQUESTED_MODEL=""

source "${PROJECT_DIR}/lib/util.zsh"
source "${PROJECT_DIR}/lib/json.zsh"
source "${PROJECT_DIR}/lib/api.zsh"
source "${PROJECT_DIR}/lib/state.zsh"
source "${PROJECT_DIR}/lib/compact.zsh"
source "${PROJECT_DIR}/lib/input.zsh"

ZCHAT_CONFIG_DIR="$TEST_STATE_DIR"
ZCHAT_SESSIONS_DIR="${TEST_STATE_DIR}/sessions"
ZCHAT_CONFIG_FILE="${TEST_STATE_DIR}/config.json"
zf_mkdir -p "$ZCHAT_SESSIONS_DIR" || exit 1

input_reset
input_layout 20 4
assert_eq "1" "${#INPUT_VISUAL_LINES}" "empty prompt occupies one visual row"

input_insert $'hello\nworld'
input_layout 20 4
assert_eq "2" "${#INPUT_VISUAL_LINES}" "hard newline creates another prompt row"
assert_eq "hello" "${INPUT_VISUAL_LINES[1]}" "multiline layout preserves the first line"
assert_eq "world" "${INPUT_VISUAL_LINES[2]}" "multiline layout preserves the second line"
assert_eq "2" "$INPUT_CURSOR_ROW" "cursor follows inserted text onto the second line"
assert_eq "5" "$INPUT_CURSOR_COL" "cursor column is relative to its visual line"

input_clear
input_insert "abcdefghij"
input_layout 4 4
assert_eq "3" "${#INPUT_VISUAL_LINES}" "long prompt input wraps at editor width"

input_clear
input_insert $'one\ntwo\nthree\nfour\nfive'
input_layout 20 4
assert_eq "4" "$INPUT_VISIBLE_ROWS" "multiline prompt viewport is capped at four rows"
assert_eq "2" "$INPUT_VIEW_TOP" "multiline prompt viewport follows the cursor"
if input_move_vertical -1 20 4; then pass "up moves inside a multiline prompt"; else fail "up moves inside a multiline prompt"; fi
assert_eq "18" "$INPUT_POS" "vertical movement preserves the preferred column"
input_move_vertical 1 20 4
assert_eq "23" "$INPUT_POS" "down returns to the following prompt line"

input_reset
typeset input_sequence=$'\e[13;2u' input_byte=""
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "newline" "$INPUT_EVENT_ACTION" "CSI-u Shift-Return inserts a newline"
input_reset
input_sequence=$'\e[27;2;13~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "newline" "$INPUT_EVENT_ACTION" "modifyOtherKeys Shift-Return inserts a newline"
input_reset
input_decode_terminal_event $'\e' ""
input_decode_terminal_event $'\n' ""
assert_eq "newline" "$INPUT_EVENT_ACTION" "Alt-Return is a multiline fallback"

input_reset
input_sequence=$'\e[200~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "paste" "$INPUT_TERM_STATE" "bracketed paste start enters paste mode"
input_sequence=$'alpha\r\nbeta\e[201~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ""; done
assert_eq "paste" "$INPUT_EVENT_ACTION" "bracketed paste produces one editor event"
assert_eq $'alpha\nbeta' "$INPUT_EVENT_TEXT" "multiline paste preserves and normalizes formatting"

INPUT_HISTORY=("earlier prompt")
INPUT_BUF="draft prompt"
INPUT_POS=${#INPUT_BUF}
input_history_previous
input_history_next
assert_eq "draft prompt" "$INPUT_BUF" "history navigation restores the unfinished draft"

json_parse_ollama_event '{"message":{"content":"done"},"done":true,"prompt_eval_count":321,"eval_count":22}'
assert_eq "done" "$JSON_MESSAGE_CONTENT" "Ollama content is decoded"
assert_eq "321" "$JSON_MESSAGE_PROMPT_TOKENS" "Ollama prompt usage is decoded"
assert_eq "22" "$JSON_MESSAGE_OUTPUT_TOKENS" "Ollama output usage is decoded"
json_parse_ollama_event '{"message":{"content":"done"},"done":true,"prompt_eval_count":999999999999999999999}'
assert_eq "0" "$JSON_MESSAGE_PROMPT_TOKENS" "oversized JSON usage counters are ignored safely"

typeset unsafe_terminal=$'safe\e]52;c;YXR0YWNr\a\rback\b\nnext\tcolumn'
zchat_terminal_safe "$unsafe_terminal" 1
assert_not_contains "$REPLY" $'\e' "terminal sanitizer removes escape controls"
assert_not_contains "$REPLY" $'\a' "terminal sanitizer removes bell controls"
assert_not_contains "$REPLY" $'\r' "terminal sanitizer removes carriage returns"
assert_not_contains "$REPLY" $'\b' "terminal sanitizer removes backspaces"
assert_contains "$REPLY" $'\nnext' "terminal sanitizer preserves transcript newlines"

typeset invalid_json=$'{"message":{"content":"unsafe\e"},"done":true}'
if json_parse_ollama_event "$invalid_json"; then fail "JSON rejects unescaped controls"; else pass "JSON rejects unescaped controls"; fi
if json_parse_ollama_event '{"message":{"content":"x"},"done":true} trailing'; then fail "JSON rejects trailing data"; else pass "JSON rejects trailing data"; fi
if json_parse_ollama_event '{"message":{"content":"x"},"done":true,"eval_count":01}'; then fail "JSON rejects malformed numbers"; else pass "JSON rejects malformed numbers"; fi
typeset nested_json='{"ignored":'
repeat 66; do nested_json+='['; done
nested_json+='0'
repeat 66; do nested_json+=']'; done
nested_json+='}'
if json_parse_ollama_event "$nested_json"; then fail "JSON nesting is bounded"; else pass "JSON nesting is bounded"; fi

api_normalize_host "localhost:65535"
assert_eq "localhost:65535" "$REPLY" "host validation accepts the maximum TCP port"
if api_normalize_host "localhost:65536"; then fail "host validation rejects oversized ports"; else pass "host validation rejects oversized ports"; fi
if api_normalize_host $'localhost:11434\r\nInjected: yes'; then fail "host validation rejects header controls"; else pass "host validation rejects header controls"; fi

typeset event_dir="${TEST_STATE_DIR}/events"
zf_mkdir -p "$event_dir"
exec {event_tfd}>"${event_dir}/thinking" {event_cfd}>"${event_dir}/content" \
  {event_efd}>"${event_dir}/error" {event_ufd}>"${event_dir}/usage"
API_NDJSON_BUFFER=""
if _api_consume_ndjson $'not-json\n' "$event_tfd" "$event_cfd" "$event_efd" "$event_ufd"; then
  fail "malformed stream events fail the request"
else
  pass "malformed stream events fail the request"
fi
exec {event_tfd}>&- {event_cfd}>&- {event_efd}>&- {event_ufd}>&-
assert_contains "${mapfile[${event_dir}/error]}" "Invalid Ollama JSON event" "stream parse errors are retained"

typeset reader_base="${TEST_STATE_DIR}/reader"
: > "${reader_base}.thinking"
: > "${reader_base}.content"
api_stream_open_readers "$reader_base"
print -rn -- "first" >> "${reader_base}.thinking"
print -rn -- "answer" >> "${reader_base}.content"
api_stream_read_updates
assert_eq "first" "$API_STREAM_THINKING_DELTA" "stream reader returns new reasoning bytes"
assert_eq "answer" "$API_STREAM_CONTENT_DELTA" "stream reader returns new content bytes"
print -rn -- "-next" >> "${reader_base}.content"
api_stream_read_updates
assert_eq "-next" "$API_STREAM_CONTENT_DELTA" "stream reader does not reread old content"
api_stream_close_readers

api_runtime_init
typeset private_runtime="$API_RUNTIME_DIR"
typeset -A runtime_stat=()
zstat -H runtime_stat "$private_runtime"
printf -v runtime_mode '%o' $(( ${runtime_stat[mode]} & 8#777 ))
assert_eq "700" "$runtime_mode" "request runtime directory is private"

typeset saved_http_stream="${functions[_api_http_stream]}"
_api_http_stream() {
  mapfile[$5]="synthetic stream failure"
  return 7
}
typeset worker_base="${API_RUNTIME_DIR}/worker-test"
api_start_stream "unused" '{}' "$worker_base"
typeset worker_pid="$API_STREAM_PID"
wait "$worker_pid" 2>/dev/null
if api_stream_collect "$worker_pid" "$worker_base"; then
  fail "stream worker failure reaches the parent"
else
  pass "stream worker failure reaches the parent"
fi
assert_eq "7" "$API_STREAM_STATUS" "stream worker preserves its failure status"
assert_eq "synthetic stream failure" "$API_STREAM_ERROR" "stream worker preserves its error message"
functions[_api_http_stream]="$saved_http_stream"
api_runtime_cleanup
[[ ! -e "$private_runtime" ]] && pass "request runtime directory is removed on cleanup" || fail "request runtime directory is removed on cleanup"

json_parse_running_model_context '{"models":[{"name":"other:latest","context_length":4096},{"model":"qwen:latest","context_length":65536}]}' qwen
assert_eq "65536" "$JSON_RUNNING_MODEL_CONTEXT" "untagged names match Ollama's loaded latest model"

SESSION_MODEL="qwen:latest"
SESSION_SYSTEM_PROMPT="Be useful."
SESSION_TEMPERATURE=0.7
typeset saved_context_lookup="${functions[api_get_running_context]}"
api_get_running_context() {
  if [[ "$1" == "qwen:latest" ]]; then
    API_RUNNING_CONTEXT=98304
    return 0
  fi
  return 1
}
ZCHAT_CONTEXT_WINDOW=auto
CHAT_CONTEXT_MODEL=""
chat_context_configure
assert_eq "98304" "$CHAT_CONTEXT_WINDOW" "automatic sizing uses Ollama's loaded model allocation"
assert_eq "0" "$CHAT_CONTEXT_DISCOVERY_PENDING" "loaded model context discovery is complete"
chat_context_options_json
assert_contains "$REPLY" '"num_ctx":98304' "loaded model requests pin the discovered allocation"

SESSION_MODEL="unloaded:latest"
CHAT_CONTEXT_MODEL=""
chat_context_configure
assert_eq "$ZCHAT_CONTEXT_FALLBACK" "$CHAT_CONTEXT_WINDOW" "unloaded models use the fallback for provisional accounting"
assert_eq "1" "$CHAT_CONTEXT_DISCOVERY_PENDING" "unloaded model allocation remains pending"
chat_context_options_json
assert_eq "" "$REPLY" "pending automatic context does not request the fallback allocation"
MSG_ROLES=(user)
MSG_CONTENTS=("first request")
MSG_THINKINGS=("")
MSG_THINKING_EXPANDED=(0)
MSG_TIMES=("")
state_build_payload
assert_not_contains "$REPLY" '"num_ctx"' "first unloaded-model payload lets Ollama choose its default context"
chat_context_summary
assert_contains "$REPLY" "provisional accounting fallback" "context status identifies the provisional fallback"

api_get_running_context() {
  API_RUNNING_CONTEXT=131072
  return 0
}
chat_context_refresh_after_response
assert_eq "131072" "$CHAT_CONTEXT_WINDOW" "post-response discovery adopts Ollama's active allocation"
assert_eq "0" "$CHAT_CONTEXT_DISCOVERY_PENDING" "post-response discovery clears the pending state"
chat_context_options_json
assert_contains "$REPLY" '"num_ctx":131072' "later requests pin the authoritative active allocation"
chat_context_summary
assert_contains "$REPLY" "active Ollama allocation" "context status identifies an authoritative allocation"
functions[api_get_running_context]="$saved_context_lookup"

ZCHAT_CONTEXT_WINDOW=8192
CHAT_CONTEXT_MODEL=""
MSG_ROLES=(user system assistant user)
MSG_CONTENTS=("first question" "UI-only notice" "first answer" "follow up")
MSG_THINKINGS=("" "" "" "")
MSG_THINKING_EXPANDED=(0 0 0 0)
MSG_TIMES=("" "" "" "")
CHAT_USER_MESSAGES=("first question" "follow up")
chat_context_configure
state_build_payload
assert_contains "$REPLY" '"num_ctx":8192' "chat requests pin the selected context allocation"
assert_contains "$REPLY" "follow up" "chat payload includes real conversation messages"
[[ "$REPLY" != *"UI-only notice"* ]] && pass "UI system notices stay out of model context" || fail "UI system notices stay out of model context"
chat_context_summary
assert_contains "$REPLY" "explicit setting" "context status identifies a fixed allocation"

typeset -g MOCK_COMPACT_PAYLOAD=""
api_chat_sync() {
  MOCK_COMPACT_PAYLOAD="$1"
  API_HTTP_BODY='{"message":{"content":"Durable checkpoint"},"done":true,"prompt_eval_count":1800,"eval_count":120}'
  return 0
}

CURRENT_SESSION_ID="compaction-test"
state_save_session
typeset -i transcript_before=${#MSG_ROLES}
chat_compact_history manual
assert_eq "Durable checkpoint" "$CHAT_COMPACTION_SUMMARY" "manual compaction stores the checkpoint"
assert_eq "1" "$CHAT_COMPACTION_COUNT" "manual compaction advances the checkpoint counter"
(( ${#MSG_ROLES} > transcript_before )) && pass "compaction preserves the visible transcript" || fail "compaction preserves the visible transcript"
state_build_payload
assert_contains "$REPLY" "Durable checkpoint" "later model prompts include compacted context"

state_save_session
CHAT_COMPACTION_SUMMARY=""
CHAT_COMPACTION_COUNT=0
CHAT_CONTEXT_START_INDEX=1
CHAT_USER_MESSAGES=()
MSG_ROLES=()
MSG_CONTENTS=()
state_load_session "compaction-test"
assert_eq "Durable checkpoint" "$CHAT_COMPACTION_SUMMARY" "session reload restores the checkpoint"
assert_eq "1" "$CHAT_COMPACTION_COUNT" "session reload restores checkpoint metadata"
(( ${#MSG_ROLES} > transcript_before )) && pass "session reload restores the complete transcript" || fail "session reload restores the complete transcript"

CHAT_COMPACTION_REARM_TOKENS=3456
CHAT_LAST_PROMPT_TOKENS=2345
CHAT_LAST_OUTPUT_TOKENS=123
CHAT_LAST_PAYLOAD_BYTES=6789
CHAT_LAST_USAGE_MODEL="$SESSION_MODEL"
CHAT_LAST_USAGE_HOST="$OLLAMA_HOST"
CHAT_COMPACTION_REARM_MODEL="$SESSION_MODEL"
CHAT_COMPACTION_REARM_HOST="$OLLAMA_HOST"
state_save_session
CHAT_COMPACTION_REARM_TOKENS=0
CHAT_LAST_PROMPT_TOKENS=0
CHAT_LAST_OUTPUT_TOKENS=0
CHAT_LAST_PAYLOAD_BYTES=0
CHAT_LAST_USAGE_MODEL=""
CHAT_LAST_USAGE_HOST=""
CHAT_COMPACTION_REARM_MODEL=""
CHAT_COMPACTION_REARM_HOST=""
state_load_session "compaction-test"
assert_eq "3456" "$CHAT_COMPACTION_REARM_TOKENS" "session reload restores compaction rearm threshold"
assert_eq "2345" "$CHAT_LAST_PROMPT_TOKENS" "session reload restores token calibration"
assert_eq "$SESSION_MODEL" "$CHAT_LAST_USAGE_MODEL" "token calibration retains its model identity"
CHAT_CONTEXT_MODEL=""
CHAT_CONTEXT_HOST=""
ZCHAT_CONTEXT_WINDOW=8192
chat_context_configure
assert_eq "2345" "$CHAT_LAST_PROMPT_TOKENS" "first configure preserves restored calibration"

typeset -i message_count_before=${#MSG_ROLES}
typeset persisted_count="${mapfile[${ZCHAT_SESSIONS_DIR}/compaction-test.session/message_count]}"
state_begin_streaming_message
assert_eq "$(( message_count_before + 1 ))" "${#MSG_ROLES}" "streaming assistant begins in memory"
assert_eq "$persisted_count" "${mapfile[${ZCHAT_SESSIONS_DIR}/compaction-test.session/message_count]}" "streaming placeholder is not persisted"
state_update_streaming_message "" "reasoning"
state_update_streaming_message "answer started" "reasoning"
assert_eq "0" "${MSG_THINKING_EXPANDED[-1]}" "reasoning collapses when response content starts"
state_discard_streaming_message "${#MSG_ROLES}"
assert_eq "$message_count_before" "${#MSG_ROLES}" "discard removes the streaming placeholder"

SESSION_MODEL="model-used-for-reply"
state_append_message assistant "model-specific answer"
SESSION_MODEL="new-session-model"
state_save_session
state_load_session "compaction-test"
assert_eq "model-used-for-reply" "${MSG_MODELS[-1]}" "assistant messages retain their generating model"

# Incremental persistence: unchanged message files are not rewritten, changed
# ones are, and a lost session directory is fully recreated on the next save.
CURRENT_SESSION_ID="incremental-test"
STATE_SAVED_SESSION_ID=""
SESSION_TITLE="Incremental"
MSG_ROLES=(user assistant user)
MSG_CONTENTS=("one" "two" "three")
MSG_THINKINGS=("" "some thinking" "")
MSG_THINKING_EXPANDED=(0 1 0)
MSG_TIMES=("" "" "")
MSG_MODELS=("" "m" "")
CHAT_USER_MESSAGES=("one" "three")
state_save_session
typeset incr_dir="${ZCHAT_SESSIONS_DIR}/incremental-test.session"
assert_eq "3" "${mapfile[$incr_dir/message_count]}" "incremental baseline saves every message"
mapfile[$incr_dir/messages/000001.content]="tampered"
state_append_message system "a fourth message"
assert_eq "tampered" "${mapfile[$incr_dir/messages/000001.content]}" "append leaves already-persisted messages untouched"
assert_eq "a fourth message" "${mapfile[$incr_dir/messages/000004.content]}" "append persists the new message"
assert_eq "4" "${mapfile[$incr_dir/message_count]}" "append advances the commit marker"
state_toggle_last_reasoning
assert_eq "0" "${mapfile[$incr_dir/messages/000002.expanded]}" "mid-transcript changes persist their own file"
assert_eq "tampered" "${mapfile[$incr_dir/messages/000001.content]}" "mid-transcript changes do not rewrite earlier files"
zf_rm -rf -- "$incr_dir"
state_save_session
assert_eq "one" "${mapfile[$incr_dir/messages/000001.content]}" "a recreated session directory is fully rewritten"
assert_eq "4" "${mapfile[$incr_dir/message_count]}" "recreated session restores the commit marker"
state_load_session "incremental-test"
assert_eq "4" "${#MSG_ROLES}" "recreated session reloads the complete transcript"
assert_eq "a fourth message" "${MSG_CONTENTS[4]}" "recreated session reloads message content"
state_load_session "compaction-test"

_state_write_config
typeset -A file_stat=() dir_stat=()
zstat -H file_stat "$ZCHAT_CONFIG_FILE"
zstat -H dir_stat "$ZCHAT_SESSIONS_DIR"
printf -v config_mode '%o' $(( ${file_stat[mode]} & 8#777 ))
printf -v sessions_mode '%o' $(( ${dir_stat[mode]} & 8#777 ))
assert_eq "600" "$config_mode" "configuration is private"
assert_eq "700" "$sessions_mode" "session directory is private"

typeset atomic_target="${TEST_STATE_DIR}/atomic-target"
zf_ln -s /dev/full "$atomic_target"
if zchat_atomic_write "$atomic_target" "checked" 0600; then pass "atomic writer replaces a hostile leaf symlink"; else fail "atomic writer replaces a hostile leaf symlink"; fi
[[ ! -L "$atomic_target" ]] && pass "atomic writer leaves a regular file" || fail "atomic writer leaves a regular file"
zchat_read_file "$atomic_target" 64
assert_eq "checked" "$REPLY" "atomic writer verifies readable content"

typeset arithmetic_file="${TEST_STATE_DIR}/arithmetic-value"
typeset -g ARITHMETIC_SENTINEL=0
mapfile[$arithmetic_file]='ARITHMETIC_SENTINEL=77'
_state_read_uint "$arithmetic_file" 0 1000
assert_eq "0" "$ARITHMETIC_SENTINEL" "persisted integers are never recursively evaluated"
assert_eq "0" "$REPLY" "invalid persisted integers fall back safely"

typeset blocked_target="${ZCHAT_SESSIONS_DIR}/blocked.session"
zf_ln -s "$TEST_STATE_DIR" "$blocked_target"
CURRENT_SESSION_ID="blocked"
STATE_MSG_DIRTY_FROM=1
if state_save_session; then fail "session save rejects symlink directories"; else pass "session save rejects symlink directories"; fi
assert_eq "1" "$STATE_MSG_DIRTY_FROM" "failed saves retain dirty bookkeeping"
zf_rm -f -- "$blocked_target"
typeset linked_load_dir="${ZCHAT_SESSIONS_DIR}/linked-load.session"
zf_mkdir -p "$linked_load_dir"
zchat_atomic_write "$linked_load_dir/message_count" "0" 0600
zf_ln -s "$TEST_STATE_DIR" "$linked_load_dir/messages"
if state_load_session 'linked-load'; then fail "session load rejects symlinked message directories"; else pass "session load rejects symlinked message directories"; fi
zf_rm -rf -- "$linked_load_dir"
if state_delete_session '../outside'; then fail "session deletion rejects path traversal"; else pass "session deletion rejects path traversal"; fi
state_load_session "compaction-test"

typeset legacy_escape="${ZCHAT_SESSIONS_DIR}/legacy-safe.json"
typeset legacy_escape_target="${TEST_STATE_DIR:h}/zchat-escape-${sysparams[pid]:-$$}.session"
mapfile[$legacy_escape]='{"id":"../../zchat-escape-'"${sysparams[pid]:-$$}"'","title":"Legacy","messages":[]}'
state_migrate_legacy_sessions
[[ -d "${ZCHAT_SESSIONS_DIR}/legacy-safe.session" ]] && pass "legacy migration derives a safe filename id" || fail "legacy migration derives a safe filename id"
[[ ! -e "$legacy_escape_target" ]] && pass "legacy migration cannot escape session storage" || fail "legacy migration cannot escape session storage"
state_load_session "compaction-test"

ZCHAT_CONTEXT_WINDOW=4096
CHAT_CONTEXT_WINDOW=4096
CHAT_CONTEXT_START_INDEX=1
CHAT_COMPACTION_SUMMARY=""
MSG_ROLES=(user assistant user)
MSG_CONTENTS=("older request" "older answer" "latest request")
CHAT_USER_MESSAGES=("older request" "latest request")
chat_build_compaction_payload 1
typeset duplicate_probe="$REPLY" occurrence_rest="$REPLY"
typeset -i latest_occurrences=0
while [[ "$occurrence_rest" == *"latest request"* ]]; do
  occurrence_rest="${occurrence_rest#*latest request}"
  (( latest_occurrences++ ))
done
assert_eq "1" "$latest_occurrences" "compaction ledger does not duplicate raw-tail requests"

MSG_ROLES=(user assistant user)
MSG_CONTENTS=("${(l:1900::u:)}" "short answer" "latest")
CHAT_USER_MESSAGES=("${MSG_CONTENTS[1]}" "latest")
chat_compaction_replace_history "aligned checkpoint"
assert_eq "user" "${MSG_ROLES[CHAT_CONTEXT_START_INDEX]}" "retained raw context starts on a user turn"

CHAT_COMPACTION_SUMMARY=""
CHAT_COMPACTION_COUNT=0
CHAT_CONTEXT_START_INDEX=1
CHAT_COMPACTION_REARM_TOKENS=0
CHAT_CONTEXT_MODEL=""
ZCHAT_CONTEXT_WINDOW=4096
ZCHAT_COMPACT_PERCENT=25
MSG_ROLES=(user assistant user)
MSG_CONTENTS=("${(l:4000::u:)}" "${(l:4000::a:)}" "continue")
CHAT_USER_MESSAGES=("${MSG_CONTENTS[1]}" "continue")
chat_prepare_payload
assert_eq "1" "$CHAT_COMPACTION_COUNT" "oversized prompts trigger automatic compaction"
assert_contains "$REPLY" "Durable checkpoint" "automatic compaction rebuilds the pending prompt"

functions[_test_real_compaction_builder]="${functions[chat_build_compaction_payload]}"
typeset -gi MOCK_COMPACTION_BUILDS=0
typeset -ga MOCK_COMPACTION_STARTS=()
chat_build_compaction_payload() {
  (( MOCK_COMPACTION_BUILDS++ ))
  MOCK_COMPACTION_STARTS+=("${1:-$CHAT_CONTEXT_START_INDEX}")
  _test_real_compaction_builder "$@"
}
ZCHAT_CONTEXT_WINDOW=4096
CHAT_CONTEXT_WINDOW=4096
CHAT_CONTEXT_MODEL="$SESSION_MODEL"
CHAT_CONTEXT_HOST="$OLLAMA_HOST"
CHAT_CONTEXT_START_INDEX=1
CHAT_COMPACTION_SUMMARY=""
CHAT_COMPACTION_COUNT=0
CHAT_LAST_PROMPT_TOKENS=0
CHAT_LAST_PAYLOAD_BYTES=0
MSG_ROLES=()
MSG_CONTENTS=()
MSG_THINKINGS=()
MSG_THINKING_EXPANDED=()
MSG_TIMES=()
CHAT_USER_MESSAGES=()
for compact_exchange in {1..64}; do
  MSG_ROLES+=(user assistant)
  MSG_CONTENTS+=("request ${compact_exchange}: ${(l:240::u:)}" "answer ${compact_exchange}: ${(l:240::a:)}")
  MSG_THINKINGS+=("" "")
  MSG_THINKING_EXPANDED+=(0 0)
  MSG_TIMES+=("" "")
  CHAT_USER_MESSAGES+=("request ${compact_exchange}: ${(l:240::u:)}")
done
typeset -a compact_users_before=("${CHAT_USER_MESSAGES[@]}")
chat_compact_history manual
large_compact_status=$?
assert_eq "0" "$large_compact_status" "large-history compaction completes"
(( MOCK_COMPACTION_BUILDS <= 8 )) && pass "large-history compaction uses a logarithmic cutoff search" || fail "large-history compaction uses a logarithmic cutoff search"
typeset -i aligned_search=1 compact_start
for compact_start in "${MOCK_COMPACTION_STARTS[@]}"; do
  [[ "${MSG_ROLES[compact_start]}" == user ]] || { aligned_search=0; break; }
done
(( aligned_search )) && pass "cutoff search evaluates only user-turn boundaries" || fail "cutoff search evaluates only user-turn boundaries"
assert_not_contains "$MOCK_COMPACT_PAYLOAD" "answer 1:" "large-history cutoff omits old assistant detail"
assert_contains "$MOCK_COMPACT_PAYLOAD" "answer 64:" "large-history cutoff retains the newest complete exchange"
typeset -i selected_exchange=0 selected_estimate=0 previous_estimate=0
for compact_exchange in {1..64}; do
  if [[ "$MOCK_COMPACT_PAYLOAD" == *"answer ${compact_exchange}:"* ]]; then
    selected_exchange=$compact_exchange
    break
  fi
done
(( selected_exchange > 1 )) && pass "large-history search selects a measurable interior cutoff" || fail "large-history search selects a measurable interior cutoff"
typeset compact_summary_after="$CHAT_COMPACTION_SUMMARY"
typeset -a compact_users_after=("${CHAT_USER_MESSAGES[@]}")
CHAT_COMPACTION_SUMMARY=""
CHAT_USER_MESSAGES=("${compact_users_before[@]}")
_test_real_compaction_builder $(( selected_exchange * 2 - 1 ))
[[ "$REPLY" == "$MOCK_COMPACT_PAYLOAD" ]] && pass "cutoff payload begins at the selected complete user turn" || fail "cutoff payload begins at the selected complete user turn"
chat_estimate_payload_tokens "$REPLY"
selected_estimate=$REPLY
_test_real_compaction_builder $(( (selected_exchange - 1) * 2 - 1 ))
chat_estimate_payload_tokens "$REPLY"
previous_estimate=$REPLY
(( selected_estimate <= CHAT_CONTEXT_WINDOW * 85 / 100 )) && pass "selected user-turn cutoff fits the checkpoint budget" || fail "selected user-turn cutoff fits the checkpoint budget"
(( previous_estimate > CHAT_CONTEXT_WINDOW * 85 / 100 )) && pass "preceding user-turn cutoff still exceeds the checkpoint budget" || fail "preceding user-turn cutoff still exceeds the checkpoint budget"
CHAT_COMPACTION_SUMMARY="$compact_summary_after"
CHAT_USER_MESSAGES=("${compact_users_after[@]}")
functions[chat_build_compaction_payload]="${functions[_test_real_compaction_builder]}"
unfunction _test_real_compaction_builder

typeset saved_context_configure="${functions[chat_context_configure]}"
chat_context_configure() { CHAT_COMPACTION_ERROR="Context discovery stopped"; return 130; }
CHAT_COMPACTION_IN_PROGRESS=0
CHAT_COMPACTION_CANCELLED=0
if chat_compact_history manual; then fail "manual compaction propagates context cancellation"; else
  assert_eq "130" "$?" "manual compaction propagates context cancellation"
fi
assert_eq "0" "$CHAT_COMPACTION_IN_PROGRESS" "cancelled context discovery clears compaction state"
assert_eq "1" "$CHAT_COMPACTION_CANCELLED" "cancelled context discovery is reported"
functions[chat_context_configure]="$saved_context_configure"

source "${PROJECT_DIR}/lib/render.zsh"
source "${PROJECT_DIR}/lib/ui.zsh"

typeset span_collision_text='before~@~bold red/black~#~after **styled**'
_render_tokenize_inline "$span_collision_text" "white/black"
typeset encoded_collision_spans="$REPLY"
if render_unpack_spans "$encoded_collision_spans"; then pass "inline spans use collision-free framing"; else fail "inline spans use collision-free framing"; fi
assert_eq 'before~@~bold red/black~#~after styled' "${(j::)RENDER_SPAN_TEXTS}" "inline span framing preserves delimiter-like text"
SCREEN_H=30
SCREEN_W=80
TOP_H=3
FOOT_H=1
FOCUS_PANE="input"
input_reset
ui_calculate_input_height
assert_eq "3" "$INPUT_H" "empty prompt uses a one-row editor"
input_insert $'one\ntwo\nthree\nfour\nfive'
ui_calculate_input_height
assert_eq "6" "$INPUT_H" "prompt window grows to its four-row cap"

typeset -ga MOCK_DRAW_CALLS=()
zchat_draw() {
  MOCK_DRAW_CALLS+=("${(j: :)@}")
  return 0
}
ui_draw_input
typeset render_calls="${(j:\n:)MOCK_DRAW_CALLS}"
assert_contains "$render_calls" "2-5/5" "prompt title reports the cursor-following viewport"
assert_contains "$render_calls" "string input_win ↑ " "prompt viewport marks rows above the visible range"

MSG_ROLES=(user assistant assistant system)
MSG_CONTENTS=("Copy this request" "Work completed" "" "Saved locally")
MSG_THINKINGS=("" "private reasoning" "expanded reasoning" "")
MSG_THINKING_EXPANDED=(0 0 1 0)
MSG_TIMES=("10:00" "10:01" "10:02" "10:03")
MSG_MODELS=("" "answer-model" "reasoning-model" "")
ui_plain_transcript
assert_contains "$REPLY" "Copy this request" "copy view exports transcript content as plain text"
assert_contains "$REPLY" "Assistant (answer-model)" "copy view uses the response's recorded model"
assert_not_contains "$REPLY" "private reasoning" "copy view omits collapsed reasoning"
assert_contains "$REPLY" "expanded reasoning" "copy view includes expanded reasoning"
MSG_THINKING_EXPANDED[2]=1
ui_plain_transcript
assert_contains "$REPLY" "private reasoning" "copy view includes reasoning after expansion"

MSG_ROLES=(assistant assistant)
MSG_CONTENTS=("finished answer" "streaming one")
MSG_THINKINGS=("" "")
MSG_THINKING_EXPANDED=(0 1)
MSG_TIMES=("[00:00]" "[00:01]")
MSG_MODELS=("old-model" "new-model")
CURRENT_SESSION_ID="render-cache-test"
render_invalidate
render_messages 70 1
typeset rendered_text="${(j:\n:)RENDERED_LINES}"
assert_contains "$rendered_text" "Assistant (old-model)" "renderer uses the model stored with each response"
MSG_CONTENTS[2]="streaming two"
render_messages 70 1
rendered_text="${(j:\n:)RENDERED_LINES}"
assert_contains "$rendered_text" "streaming two" "stream render cache refreshes the active response"
[[ "$rendered_text" != *"streaming one"* ]] && pass "stream render cache does not retain stale content" || fail "stream render cache does not retain stale content"

MOCK_DRAW_CALLS=()
SIDE_W=20
ui_refresh_all 0
render_calls="${(j:\n:)MOCK_DRAW_CALLS}"
assert_contains "$render_calls" "refresh top_win side_win chat_win input_win foot_win" "full refresh batches all curses windows"

MOCK_DRAW_CALLS=()
ui_refresh_stream
render_calls="${(j:\n:)MOCK_DRAW_CALLS}"
assert_contains "$render_calls" "refresh top_win chat_win" "stream refresh repaints only changing windows"

typeset hostile_option_version
hostile_option_version="$(zsh -f -o KSH_ARRAYS "${PROJECT_DIR}/zchat.zsh" --version)"
assert_eq "zchat.zsh v${ZCHAT_VERSION:-1.0.11}" "$hostile_option_version" "entrypoint resets hostile ambient Zsh options"
if zsh -f "${PROJECT_DIR}/zchat.zsh" --model >/dev/null 2>&1; then fail "CLI rejects missing option values"; else pass "CLI rejects missing option values"; fi
if zsh -f "${PROJECT_DIR}/zchat.zsh" --unknown >/dev/null 2>&1; then fail "CLI rejects unknown options"; else pass "CLI rejects unknown options"; fi

source "$TEST_DIR/chat_ports.zsh"
source "$TEST_DIR/http_transport.zsh"

unfunction zchat_draw
source "$TEST_DIR/draw.zsh"
source "$TEST_DIR/drawing.zsh"
source "$TEST_DIR/input_cells.zsh"
source "$TEST_DIR/chat_ports_pty.zsh"

print -r -- "1..${TESTS}"
(( FAILURES == 0 ))
