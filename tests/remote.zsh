#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob no_nomatch
zmodload zsh/files zsh/system zsh/datetime zsh/net/tcp zsh/zselect
ROOT="${0:A:h:h}"
source "$ROOT/lib/util.zsh"
source "$ROOT/lib/json.zsh"
source "$ROOT/lib/api.zsh"
source "$ROOT/lib/compact.zsh"
source "$ROOT/lib/state.zsh"
source "$ROOT/lib/remote.zsh"
source "$ROOT/lib/remote_stream.zsh"
typeset -i failures=0 checks=0
check() { (( checks++ )); if "$@"; then print -r -- "ok remote $checks - $*"; else print -r -- "FAIL remote $checks - $*"; (( failures++ )); fi }
eq() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
api_runtime_init || exit 1
trap 'api_stop_stream "$API_STREAM_PID"; [[ -z "$fixture_pid" ]] || kill "$fixture_pid" 2>/dev/null; api_runtime_cleanup' EXIT
ZCHAT_REMOTE_CONFIG="$API_RUNTIME_DIR/remotes.json"
config='{"models":{"chat":{"protocol":"chat-completions","url":"https://example.test/chat/completions","model":"some-model","auth":"none","parameters":{"temperature":0.4}},"responses":{"protocol":"responses","url":"https://example.test/responses","model":"another-model","auth":"none"},"messages":{"protocol":"messages","url":"https://example.test/messages","model":"third-model","auth":"api-key","api_key_env":"REMOTE_TEST_KEY","headers":{"anthropic-version":"2023-06-01"}}}}'
export REMOTE_TEST_KEY='secret for fixture'
# Display aliases may contain model version dots; provider IDs remain separate.
dotted_config='{"models":{"glm-5.3-flash":{"protocol":"chat-completions","url":"https://example.test/chat/completions","model":"fireworks/glm-5p3-flash","auth":"none"},"opus-5.5":{"protocol":"messages","url":"https://example.test/messages","model":"anthropic/claude-opus-5-5","auth":"none"}}}'
zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$dotted_config" 0600
check remote_load_config
check eq "${REMOTE_MODELS[1]}" remote:glm-5.3-flash
check eq "${REMOTE_MODELS[2]}" remote:opus-5.5
SESSION_MODEL=remote:glm-5.3-flash
check remote_profile
check eq "$REMOTE_MODEL" fireworks/glm-5p3-flash
SESSION_MODEL=remote:opus-5.5
check remote_profile
check eq "$REMOTE_MODEL" anthropic/claude-opus-5-5
zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$config" 0600
check remote_load_config
check eq "${#REMOTE_MODELS}" 3
SESSION_MODEL=remote:chat
check remote_profile
check eq "$REMOTE_PARAMETERS" '{"temperature":0.4}'
source_payload='{"messages":[{"role":"system","content":"Be helpful"},{"role":"user","content":"hello \"world\""},{"role":"assistant","content":"old reply"}],"options":{"num_ctx":65536,"temperature":0.7}}'
for protocol in chat responses messages; do
  SESSION_MODEL="remote:$protocol"
  check remote_profile
  check remote_payload "$source_payload"
  check remote_json_parse "$REPLY"
  check eq "${REMOTE_JSON[/stream]}" true
  check eq "${REMOTE_JSON_TYPE[/options]}" ''
  case "$protocol" in
    chat) check eq "${REMOTE_JSON[/messages/0/role]}" system ;;
    responses) check eq "${REMOTE_JSON[/instructions]}" 'Be helpful'; check eq "${REMOTE_JSON[/input/1/role]}" assistant ;;
    messages) check eq "${REMOTE_JSON[/system]}" 'Be helpful'; check eq "${REMOTE_JSON[/messages/0/role]}" user ;;
  esac
done
check eq "${REMOTE_HEADERS[2]}" 'x-api-key: secret for fixture'
# Configuration and payload injection boundaries.
SESSION_MODEL=remote:chat
REMOTE_CONFIG_TYPE[/models/chat/parameters/stream]=true
if remote_profile; then check false; else check contains "$REMOTE_ERROR" parameters.stream; fi
unset 'REMOTE_CONFIG_TYPE[/models/chat/parameters/stream]'
REMOTE_CONFIG[/models/chat/context_window]='1+2'
if remote_profile; then check false; else check eq "$REMOTE_ERROR" 'Invalid remote context_window'; fi
unset 'REMOTE_CONFIG[/models/chat/context_window]'
REMOTE_CONFIG_TYPE[/models/chat/header_env]='{'
REMOTE_CONFIG_TYPE[/models/chat/header_env/X-Test]=string
REMOTE_CONFIG[/models/chat/header_env/X-Test]='bad[$(touch should-not-exist)]'
if remote_profile; then check false; else check eq "$REMOTE_ERROR" 'Missing header environment variable'; fi
unset 'REMOTE_CONFIG_TYPE[/models/chat/header_env]' 'REMOTE_CONFIG_TYPE[/models/chat/header_env/X-Test]' 'REMOTE_CONFIG[/models/chat/header_env/X-Test]'
SESSION_MODEL=remote:missing
if remote_profile; then check false; else check eq "$REMOTE_ERROR" 'Unknown remote model: remote:missing'; fi
for invalid in '{"a":1,"a":2}' '{"a":1,}' '[1,]' '{"a":}' '{} trailing'; do
  if remote_json_parse "$invalid"; then check false; else check true; fi
done
SESSION_MODEL=remote:messages
unset REMOTE_TEST_KEY
if remote_profile; then check false; else check true; fi
export REMOTE_TEST_KEY='secret for fixture'

reset_stream() {
  REMOTE_SSE_BUFFER='' REMOTE_SSE_DATA='' REMOTE_SSE_EVENT='' REMOTE_DONE=0 REMOTE_SSE_STARTED=0
  REMOTE_INPUT_TOKENS=0 REMOTE_OUTPUT_TOKENS=0 REMOTE_ERROR=''
  exec {remote_content_fd}>"$API_RUNTIME_DIR/content" {remote_thinking_fd}>"$API_RUNTIME_DIR/thinking"
}
close_stream() { exec {remote_content_fd}>&- {remote_thinking_fd}>&-; }
REMOTE_PROTOCOL=chat-completions
reset_stream
sse=$'\xef\xbb\xbf: ping\r\ndata: {"choices":[{"delta":{"content":"héllo 🌍","reasoning_content":"hmm"}}]}\r\n\r\ndata: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}\n\ndata: [DONE]\n\n'
# Byte-by-byte boundaries exercise fragmented UTF-8, CRLF and JSON.
setopt nomultibyte
for (( i=1; i<=${#sse}; i++ )); do
  remote_sse_feed "${sse[i]}" || { check false; print -r -- "$REMOTE_ERROR"; break; }
done
setopt multibyte
close_stream
check eq "$REMOTE_DONE" 1
zchat_read_file "$API_RUNTIME_DIR/content"; check eq "$REPLY" 'héllo 🌍'
zchat_read_file "$API_RUNTIME_DIR/thinking"; check eq "$REPLY" hmm
check eq "$REMOTE_INPUT_TOKENS $REMOTE_OUTPUT_TOKENS" '12 3'
for protocol in responses messages; do
  REMOTE_PROTOCOL=$protocol
  reset_stream
  if [[ "$protocol" == responses ]]; then
    sse=$'event: response.output_text.delta\ndata: {"type":"response.output_text.delta",\ndata: "delta":"hello"}\n\ndata: {"type":"response.reasoning_summary_text.delta","delta":"thought"}\n\ndata: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":9,"output_tokens":2}}}\n\n'
  else
    sse=$'data: {"type":"message_start","message":{"usage":{"input_tokens":9,"output_tokens":1}}}\n\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}\n\ndata: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"thought"}}\n\ndata: {"type":"message_delta","usage":{"output_tokens":2}}\n\ndata: {"type":"message_stop"}\n\n'
  fi
  check remote_sse_feed "$sse"
  close_stream
  check eq "$REMOTE_DONE" 1
  check eq "$REMOTE_INPUT_TOKENS $REMOTE_OUTPUT_TOKENS" '9 2'
  zchat_read_file "$API_RUNTIME_DIR/content"; check eq "$REPLY" hello
  zchat_read_file "$API_RUNTIME_DIR/thinking"; check eq "$REPLY" thought
done
reset_stream
if remote_sse_feed $'data: {"type":"error","error":{"message":"overloaded"}}\n\n'; then check false; else check eq "$REMOTE_ERROR" overloaded; fi
close_stream
REMOTE_PROTOCOL=chat-completions
reset_stream
check remote_sse_feed $'data: {"choices":[{"delta":{"content":null,"role":"assistant"}}]}\n\ndata: [DONE]\n\n'
close_stream
zchat_read_file "$API_RUNTIME_DIR/content"; check eq "$REPLY" ''
REMOTE_PROTOCOL=messages
reset_stream
check remote_sse_feed $'data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}\n\ndata: {"type":"message_stop"}\n\n'
check eq "$REMOTE_INPUT_TOKENS" 130
close_stream
REMOTE_PROTOCOL=responses
reset_stream
if remote_sse_feed $'data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}\n\n'; then check false; else check contains "$REMOTE_ERROR" 'Responses incomplete: max_output_tokens'; fi
close_stream

if [[ -r "$ZCHAT_ZCURL_LOADER" ]] && { [[ "$ZCHAT_ZCURL_LOADER" != "$ROOT/vendor/zcurl/zcurl.zsh" ]] || [[ -r "$ROOT/vendor/zcurl/build/zcurl.so" ]]; }; then
  python3 "$ROOT/tests/fixtures/remote_server.py" "$API_RUNTIME_DIR/port" &
  fixture_pid=$!
  for i in {1..100}; do [[ -s "$API_RUNTIME_DIR/port" ]] && break; zselect -t 2; done
  zchat_read_file "$API_RUNTIME_DIR/port"; port=$REPLY
  config="${config//https:\/\/example.test/http:\/\/127.0.0.1:$port}"
  zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$config" 0600
  check remote_load_config
  for protocol in chat responses messages; do
    SESSION_MODEL=remote:$protocol
    check remote_profile
    remote_payload "$source_payload"
    check remote_start_stream "$REPLY" "$API_RUNTIME_DIR/stream"
    [[ -n "$API_STREAM_PID" ]] || continue
    wait "$API_STREAM_PID"
    check api_stream_collect "$API_STREAM_PID" "$API_RUNTIME_DIR/stream"
    [[ -z "$API_STREAM_ERROR" ]] || print -r -- "$API_STREAM_ERROR"
    zchat_read_file "$API_RUNTIME_DIR/stream.content"; check eq "$REPLY" 'fixture reply 🌍'
    zchat_read_file "$API_RUNTIME_DIR/stream.usage"; check eq "$REPLY" '9 2'
  done
  # Test realistic Responses lifecycle streams and compatible gateway endings.
  for case_name in responses-done responses-gzip responses-json-error responses-sse-error responses-failed responses-incomplete responses-truncated responses-early-done responses-bad-completed; do
    case_config="${config//\/responses/\/$case_name}"
    zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$case_config" 0600
    check remote_load_config
    SESSION_MODEL=remote:responses
    check remote_profile
    remote_payload "$source_payload"
    check remote_start_stream "$REPLY" "$API_RUNTIME_DIR/responses"
    wait "$API_STREAM_PID"
    if [[ "$case_name" == responses-done || "$case_name" == responses-gzip ]]; then
      check api_stream_collect "$API_STREAM_PID" "$API_RUNTIME_DIR/responses"
      zchat_read_file "$API_RUNTIME_DIR/responses.content"; check eq "$REPLY" 'fixture reply 🌍'
      zchat_read_file "$API_RUNTIME_DIR/responses.thinking"; check eq "$REPLY" 'fixture thought'
      zchat_read_file "$API_RUNTIME_DIR/responses.usage"; check eq "$REPLY" '9 2'
    else
      if api_stream_collect "$API_STREAM_PID" "$API_RUNTIME_DIR/responses"; then check false; else check true; fi
      case "$case_name" in
        responses-json-error) check eq "$API_STREAM_ERROR" 'Remote HTTP 400: Unknown model (code: model_not_found) (param: model)' ;;
        responses-sse-error) check eq "$API_STREAM_ERROR" 'Bad input (code: invalid_request) (param: input)' ;;
        responses-failed) check eq "$API_STREAM_ERROR" 'Responses failed: Upstream failed (code: server_error)' ;;
        responses-incomplete) check contains "$API_STREAM_ERROR" 'output budget includes reasoning tokens' ;;
        responses-truncated) check contains "$API_STREAM_ERROR" 'closed before response.completed' ;;
        responses-early-done) check contains "$API_STREAM_ERROR" '[DONE] before response.completed' ;;
        responses-bad-completed) check contains "$API_STREAM_ERROR" 'Invalid response.completed event' ;;
      esac
    fi
  done
  zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$config" 0600
  check remote_load_config

  # Remote compaction uses a remote request and persists the checkpoint.
  ZCHAT_SESSIONS_DIR="$API_RUNTIME_DIR/sessions"
  ZCHAT_CONFIG_FILE="$API_RUNTIME_DIR/config.json"
  zf_mkdir -p "$ZCHAT_SESSIONS_DIR"
  check state_new_session remote:chat 'Be helpful'
  check state_append_message user 'Remember this exact request'
  check state_append_message assistant 'A previous reply'
  check backend_compact_history manual
  check eq "$CHAT_COMPACTION_SUMMARY" 'fixture reply 🌍'
  check eq "$CHAT_COMPACTION_COUNT" 1
  check state_load_session "$CURRENT_SESSION_ID"
  check eq "$SESSION_MODEL" remote:chat
  check eq "$CHAT_COMPACTION_SUMMARY" 'fixture reply 🌍'
  check backend_prepare_payload
  check remote_json_parse "$REPLY"
  check eq "${REMOTE_JSON[/model]}" some-model
  SESSION_MODEL=local-test-model
  ZCHAT_CONTEXT_WINDOW=8192
  check chat_context_configure
  check eq "$CHAT_CONTEXT_WINDOW" 8192
  SESSION_MODEL=remote:chat
  check backend_prepare_payload
  check eq "$CHAT_CONTEXT_WINDOW" 65536
  ZCHAT_CONTEXT_WINDOW=auto

  # The worker must reject HTTP errors, redirects, malformed SSE and EOF before
  # the protocol's final event, rather than silently saving a successful reply.
  for case_name in http-error redirect malformed api-error truncated slow; do
    case_config="${config//chat\/completions/$case_name}"
    zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$case_config" 0600
    remote_load_config
    SESSION_MODEL=remote:chat
    remote_profile
    remote_payload "$source_payload"
    check remote_start_stream "$REPLY" "$API_RUNTIME_DIR/failure"
    if [[ "$case_name" == slow ]]; then
      check api_stream_open_readers "$API_RUNTIME_DIR/failure"
      observed=''
      for i in {1..100}; do
        api_stream_read_updates
        observed+="$API_STREAM_CONTENT_DELTA"
        [[ -n "$observed" ]] && break
        zselect -t 2
      done
      check eq "$observed" partial
      check kill -0 "$API_STREAM_PID"
      cancelled_pid="$API_STREAM_PID"
      api_stop_stream "$API_STREAM_PID"
      if kill -0 "$cancelled_pid" 2>/dev/null; then check false; else check true; fi
    else
      wait "$API_STREAM_PID"
      if api_stream_collect "$API_STREAM_PID" "$API_RUNTIME_DIR/failure"; then check false; else check true; fi
      case "$case_name" in
        http-error) check contains "$API_STREAM_ERROR" 'Remote HTTP 401:' ;;
        api-error) check eq "$API_STREAM_ERROR" 'fixture overloaded' ;;
        malformed) check eq "$API_STREAM_ERROR" 'Invalid JSON in remote stream' ;;
        truncated) check eq "$API_STREAM_ERROR" 'Remote connection closed before its final event' ;;
      esac
    fi
  done
  if (( $+commands[openssl] )); then
    kill "$fixture_pid"
    wait "$fixture_pid" 2>/dev/null
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$API_RUNTIME_DIR/key.pem" \
      -out "$API_RUNTIME_DIR/cert.pem" -days 1 -subj '/CN=127.0.0.1' \
      -addext 'subjectAltName=IP:127.0.0.1' >/dev/null 2>&1 || exit 1
    python3 "$ROOT/tests/fixtures/remote_server.py" "$API_RUNTIME_DIR/tls-port" \
      "$API_RUNTIME_DIR/cert.pem" "$API_RUNTIME_DIR/key.pem" &
    fixture_pid=$!
    for i in {1..100}; do [[ -s "$API_RUNTIME_DIR/tls-port" ]] && break; zselect -t 2; done
    zchat_read_file "$API_RUNTIME_DIR/tls-port"; tls_port=$REPLY
    tls_config="${config//$port/$tls_port}"
    tls_config="${tls_config//http:/https:}"
    for trust in no yes; do
      if [[ "$trust" == yes ]]; then
        tls_config="${tls_config//\"auth\":\"none\"/\"auth\":\"none\",\"ca_file\":\"$API_RUNTIME_DIR/cert.pem\"}"
      fi
      zchat_atomic_write "$ZCHAT_REMOTE_CONFIG" "$tls_config" 0600
      remote_load_config
      SESSION_MODEL=remote:chat
      remote_profile
      remote_payload "$source_payload"
      check remote_start_stream "$REPLY" "$API_RUNTIME_DIR/tls"
      wait "$API_STREAM_PID"
      if [[ "$trust" == yes ]]; then
        check api_stream_collect "$API_STREAM_PID" "$API_RUNTIME_DIR/tls"
        zchat_read_file "$API_RUNTIME_DIR/tls.content"; check eq "$REPLY" 'fixture reply 🌍'
      else
        if api_stream_collect "$API_STREAM_PID" "$API_RUNTIME_DIR/tls"; then check false; else check true; fi
        check contains "$API_STREAM_ERROR" 'certificate'
      fi
    done
  fi
else
  print -r -- 'SKIP remote integration: run make zcurl, or set ZCHAT_ZCURL_LOADER to a compatible built module loader'
fi
# Every non-remote entrypoint delegates with the original arguments and status.
(
  SESSION_MODEL=gemma4:12b
  chat_prepare_payload() { REPLY=ollama; return 7; }
  backend_prepare_payload
  [[ $? == 7 && "$REPLY" == ollama ]] || exit 1
  chat_compact_history() { [[ "$1" == manual ]]; }
  backend_compact_history manual || exit 1
  chat_context_summary() { REPLY=local-context; }
  backend_context_summary
  [[ "$REPLY" == local-context ]] || exit 1
  api_start_stream() { [[ "$1" == host && "$2" == payload && "$3" == base ]]; }
  backend_start_stream host payload base || exit 1
  chat_record_response_usage() { [[ "$1" == payload && "$2" == 12 && "$3" == 3 ]]; }
  backend_record_response_usage payload 12 3
)
check eq "$?" 0
print -r -- "$checks remote checks, $failures failures"
(( failures == 0 ))
