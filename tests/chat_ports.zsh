() {
  local ZCHAT_CONFIG_DIR="$TEST_STATE_DIR/ui preferences"
  local -i UI_SIDEBAR_HIDDEN=0 UI_PREFERENCES_LOADED=0
  local saved_move=${functions[zf_mv]-} value=''
  local -a scratch=()
  local -A file_info=()
  ui_preferences_load
  assert_eq 0 "$UI_SIDEBAR_HIDDEN" 'missing UI preferences keep the sidebar visible by default'
  [[ ! -e $ZCHAT_CONFIG_DIR ]]
  assert_status_ok 'loading default UI preferences does not create configuration files' $?
  UI_SIDEBAR_HIDDEN=1
  ui_preferences_save
  assert_status_ok 'sidebar preferences save in a new configuration directory with spaces' $?
  assert_eq $'sidebar_hidden=1\n' "${mapfile[$ZCHAT_CONFIG_DIR/ui-preferences]}" 'sidebar preferences contain literal data'
  zstat -H file_info "$ZCHAT_CONFIG_DIR/ui-preferences"
  assert_eq 0 "$(( file_info[mode] & 077 ))" 'UI preferences are private to the user'

  UI_SIDEBAR_HIDDEN=0; UI_PREFERENCES_LOADED=0
  ui_preferences_load
  assert_eq 1 "$UI_SIDEBAR_HIDDEN" 'saved hidden preference is restored'
  mapfile[$ZCHAT_CONFIG_DIR/ui-preferences]=$'sidebar_hidden=0\n'
  ui_preferences_load
  assert_eq 1 "$UI_SIDEBAR_HIDDEN" 'curses reentry does not import another TUI instance change'
  UI_PREFERENCES_LOADED=0
  ui_preferences_load
  assert_eq 0 "$UI_SIDEBAR_HIDDEN" 'a new launch restores the latest explicit visible preference'
  for value in 'sidebar_hidden=1+1' 'sidebar_hidden=$(print executed > "$ZCHAT_CONFIG_DIR/executed")' 'unknown=1'; do
    mapfile[$ZCHAT_CONFIG_DIR/ui-preferences]="$value"
    UI_PREFERENCES_LOADED=0
    ui_preferences_load
    assert_eq 0 "$UI_SIDEBAR_HIDDEN" 'invalid and unknown preference values are ignored as data'
  done
  [[ ! -e $ZCHAT_CONFIG_DIR/executed ]]
  assert_status_ok 'loading UI preferences never executes shell text' $?

  mapfile[$ZCHAT_CONFIG_DIR/ui-preferences]=$'sidebar_hidden=1\n'
  zf_mv() { return 1; }
  {
    ui_preferences_save
    assert_eq 1 "$?" 'failed preference publication reports failure'
    assert_eq $'sidebar_hidden=1\n' "${mapfile[$ZCHAT_CONFIG_DIR/ui-preferences]}" 'failed publication preserves the previous preference'
    scratch=("$ZCHAT_CONFIG_DIR"/*.tmp(N))
    assert_eq 0 "${#scratch}" 'failed publication removes its temporary file'
  } always {
    if [[ -n $saved_move ]]; then functions[zf_mv]=$saved_move; else unfunction zf_mv; fi
  }
}

() {
  emulate -L zsh
  setopt extendedglob nomultibyte
  local packet='' byte='' output='' header=$'HTTP/1.1 200 OK\r\n'
  local -i result=0
  packet="${header}"$'Transfer-Encoding: chunked\r\n\r\n3\r\n界\r\n2;ext=yes\r\nOK\r\n0\r\nX-End: yes\r\n\r\n'
  api_http_frame_reset
  for byte in "${(@s::)packet}"; do
    api_http_frame_feed "$byte" || result=1
    output+=$API_FRAME_OUTPUT
  done
  api_http_frame_finish || result=1
  assert_eq 0 "$result" 'chunked HTTP tolerates every TCP/UTF-8 split'
  assert_eq '界OK' "$output" 'incremental framing preserves exact response bytes'
  api_http_frame_reset
  api_http_frame_feed "${header}"$'Transfer-Encoding: chunked\r\n\r\n100\r\nhello'
  assert_eq hello "$API_FRAME_OUTPUT" 'large HTTP chunks publish their available prefix immediately'
  api_http_frame_finish
  assert_eq 1 "$?" 'EOF inside a chunk fails instead of accepting partial text'
  for packet in \
    $'Content-Length: 3\r\nContent-Length: 3\r\n\r\nabc' \
    $'Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n' \
    $'Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n' \
    $'Transfer-Encoding: gzip\r\n\r\n' \
    $'Content-Length: 3\r\n\r\nabcd' \
    $'Transfer-Encoding: chunked\r\n\r\n1\r\nx!!'; do
    api_http_frame_reset
    api_http_frame_feed "$header$packet"
    assert_eq 1 "$?" 'malformed or ambiguous HTTP framing fails closed'
  done
  api_http_frame_reset 3
  api_http_frame_feed "${header}"$'Content-Length: 4\r\n\r\n'
  assert_eq 1 "$?" 'Content-Length respects the request-specific body limit'
  api_http_frame_reset
  api_http_frame_feed "${header}"$'Content-Length: 2\r\n\r\nOK'
  assert_eq done "$API_FRAME_STATE" 'fixed-length HTTP completes without waiting for socket close'
  api_http_frame_reset
  api_http_frame_feed "${header}"$'\r\nOK'
  api_http_frame_finish
  assert_eq 0 "$?" 'close-delimited HTTP remains supported'

  local -i tfd cfd efd ufd API_STREAM_SAW_DONE=0
  local API_NDJSON_BUFFER='' API_IN_THINK_TAG=0
  exec {tfd}>/dev/null {cfd}>/dev/null {efd}>/dev/null {ufd}>/dev/null
  _api_consume_ndjson $'{"message":{"content":"ok"},"done":true}\n' "$tfd" "$cfd" "$efd" "$ufd"
  assert_eq 0 "$?" 'final Ollama record is accepted'
  _api_consume_ndjson $'{"message":{"content":"late"},"done":false}\n' "$tfd" "$cfd" "$efd" "$ufd"
  assert_eq 1 "$?" 'Ollama data after done:true is rejected'
  API_STREAM_SAW_DONE=0
  _api_process_event_line '{"message":{"content":"x"},"done":"true"}' "$tfd" "$cfd" "$efd" "$ufd"
  assert_eq 1 "$?" 'stream events require a boolean done field'
  exec {tfd}>&- {cfd}>&- {efd}>&- {ufd}>&-
}

() {
  emulate -L zsh
  local -i UI_ACTIVE=0 SCREEN_H=24 SCREEN_W=80 UI_SMALL_SCREEN=0
  local STREAM_PID='' FOCUS_PANE=input ch='' sequence=''
  input_reset
  INPUT_BUF=/co; INPUT_POS=3
  ui_calculate_input_height
  assert_eq '/copy|/compact|/context' "${(j:|:)UI_SLASH_TEXTS}" 'slash suggestions contain only matching chat commands'
  ui_slash_input '' DOWN
  ui_slash_input $'\t' ''
  assert_eq /compact "$INPUT_BUF" 'Tab completes the selected command without submitting it'
  assert_eq '' "$INPUT_SUBMITTED" 'completion never dispatches a command'
  assert_eq 0 "$UI_SLASH_ROWS" 'completion closes its suggestion rows'
  INPUT_BUF=/help; INPUT_POS=5
  ui_calculate_input_height
  ui_slash_input $'\n' ''
  assert_eq 1 "$?" 'Enter on a complete command reaches ordinary dispatch'
  INPUT_BUF='/host localhost'; INPUT_POS=${#INPUT_BUF}
  ui_calculate_input_height
  assert_eq 0 "$UI_SLASH_ROWS" 'command arguments keep normal editor navigation'
  INPUT_BUF='/'; INPUT_POS=1; SCREEN_H=12
  ui_calculate_input_height
  (( INPUT_H + TOP_H + FOOT_H + 3 <= SCREEN_H ))
  assert_eq 0 "$?" 'suggestions leave room for chat at the minimum terminal height'
  input_reset
  input_sanitize_paste $'a\r\nb\t\x00\x03\e\x7f'
  assert_eq $'a\nb    ' "$REPLY" 'paste strips controls while retaining paragraphs and spacing'
  sequence=$'\e[200~hello\x03\r\nworld\e[201~'
  for ch in "${(@s::)sequence}"; do input_decode_terminal_event "$ch" ''; done
  assert_eq $'hello\nworld' "$INPUT_EVENT_TEXT" 'legacy paste sanitizes controls before insertion'
  input_reset
  sequence=$'\e[200~'
  for ch in "${(@s::)sequence}"; do input_decode_terminal_event "$ch" ''; done
  INPUT_PASTE_BYTES=1048576
  sequence=$'x\e[201~'
  for ch in "${(@s::)sequence}"; do input_decode_terminal_event "$ch" ''; done
  assert_eq paste_rejected "$INPUT_EVENT_ACTION" 'legacy oversized paste drains before reporting rejection'
  assert_eq 0 "${#INPUT_PASTE_CHUNKS}" 'rejected paste releases buffered chunks'
  input_reset
}

() {
  emulate -L zsh
  local -i TERMINAL_PASTE_LIMIT=4 TERMINAL_DISCARD_PASTE=0 TERMINAL_PASTE_DISCARDING=0
  local TERMINAL_EVENT_TEXT=''
  _terminal_paste_event begin ''
  _terminal_paste_event data 1234
  _terminal_paste_event end 5
  assert_eq PASTE_REJECTED "$REPLY" 'native paste enforces its byte limit across records'
  _terminal_paste_event begin ''
  _terminal_paste_event data $'\xc3'
  _terminal_paste_event end $'\xa9'
  input_decode_terminal_event '' "$REPLY"
  assert_eq é "$INPUT_EVENT_TEXT" 'native paste joins split UTF-8 before editor normalization'
  TERMINAL_DISCARD_PASTE=1
  _terminal_paste_event begin ''
  TERMINAL_DISCARD_PASTE=0
  TERMINAL_EVENT_TEXT=''
  _terminal_paste_event end y
  assert_eq PASTE_PENDING "$REPLY" 'a paste begun in a dialog stays discarded after the dialog closes'
  assert_eq '' "$TERMINAL_EVENT_TEXT" 'discarded dialog paste never reaches the prompt'
}
