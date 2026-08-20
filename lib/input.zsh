# lib/input.zsh - Input line editor and history for zchat

typeset -g INPUT_BUF=""
typeset -g INPUT_POS=0
typeset -ga INPUT_HIST=()
typeset -g INPUT_HIST_IDX=0
typeset -g INPUT_DRAFT=""
typeset -g INPUT_LAST_SUBMITTED=""

input_init() {
  INPUT_BUF=""
  INPUT_POS=0
  INPUT_HIST_IDX=0
  INPUT_DRAFT=""
  INPUT_LAST_SUBMITTED=""
}

input_insert_char() {
  local ch="$1"
  [[ -z "$ch" ]] && return

  if (( INPUT_POS == 0 )); then
    INPUT_BUF="${ch}${INPUT_BUF}"
  elif (( INPUT_POS >= ${#INPUT_BUF} )); then
    INPUT_BUF="${INPUT_BUF}${ch}"
  else
    INPUT_BUF="${INPUT_BUF[1,INPUT_POS]}${ch}${INPUT_BUF[INPUT_POS+1,-1]}"
  fi
  (( INPUT_POS += ${#ch} ))
}

input_backspace() {
  if (( INPUT_POS > 0 )); then
    if (( INPUT_POS == 1 )); then
      INPUT_BUF="${INPUT_BUF[2,-1]}"
    elif (( INPUT_POS >= ${#INPUT_BUF} )); then
      INPUT_BUF="${INPUT_BUF[1,-2]}"
    else
      INPUT_BUF="${INPUT_BUF[1,INPUT_POS-1]}${INPUT_BUF[INPUT_POS+1,-1]}"
    fi
    (( INPUT_POS-- ))
  fi
}

input_delete() {
  local len=${#INPUT_BUF}
  if (( INPUT_POS < len )); then
    if (( INPUT_POS == 0 )); then
      INPUT_BUF="${INPUT_BUF[2,-1]}"
    else
      INPUT_BUF="${INPUT_BUF[1,INPUT_POS]}${INPUT_BUF[INPUT_POS+2,-1]}"
    fi
  fi
}

input_left() {
  (( INPUT_POS > 0 )) && (( INPUT_POS-- ))
}

input_right() {
  (( INPUT_POS < ${#INPUT_BUF} )) && (( INPUT_POS++ ))
}

input_home() {
  INPUT_POS=0
}

input_end() {
  INPUT_POS=${#INPUT_BUF}
}

input_clear() {
  INPUT_BUF=""
  INPUT_POS=0
}

input_kill_word() {
  if (( INPUT_POS > 0 )); then
    local left_part="${INPUT_BUF[1,INPUT_POS]}"
    local right_part="${INPUT_BUF[INPUT_POS+1,-1]}"
    left_part="${left_part%# }"
    left_part="${left_part%#* }"
    INPUT_BUF="${left_part}${right_part}"
    INPUT_POS=${#left_part}
  fi
}

input_hist_prev() {
  local total=${#INPUT_HIST}
  (( total == 0 )) && return

  if (( INPUT_HIST_IDX == 0 )); then
    INPUT_DRAFT="$INPUT_BUF"
    INPUT_HIST_IDX=$total
  elif (( INPUT_HIST_IDX > 1 )); then
    (( INPUT_HIST_IDX-- ))
  fi

  INPUT_BUF="${INPUT_HIST[INPUT_HIST_IDX]}"
  INPUT_POS=${#INPUT_BUF}
}

input_hist_next() {
  local total=${#INPUT_HIST}
  (( total == 0 || INPUT_HIST_IDX == 0 )) && return

  if (( INPUT_HIST_IDX < total )); then
    (( INPUT_HIST_IDX++ ))
    INPUT_BUF="${INPUT_HIST[INPUT_HIST_IDX]}"
  else
    INPUT_HIST_IDX=0
    INPUT_BUF="$INPUT_DRAFT"
  fi
  INPUT_POS=${#INPUT_BUF}
}

input_submit() {
  INPUT_LAST_SUBMITTED="$INPUT_BUF"
  if [[ -n "$INPUT_LAST_SUBMITTED" ]]; then
    INPUT_HIST+=("$INPUT_LAST_SUBMITTED")
  fi
  INPUT_BUF=""
  INPUT_POS=0
  INPUT_HIST_IDX=0
  INPUT_DRAFT=""
}
