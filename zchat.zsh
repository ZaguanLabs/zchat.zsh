#!/usr/bin/env zsh
# ==============================================================================
# zchat.zsh - Interactive AI Terminal Chat Interface in Pure ZSH & Curses
# ==============================================================================

setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP 2>/dev/null
zmodload zsh/curses zsh/datetime zsh/files zsh/mapfile zsh/net/tcp \
  zsh/system zsh/terminfo zsh/zselect || {
  echo "Error: required Zsh loadable modules are unavailable." >&2
  exit 1
}

typeset -gr ZCHAT_NAME="zchat.zsh"
typeset -gr ZCHAT_VERSION="1.0.0"
typeset -gr ZCHAT_DEFAULT_OLLAMA_HOST="localhost:11434"
typeset -g ZCHAT_HOST_OVERRIDE=0
[[ -n "${OLLAMA_HOST:-}" ]] && ZCHAT_HOST_OVERRIDE=1

# Locate script directory
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
ZCHAT_DIR="${0:A:h}"

# Source internal modules
source "${ZCHAT_DIR}/lib/util.zsh"
source "${ZCHAT_DIR}/lib/json.zsh"
source "${ZCHAT_DIR}/lib/api.zsh"
source "${ZCHAT_DIR}/lib/state.zsh"
source "${ZCHAT_DIR}/lib/render.zsh"
source "${ZCHAT_DIR}/lib/input.zsh"
source "${ZCHAT_DIR}/lib/modal.zsh"
source "${ZCHAT_DIR}/lib/ui.zsh"

# CLI Argument parsing
while (( $# > 0 )); do
  case "$1" in
    --host|-h)
      shift
      if ! api_normalize_host "$1"; then
        echo "Error: $API_HOST_ERROR" >&2
        exit 2
      fi
      OLLAMA_HOST="$REPLY"
      ZCHAT_HOST_OVERRIDE=1
      ;;
    --model|-m)
      shift
      SESSION_MODEL="$1"
      ;;
    --help)
      echo "Usage: ${ZCHAT_NAME} [options]"
      echo "Options:"
      echo "  --host, -h <URL>         Ollama server (default: ${ZCHAT_DEFAULT_OLLAMA_HOST})"
      echo "  --model, -m <model>      Default model name"
      echo "  --version, -V            Show version"
      echo "  --help                   Show this help"
      exit 0
      ;;
    --version|-V)
      echo "${ZCHAT_NAME} v${ZCHAT_VERSION}"
      exit 0
      ;;
    *)
      ;;
  esac
  shift
done

# Runtime state
typeset -g RUNNING=1
typeset -g STREAM_PID=""
typeset -g STREAM_BASE_FILE="/tmp/zchat_stream_$$"
typeset -g STREAM_LAST_CONTENT=""
typeset -g STREAM_LAST_THINKING=""
typeset -ga SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
typeset -g SPINNER_IDX=1

# Clean exit handler
cleanup() {
  RUNNING=0
  api_stop_stream "$STREAM_PID"
  zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
  ui_destroy_windows
  zcurses end 2>/dev/null
  print -rn -- "${terminfo[cnorm]}" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

# Resize signal handler
TRAPWINCH() {
  ui_setup_windows
  ui_refresh_all 0
}

# Main Application Initialization
main() {
  state_init
  input_init

  zcurses init
  ui_setup_windows
  ui_refresh_all 0

  # Pre-declare all function-scoped variables
  local ch="" key="" mouse=""
  local cur_ch="" cur_key=""
  local raw_stream="" final_content=""
  local raw_thinking="" raw_content=""
  local t_file="${STREAM_BASE_FILE}.thinking"
  local c_file="${STREAM_BASE_FILE}.content"
  local done_file="${STREAM_BASE_FILE}.done"
  local prompt_text="" payload=""
  local curr_idx=1 i=1

  while (( RUNNING )); do
    # --------------------------------------------------------------------------
    # 1. Handle Active Background Streaming (Reasoning + Content)
    # --------------------------------------------------------------------------
    if [[ -n "$STREAM_PID" ]]; then
      SPINNER_IDX=$(( (SPINNER_IDX % ${#SPINNER_CHARS}) + 1 ))

      if [[ -f "$done_file" ]] || ! kill -0 "$STREAM_PID" 2>/dev/null; then
        # Generation completed
        zchat_read_file "$t_file"
        raw_thinking="$REPLY"
        zchat_read_file "$c_file"
        raw_content="$REPLY"
        state_set_last_assistant_message "$raw_content" "$raw_thinking"

        STREAM_PID=""
        STREAM_LAST_THINKING=""
        STREAM_LAST_CONTENT=""
        zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
        UI_STATUS_TEXT="Ready"
        ui_refresh_all 0

      elif [[ -f "$t_file" || -f "$c_file" ]]; then
        zchat_read_file "$t_file"
        raw_thinking="$REPLY"
        zchat_read_file "$c_file"
        raw_content="$REPLY"

        if [[ "$raw_thinking" != "$STREAM_LAST_THINKING" || "$raw_content" != "$STREAM_LAST_CONTENT" ]]; then
          STREAM_LAST_THINKING="$raw_thinking"
          STREAM_LAST_CONTENT="$raw_content"
          state_update_streaming_message "$raw_content" "$raw_thinking"

          if [[ -z "$raw_content" ]]; then
            UI_STATUS_TEXT="Thinking ${SPINNER_CHARS[SPINNER_IDX]}"
          else
            UI_STATUS_TEXT="Streaming ${SPINNER_CHARS[SPINNER_IDX]}"
          fi
          ui_refresh_all 1
        else
          # Keep spinner animating in header
          if [[ -z "$raw_content" ]]; then
            UI_STATUS_TEXT="Thinking ${SPINNER_CHARS[SPINNER_IDX]}"
          else
            UI_STATUS_TEXT="Streaming ${SPINNER_CHARS[SPINNER_IDX]}"
          fi
          ui_draw_header
        fi
      fi
    fi

    # --------------------------------------------------------------------------
    # 2. Non-blocking Input Poll (50ms timeout)
    # --------------------------------------------------------------------------
    ch=""
    key=""
    mouse=""
    zcurses timeout input_win 50
    zcurses input input_win ch key mouse

    # If timeout (no key pressed), continue loop
    if [[ -z "$ch" && -z "$key" ]]; then
      continue
    fi

    # Capture pressed key and clear poll buffers
    cur_ch="$ch"
    cur_key="$key"
    ch=""
    key=""
    mouse=""

    # --------------------------------------------------------------------------
    # 3. Global Keybindings
    # --------------------------------------------------------------------------
    # Ctrl+Q (^Q = \x11) or Ctrl+D (^D = \x04): Exit
    if [[ "$cur_ch" == $'\x11' || "$cur_ch" == $'\x04' ]]; then
      break

    # Ctrl+C (^C = \x03): Cancel streaming or clear input
    elif [[ "$cur_ch" == $'\x03' ]]; then
      if [[ -n "$STREAM_PID" ]]; then
        api_stop_stream "$STREAM_PID"
        STREAM_PID=""
        zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
        UI_STATUS_TEXT="Stopped"
        state_append_message "system" "⏹ Response generation cancelled."
        ui_refresh_all 0
      else
        input_clear
        ui_draw_input
      fi

    # Ctrl+R (^R = \x12): Toggle Reasoning block expansion
    elif [[ "$cur_ch" == $'\x12' ]]; then
      state_toggle_last_reasoning
      ui_draw_chat 0

    # Ctrl+N (^N = \x0e): New chat session
    elif [[ "$cur_ch" == $'\x0e' ]]; then
      state_new_session "$SESSION_MODEL" "$SESSION_SYSTEM_PROMPT"
      CHAT_SCROLL_OFFSET=0
      CHAT_AUTO_SCROLL=1
      input_init
      ui_refresh_all 0

    # Ctrl+O (^O = \x0f): Switch model dialog
    elif [[ "$cur_ch" == $'\x0f' ]]; then
      modal_select_model
      ui_setup_windows
      ui_refresh_all 0

    # Ctrl+S (^S = \x13): System prompt presets dialog
    elif [[ "$cur_ch" == $'\x13' ]]; then
      modal_system_prompt
      ui_setup_windows
      ui_refresh_all 0

    # Ctrl+H (^H = \x08 / \x7f with mod) or F1: Help modal
    elif [[ "$cur_ch" == $'\x08' || "$cur_key" == "F1" ]]; then
      modal_show_help
      ui_setup_windows
      ui_refresh_all 0

    # Tab: Toggle pane focus (input -> sidebar -> chat -> input)
    elif [[ "$cur_ch" == $'\t' || "$cur_key" == "TAB" ]]; then
      case "$FOCUS_PANE" in
        input)
          if (( SIDE_W > 0 )); then
            FOCUS_PANE="sidebar"
          else
            FOCUS_PANE="chat"
          fi
          ;;
        sidebar) FOCUS_PANE="chat" ;;
        chat) FOCUS_PANE="input" ;;
      esac
      ui_refresh_all 0

    # PageUp / PageDown: Scroll chat transcript
    elif [[ "$cur_key" == "PPAGE" ]]; then
      CHAT_AUTO_SCROLL=0
      (( CHAT_SCROLL_OFFSET -= 6 ))
      (( CHAT_SCROLL_OFFSET < 0 )) && CHAT_SCROLL_OFFSET=0
      ui_draw_chat 0

    elif [[ "$cur_key" == "NPAGE" ]]; then
      (( CHAT_SCROLL_OFFSET += 6 ))
      ui_draw_chat 0

    # Home / End: Top / bottom of chat
    elif [[ "$cur_key" == "HOME" && "$FOCUS_PANE" == "chat" ]]; then
      CHAT_AUTO_SCROLL=0
      CHAT_SCROLL_OFFSET=0
      ui_draw_chat 0

    elif [[ "$cur_key" == "END" && "$FOCUS_PANE" == "chat" ]]; then
      CHAT_AUTO_SCROLL=1
      ui_draw_chat 0

    # --------------------------------------------------------------------------
    # 4. Sidebar Focus Navigation
    # --------------------------------------------------------------------------
    elif [[ "$FOCUS_PANE" == "sidebar" ]]; then
      if [[ "$cur_key" == "UP" || "$cur_ch" == "k" ]]; then
        curr_idx=1
        for (( i=1; i<=${#SESSION_IDS}; i++ )); do
          [[ "${SESSION_IDS[i]}" == "$CURRENT_SESSION_ID" ]] && { curr_idx=$i; break }
        done
        if (( curr_idx > 1 )); then
          state_load_session "${SESSION_IDS[curr_idx-1]}"
          ui_refresh_all 0
        fi
      elif [[ "$cur_key" == "DOWN" || "$cur_ch" == "j" ]]; then
        curr_idx=1
        for (( i=1; i<=${#SESSION_IDS}; i++ )); do
          [[ "${SESSION_IDS[i]}" == "$CURRENT_SESSION_ID" ]] && { curr_idx=$i; break }
        done
        if (( curr_idx < ${#SESSION_IDS} )); then
          state_load_session "${SESSION_IDS[curr_idx+1]}"
          ui_refresh_all 0
        fi
      elif [[ "$cur_ch" == "d" || "$cur_ch" == "x" ]]; then
        # Delete active session
        state_delete_session "$CURRENT_SESSION_ID"
        ui_refresh_all 0
      elif [[ "$cur_ch" == $'\n' || "$cur_ch" == $'\r' || "$cur_key" == "ENTER" ]]; then
        FOCUS_PANE="input"
        ui_refresh_all 0
      fi

    # --------------------------------------------------------------------------
    # 5. Input Box Editing & Message Dispatch
    # --------------------------------------------------------------------------
    elif [[ "$FOCUS_PANE" == "input" ]]; then
      # Enter: Dispatch prompt
      if [[ "$cur_ch" == $'\n' || "$cur_ch" == $'\r' || "$cur_key" == "ENTER" || "$cur_key" == "PADENTER" ]]; then
        input_submit
        prompt_text="$INPUT_LAST_SUBMITTED"

        if [[ -n "$prompt_text" ]]; then
          # Check for slash commands
          case "$prompt_text" in
            /model*)
              modal_select_model
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /host|/host\ *)
              local requested_host="${prompt_text#/host}"
              requested_host="${requested_host##[[:space:]]#}"
              if [[ -z "$requested_host" ]]; then
                state_append_message "system" "Current Ollama URL: ${OLLAMA_HOST}"$'\n'"Change it with: /host http://hostname:11434"
              elif api_normalize_host "$requested_host"; then
                OLLAMA_HOST="$REPLY"
                _state_write_config
                state_append_message "system" "Ollama URL changed to ${OLLAMA_HOST}."
                UI_STATUS_TEXT="Ready"
              else
                state_append_message "system" "Could not change Ollama URL: ${API_HOST_ERROR}"
                UI_STATUS_TEXT="Error"
              fi
              ui_refresh_all 0
              ;;
            /reason*|/think*)
              state_toggle_last_reasoning
              ui_draw_chat 0
              ;;
            /sys*|/system*)
              modal_system_prompt
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /new|/clear)
              state_new_session "$SESSION_MODEL" "$SESSION_SYSTEM_PROMPT"
              CHAT_SCROLL_OFFSET=0
              CHAT_AUTO_SCROLL=1
              ui_refresh_all 0
              ;;
            /help|/\?)
              modal_show_help
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /quit|/exit|/q)
              break
              ;;
            *)
              # 1. Append user prompt
              state_append_message "user" "$prompt_text"

              # 2. Build payload BEFORE adding placeholder assistant message
              state_build_payload
              payload="$REPLY"

              # 3. Create initial assistant message for UI (expanded thinking mode)
              state_append_message "assistant" "" "" 1

              CHAT_AUTO_SCROLL=1
              UI_STATUS_TEXT="Thinking ⠋"
              ui_refresh_all 1

              # 4. Start background streaming
              api_start_stream "$OLLAMA_HOST" "$payload" "$STREAM_BASE_FILE"
              STREAM_PID="$API_STREAM_PID"
              ;;
          esac
        fi
        ui_draw_input

      # Line editing keys
      elif [[ "$cur_key" == "BACKSPACE" || "$cur_ch" == $'\x7f' || "$cur_ch" == $'\b' ]]; then
        input_backspace
        ui_draw_input
      elif [[ "$cur_key" == "DC" || "$cur_key" == "DELETE" ]]; then
        input_delete
        ui_draw_input
      elif [[ "$cur_key" == "LEFT" ]]; then
        input_left
        ui_draw_input
      elif [[ "$cur_key" == "RIGHT" ]]; then
        input_right
        ui_draw_input
      elif [[ "$cur_key" == "HOME" || "$cur_ch" == $'\x01' ]]; then
        input_home
        ui_draw_input
      elif [[ "$cur_key" == "END" || "$cur_ch" == $'\x05' ]]; then
        input_end
        ui_draw_input
      elif [[ "$cur_ch" == $'\x15' ]]; then
        # Ctrl+U: Clear line
        input_clear
        ui_draw_input
      elif [[ "$cur_ch" == $'\x17' ]]; then
        # Ctrl+W: Kill word
        input_kill_word
        ui_draw_input
      elif [[ "$cur_key" == "UP" ]]; then
        input_hist_prev
        ui_draw_input
      elif [[ "$cur_key" == "DOWN" ]]; then
        input_hist_next
        ui_draw_input
      elif [[ -n "$cur_ch" && "$cur_ch" != $'\x1b' ]]; then
        # Printable character input
        input_insert_char "$cur_ch"
        ui_draw_input
      fi
    fi
  done
}

main "$@"
