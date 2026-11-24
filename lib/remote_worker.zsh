#!/usr/bin/env zsh
# Exec boundary: zcurl must own its module in a fresh process, not inherit it.
emulate -R zsh
setopt extendedglob no_nomatch
zmodload zsh/system zsh/files zsh/datetime || exit 1
umask 077
local_dir="${0:A:h}"
source "$local_dir/util.zsh"
source "$local_dir/json.zsh"
source "$local_dir/remote.zsh"
source "$local_dir/remote_stream.zsh"
typeset -g remote_base="$1" SESSION_MODEL="$2"
typeset -g ZCHAT_REMOTE_CONFIG="$remote_base.config"
typeset -g remote_loader="$3"
typeset -gi remote_result=1 remote_content_fd=-1 remote_thinking_fd=-1 remote_output_fd=-1 remote_read_fd=-1
remote_worker_finish() {
  [[ -n "$REMOTE_ERROR" ]] && zchat_atomic_write "$remote_base.err" "$REMOTE_ERROR" 0600
  zchat_atomic_write "$remote_base.usage" "$REMOTE_INPUT_TOKENS $REMOTE_OUTPUT_TOKENS" 0600
  zchat_atomic_write "$remote_base.status" "$remote_result" 0600
  zchat_atomic_write "$remote_base.done" DONE 0600
}
trap remote_worker_finish EXIT
trap 'REMOTE_ERROR="Remote request cancelled"; exit 130' INT TERM HUP

remote_worker_run() {
  local payload chunk='' rc=0
  local -A event=() response=()
  remote_load_config && remote_profile || return 1
  source "$remote_loader" || { REMOTE_ERROR='Could not load zcurl (check module build and Zsh compatibility)'; return 1; }
  zchat_read_file "$remote_base.request" 67108864 || { REMOTE_ERROR='Cannot read remote request'; return 1; }
  payload="$REPLY"
  exec {remote_content_fd}>"$remote_base.content" {remote_thinking_fd}>"$remote_base.thinking" \
    {remote_output_fd}>"$remote_base.wire" {remote_read_fd}<"$remote_base.wire" || return 1
  if ! zcurl http submit zchat --result response --fail --compressed --timeout 300000 --max-body 67108864 \
    --header 'Content-Type: application/json' --header 'Accept: text/event-stream' \
    "${REMOTE_HEADERS[@]}" "${REMOTE_OPTIONS[@]}" --data "$payload" --output-fd "$remote_output_fd" -- "$REMOTE_URL"; then
    REMOTE_ERROR="zcurl: ${response[error]:-could not submit request}"
    return 1
  fi
  while true; do
    zcurl http poll --result event --timeout 50 || { REMOTE_ERROR='zcurl polling failed'; return 1; }
    while true; do
      chunk=''
      sysread -i "$remote_read_fd" -s 32768 chunk 2>/dev/null
      rc=$?
      [[ -z "$chunk" ]] || remote_sse_feed "$chunk" || { zcurl http drop zchat; return 1; }
      (( rc == 5 )) && break
      (( rc == 0 )) || { REMOTE_ERROR='Could not read remote stream'; return 1; }
    done
    [[ "${event[event]}" == ready ]] && break
  done
  zcurl http collect zchat --result response
  rc=$?
  if (( rc != 0 )) || [[ "${response[http_status]}" != 2[0-9][0-9] ]]; then
    remote_http_error "${response[http_status]}" "${response[error]}" "$remote_base.wire"
    return 1
  fi
  # Dispatch a final CR-terminated blank line, but never invent a missing SSE
  # event separator: a truncated event is not a completed response.
  [[ "$REMOTE_SSE_BUFFER" != *$'\r' ]] || remote_sse_feed $'\n' || return 1
  if (( ! REMOTE_DONE )); then
    if [[ "$REMOTE_PROTOCOL" == responses ]]; then
      REMOTE_ERROR='Responses stream closed before response.completed (the endpoint may not support Responses SSE)'
    else
      REMOTE_ERROR='Remote connection closed before its final event'
    fi
    return 1
  fi
  [[ -z "$REMOTE_SSE_DATA" && -z "${REMOTE_SSE_BUFFER//[[:space:]]/}" ]] || { REMOTE_ERROR='Truncated remote SSE event'; return 1; }
  return 0
}
remote_worker_run && remote_result=0
exit "$remote_result"
