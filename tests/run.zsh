#!/usr/bin/env zsh

setopt EXTENDED_GLOB NO_NOMATCH
zmodload zsh/datetime zsh/files zsh/mapfile zsh/net/tcp zsh/system || exit 1

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

json_parse_running_model_context '{"models":[{"name":"other:latest","context_length":4096},{"model":"qwen:latest","context_length":65536}]}' qwen
assert_eq "65536" "$JSON_RUNNING_MODEL_CONTEXT" "untagged names match Ollama's loaded latest model"

SESSION_MODEL="qwen:latest"
SESSION_SYSTEM_PROMPT="Be useful."
SESSION_TEMPERATURE=0.7
typeset saved_context_lookup="${functions[api_get_running_context]}"
api_get_running_context() {
  API_RUNNING_CONTEXT=98304
  return 0
}
ZCHAT_CONTEXT_WINDOW=auto
CHAT_CONTEXT_MODEL=""
chat_context_configure
assert_eq "98304" "$CHAT_CONTEXT_WINDOW" "automatic sizing uses Ollama's loaded model allocation"
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

print -r -- "1..${TESTS}"
(( FAILURES == 0 ))
