# Incremental HTTP body framing, adapted from zcoder's stream decoder.
# Feed bytes, consume API_FRAME_OUTPUT, then finish at EOF. Limits and framing
# are checked before Ollama records can be committed to a conversation.
typeset -g API_FRAME_WIRE="" API_FRAME_STATE=headers API_FRAME_OUTPUT=""
typeset -gi API_FRAME_LEFT=0 API_FRAME_BYTES=0 API_FRAME_LIMIT=0

api_http_frame_reset() {
  API_FRAME_WIRE=""; API_FRAME_STATE=headers; API_FRAME_OUTPUT=""
  API_FRAME_LEFT=0; API_FRAME_BYTES=0
  API_FRAME_LIMIT=${1:-$API_MAX_STREAM_BYTES}
}

api_http_frame_feed() {
  emulate -L zsh
  setopt extendedglob nomultibyte
  local header="" line="" key="" value="" length="" encoding="" part=""
  local -i take=0 encoding_seen=0
  API_FRAME_OUTPUT=""
  API_FRAME_WIRE+="$1"
  while true; do
    case "$API_FRAME_STATE" in
      headers)
        if [[ "$API_FRAME_WIRE" != *$'\r\n\r\n'* ]]; then
          (( ${#API_FRAME_WIRE} <= API_MAX_HEADER_BYTES )) || { API_HTTP_ERROR="Ollama response headers exceed the header limit"; return 1; }
          return 0
        fi
        header="${API_FRAME_WIRE%%$'\r\n\r\n'*}"
        (( ${#header} <= API_MAX_HEADER_BYTES )) || { API_HTTP_ERROR="Ollama response headers exceed the header limit"; return 1; }
        API_FRAME_WIRE="${API_FRAME_WIRE[$(( ${#header}+5 )),-1]}"
        line="${header%%$'\r\n'*}"
        [[ "$line" == HTTP/1.[01]' '2[0-9][0-9]' '* ]] || { API_HTTP_ERROR="Ollama HTTP error: $line"; return 1; }
        for line in "${(@f)${header//$'\r'/}}"; do
          [[ "$line" == *:* ]] || continue
          key="${(L)${line%%:*}}"; value="${line#*:}"
          value="${value##[[:space:]]#}"; value="${value%%[[:space:]]#}"
          case "$key" in
            content-length)
              [[ "$value" == <0-> && ${#value} -le 9 && -z "$length" ]] || { API_HTTP_ERROR="invalid streaming Content-Length"; return 1; }
              length="$value" ;;
            transfer-encoding)
              (( ! encoding_seen )) || { API_HTTP_ERROR="duplicate HTTP Transfer-Encoding"; return 1; }
              encoding_seen=1; encoding="${value:l}"
              [[ -n "$encoding" ]] || { API_HTTP_ERROR="empty HTTP Transfer-Encoding"; return 1; } ;;
          esac
        done
        if [[ "$encoding" == chunked && -z "$length" ]]; then API_FRAME_STATE=size
        elif [[ -n "$encoding" ]]; then API_HTTP_ERROR="unsupported streaming HTTP transfer framing"; return 1
        elif [[ -n "$length" ]]; then API_FRAME_STATE=length; API_FRAME_LEFT=$(( 10#$length )); (( API_FRAME_LEFT <= API_FRAME_LIMIT )) || { API_HTTP_ERROR="HTTP body exceeds the body limit"; return 1; }
        else API_FRAME_STATE=close
        fi
        ;;
      size)
        if [[ "$API_FRAME_WIRE" != *$'\r\n'* ]]; then
          (( ${#API_FRAME_WIRE} <= 1024 )) || { API_HTTP_ERROR="invalid streaming chunk header"; return 1; }
          return 0
        fi
        line="${API_FRAME_WIRE%%$'\r\n'*}"
        (( ${#line} <= 1024 )) || { API_HTTP_ERROR="invalid streaming chunk header"; return 1; }
        API_FRAME_WIRE="${API_FRAME_WIRE[$(( ${#line}+3 )),-1]}"
        value="${line%%;*}"
        [[ "$value" == [[:xdigit:]]## && ${#value} -le 8 ]] || { API_HTTP_ERROR="invalid streaming chunk size"; return 1; }
        API_FRAME_LEFT=$(( 16#$value ))
        (( API_FRAME_LEFT <= API_MAX_HTTP_CHUNK_BYTES && API_FRAME_LEFT <= API_FRAME_LIMIT )) || { API_HTTP_ERROR="streaming chunk exceeds the body limit"; return 1; }
        (( API_FRAME_LEFT )) && API_FRAME_STATE=chunk || API_FRAME_STATE=trailers
        ;;
      length|chunk|close)
        if [[ "$API_FRAME_STATE" != close ]] && (( API_FRAME_LEFT == 0 )); then
          [[ "$API_FRAME_STATE" == length ]] && API_FRAME_STATE=done || API_FRAME_STATE=crlf
          continue
        fi
        take=${#API_FRAME_WIRE}
        (( take > 0 )) || return 0
        [[ "$API_FRAME_STATE" != close ]] && (( take > API_FRAME_LEFT )) && take=$API_FRAME_LEFT
        (( API_FRAME_BYTES+=take ))
        (( API_FRAME_BYTES <= API_FRAME_LIMIT )) || { API_HTTP_ERROR="Ollama stream exceeds the body limit"; return 1; }
        API_FRAME_OUTPUT+="${API_FRAME_WIRE[1,take]}"
        API_FRAME_WIRE="${API_FRAME_WIRE[$(( take+1 )),-1]}"
        [[ "$API_FRAME_STATE" == close ]] || (( API_FRAME_LEFT-=take ))
        ;;
      crlf)
        (( ${#API_FRAME_WIRE} >= 2 )) || return 0
        [[ "${API_FRAME_WIRE[1,2]}" == $'\r\n' ]] || { API_HTTP_ERROR="invalid streaming chunk terminator"; return 1; }
        API_FRAME_WIRE="${API_FRAME_WIRE[3,-1]}"; API_FRAME_STATE=size
        ;;
      trailers)
        (( ${#API_FRAME_WIRE} <= API_MAX_HEADER_BYTES )) || { API_HTTP_ERROR="streaming trailers exceed the header limit"; return 1; }
        if [[ "$API_FRAME_WIRE" == $'\r\n'* ]]; then
          API_FRAME_WIRE="${API_FRAME_WIRE[3,-1]}"; API_FRAME_STATE=done
        elif [[ "$API_FRAME_WIRE" == *$'\r\n\r\n'* ]]; then
          API_FRAME_WIRE="${API_FRAME_WIRE#*$'\r\n\r\n'}"; API_FRAME_STATE=done
        else
          return 0
        fi
        ;;
      done)
        [[ -z "$API_FRAME_WIRE" ]] || { API_HTTP_ERROR="unexpected bytes after streaming HTTP body"; return 1; }
        return 0 ;;
    esac
  done
}

api_http_frame_finish() {
  [[ "$API_FRAME_STATE" == done || "$API_FRAME_STATE" == close ]] && return 0
  API_HTTP_ERROR="Ollama closed an incomplete streaming HTTP response"
  return 1
}
