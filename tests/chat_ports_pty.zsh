# Headless Unicode boundary tests use the actual selected native module.
() {
  local backend output
  for backend in "${drawing_backends[@]}"; do
    output=$(LC_ALL=C.UTF-8 zsh -df "$TEST_DIR/fixtures/grapheme_input.zsh" "$PROJECT_DIR" "$backend" 2>&1)
    assert_status_ok "$backend Unicode editor: $output" $?
  done
}

# Real structured/legacy input, with fragmented paste and terminal teardown.
() {
  local backend base chunk='' output=''
  local -i sent=0 copy_sent=0
  local -F deadline
  _chat_input_fixture() {
    trap - EXIT INT TERM HUP
    export TERM=xterm-256color LC_ALL=C.UTF-8 ZCHAT_SYNC_OUTPUT=auto
    exec zsh -df "$TEST_DIR/fixtures/chat_input.zsh" "$PROJECT_DIR" "$base" "$backend"
  }
  for backend in "${drawing_backends[@]}"; do
    base="$TEST_STATE_DIR/chat-input-$backend"
    sent=0; copy_sent=0; output=''
    zpty -b chat-input _chat_input_fixture
    deadline=$(( EPOCHREALTIME + 10 ))
    while (( EPOCHREALTIME < deadline )); do
      while zpty -r chat-input chunk 2>/dev/null; do output+=$chunk; done
      if [[ -f $base.ready ]] && (( ! sent )); then
        zpty -w -n chat-input $'\e[?2026;2$y'
        if [[ $backend == auto ]]; then
          zpty -w -n chat-input $'\e[200~first\r\nsecond\t'
        else
          # Stock cbreak translates CR before the application receives it.
          zpty -w -n chat-input $'\e[200~first\nsecond\t'
        fi
        if [[ $backend == auto ]]; then
          zpty -w -n chat-input $'e\u0301👩‍💻\x03\e[201~'
        else
          zpty -w -n chat-input $'e\u0301👩‍💻\a\e[201~'
        fi
        sent=1
      fi
      if [[ "$output" == *'Press Enter to return: '* ]] && (( ! copy_sent )); then
        zpty -w -n chat-input $'\n'
        copy_sent=1
      fi
      [[ -f $base.exit ]] && break
      zselect -t 1
    done
    assert_eq 0 "${mapfile[$base.exit]:-missing}" "$backend real paste, sidebar and command UI complete"
    assert_eq $'first\nsecond    e\u0301👩‍💻' "${mapfile[$base.text]:-}" "$backend paste stays one inert multiline editor action"
    assert_contains "${mapfile[$base.sync]:-}" supported "$backend capability reply activates synchronized presentation"
    assert_contains "$output" $'\e[?2026h' "$backend synchronized output emits a frame boundary"
    assert_eq 1 "${mapfile[$base.copy]:-}" "$backend copy view restores the terminal and draft"
    assert_eq 1 "${mapfile[$base.ui]:-}" "$backend sidebar and slash rows fit the real curses windows"
    zpty -d chat-input
  done
  unfunction _chat_input_fixture
}
