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

api_chat_sync() {
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

_state_write_config
typeset -A file_stat=() dir_stat=()
zstat -H file_stat "$ZCHAT_CONFIG_FILE"
zstat -H dir_stat "$ZCHAT_SESSIONS_DIR"
printf -v config_mode '%o' $(( ${file_stat[mode]} & 8#777 ))
printf -v sessions_mode '%o' $(( ${dir_stat[mode]} & 8#777 ))
assert_eq "600" "$config_mode" "configuration is private"
assert_eq "700" "$sessions_mode" "session directory is private"

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

source "${PROJECT_DIR}/lib/render.zsh"
source "${PROJECT_DIR}/lib/ui.zsh"
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

typeset -ga MOCK_ZCURSES_CALLS=()
zcurses() {
  MOCK_ZCURSES_CALLS+=("${(j: :)@}")
  return 0
}
ui_draw_input
typeset render_calls="${(j:\n:)MOCK_ZCURSES_CALLS}"
assert_contains "$render_calls" "2-5/5" "prompt title reports the cursor-following viewport"
assert_contains "$render_calls" "string input_win ↑ " "prompt viewport marks rows above the visible range"

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

MOCK_ZCURSES_CALLS=()
SIDE_W=20
ui_refresh_all 0
render_calls="${(j:\n:)MOCK_ZCURSES_CALLS}"
assert_contains "$render_calls" "refresh top_win side_win chat_win input_win foot_win" "full refresh batches all curses windows"

MOCK_ZCURSES_CALLS=()
ui_refresh_stream
render_calls="${(j:\n:)MOCK_ZCURSES_CALLS}"
assert_contains "$render_calls" "refresh top_win chat_win" "stream refresh repaints only changing windows"

print -r -- "1..${TESTS}"
(( FAILURES == 0 ))
