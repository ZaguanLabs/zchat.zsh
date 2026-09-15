# Display-cell geometry must preserve original character offsets for editing.
input_reset
input_insert $'界e\u0301Z'
input_layout 3 4
assert_eq $'界e\u0301' "$INPUT_VISUAL_LINES[1]" 'wrapping keeps combining marks with their base'
assert_eq Z "$INPUT_VISUAL_LINES[2]" 'wide text wraps at terminal cells'
assert_eq 1 "$INPUT_CURSOR_COL" 'cursor column counts cells on wrapped row'
input_move_vertical -1 3 4
assert_eq 0 "$INPUT_POS" 'vertical movement never lands inside a wide glyph'
input_reset
input_insert '界'
input_layout 1 4
assert_eq '?' "$INPUT_VISUAL_LINES[1]" 'one-cell editor represents an oversized glyph safely'
assert_eq 1 "$INPUT_VISUAL_STARTS[2]" 'oversized glyph still consumes one original character'
zchat_pad_right $'界e\u0301' 5
assert_eq $'界e\u0301  ' "$REPLY" 'padding counts cells and preserves combining marks'
zchat_clip '界Z' 1
assert_eq '' "$REPLY" 'clipping does not split a wide glyph'
input_reset
input_insert $'first\tsecond  '
input_kill_word
assert_eq $'first\t' "$INPUT_BUF" 'word deletion handles trailing whitespace and tabs'
input_reset
input_sequence=$'\e[200~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ''; done
typeset paste_body="${(pl:700::a:)}"$'\r\nlast'
for input_byte in ${(s::)paste_body}; do input_decode_terminal_event "$input_byte" ''; done
input_sequence=$'\e[201~'
for input_byte in ${(s::)input_sequence}; do input_decode_terminal_event "$input_byte" ''; done
assert_eq "${(pl:700::a:)}"$'\nlast' "$INPUT_EVENT_TEXT" 'chunked paste preserves text across delimiter boundaries'
assert_eq paste "$INPUT_EVENT_ACTION" 'large paste completes as one editor event'
