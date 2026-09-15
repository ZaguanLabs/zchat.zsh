# Exercise the actual TCP consumers, including done:true inside truncated HTTP.
() {
  emulate -L zsh
  setopt extendedglob nomultibyte
  local listener='' peer='' worker='' response='' request='' byte='' base="$TEST_STATE_DIR/http-transport"
  local -i port attempt payload_length held=0 result
  local -F deadline
  for (( attempt=0; attempt<20; attempt++ )); do
    port=$(( 20000 + RANDOM ))
    if ztcp -l "$port" 2>/dev/null; then listener=$REPLY; break; fi
  done
  [[ -n $listener ]] || { fail 'test HTTP listener opens'; return; }
  _chat_http_server() {
    trap - EXIT INT TERM HUP
    ztcp -a "$listener" || return 1
    peer=$REPLY
    request=''
    while [[ $request != *$'\r\n\r\n'* ]]; do
      sysread -i "$peer" -s 1 -t 3 byte || return 1
      request+=$byte
    done
    payload_length=${${request#*Content-Length: }%%$'\r\n'*}
    if (( payload_length > 0 )); then
      sysread -i "$peer" -s "$payload_length" -t 3 byte || return 1
    fi
    zchat_write_all "$peer" "$response" || return 1
    if (( held )); then
      deadline=$(( EPOCHREALTIME + 3 ))
      while [[ ! -f $base.collected ]] && (( EPOCHREALTIME < deadline )); do zselect -t 1; done
      [[ -f $base.collected ]] || print -r -- timed-out > "$base.wait"
    fi
    ztcp -c "$peer"
  }
  {
    held=1
    response=$'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}'
    _chat_http_server & worker=$!
    _api_http_request GET /api/tags '' "localhost:$port" 1 1024
    result=$?
    print -r -- done > "$base.collected"
    wait "$worker"
    assert_eq 0 "$result" 'metadata completes on Content-Length while the server keeps its socket open'
    assert_eq '{}' "$API_HTTP_BODY" 'real metadata HTTP returns exactly its framed body'
    [[ ! -f $base.wait ]]
    assert_eq 0 "$?" 'metadata client does not depend on EOF'
    held=0
    local record=$'{"message":{"content":"hello"},"done":true}\n'
    local framing
    for framing in valid truncated extra; do
      response=$'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
      printf -v byte '%x' "${#record}"
      response+="$byte"$'\r\n'"$record"$'\r\n'
      [[ $framing != truncated ]] && response+=$'0\r\n\r\n'
      [[ $framing == extra ]] && response+=garbage
      _chat_http_server & worker=$!
      _api_http_stream "localhost:$port" '{}' "$base.thinking" "$base.content" "$base.error" "$base.usage"
      result=$?
      wait "$worker"
      if [[ $framing == valid ]]; then
        assert_eq 0 "$result" 'real streaming request accepts a complete framed done:true response'
        assert_eq hello "${mapfile[$base.content]}" 'stream worker publishes decoded assistant text'
      else
        assert_eq 1 "$result" "$framing HTTP fails even when Ollama emitted done:true"
      fi
    done
  } always {
    [[ -n $worker ]] && kill "$worker" 2>/dev/null
    ztcp -c "$listener"
    unfunction _chat_http_server
  }
}
