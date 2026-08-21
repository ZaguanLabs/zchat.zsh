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
typeset -gr ZCHAT_VERSION="1.0.3"
typeset -gr ZCHAT_DEFAULT_OLLAMA_HOST="localhost:11434"
typeset -g ZCHAT_HOST_OVERRIDE=0
typeset -g ZCHAT_MODEL_OVERRIDE=0
typeset -g ZCHAT_REQUESTED_MODEL=""
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
source "${ZCHAT_DIR}/lib/compact.zsh"
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
      ZCHAT_REQUESTED_MODEL="$1"
      ZCHAT_MODEL_OVERRIDE=1
      ;;
    --context-window)
      shift
      if [[ "$1" != auto && "$1" != <4096-> ]]; then
        echo "Error: --context-window expects auto or an integer of at least 4096" >&2
        exit 2
      fi
      ZCHAT_CONTEXT_WINDOW="$1"
      ;;
    --compact-at)
      shift
      if [[ "$1" != <25-90> ]]; then
        echo "Error: --compact-at expects an integer from 25 through 90" >&2
        exit 2
      fi
      ZCHAT_COMPACT_PERCENT="$1"
      ;;
    --help)
      echo "Usage: ${ZCHAT_NAME} [options]"
      echo "Options:"
      echo "  --host, -h <URL>         Ollama server (default: ${ZCHAT_DEFAULT_OLLAMA_HOST})"
      echo "  --model, -m <model>      Default model name"
      echo "  --context-window <N>     Context tokens to request, or auto"
      echo "  --compact-at <percent>   Compact at 25-90% (default: 85)"
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
typeset -g STREAM_PAYLOAD=""
typeset -ga SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
typeset -g SPINNER_IDX=1

# Clean exit handler
cleanup() {
  RUNNING=0
  api_stop_stream "$STREAM_PID"
  [[ -n "$API_ASYNC_PID" ]] && api_async_cancel
  zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
  ui_destroy_windows
  zcurses end 2>/dev/null
  print -rn -- $'\e[?2004l' > /dev/tty 2>/dev/null
  print -rn -- "${terminfo[cnorm]}" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

# Main Application Initialization
main() {
  state_init
  input_init

  zcurses init
  # Delimit pasted text so embedded newlines remain inside one prompt.
  print -rn -- $'\e[?2004h' > /dev/tty 2>/dev/null
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
  local usage_file="${STREAM_BASE_FILE}.usage"
  local usage_line="" prompt_tokens="0" output_tokens="0"
  local prompt_text="" payload=""
  local curr_idx=1 i=1

  while (( RUNNING )); do
    ui_poll_resize

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

        zchat_read_file "$usage_file"
        usage_line="$REPLY"
        if [[ "$usage_line" == <0->' '*<0->* ]]; then
          prompt_tokens="${usage_line%% *}"
          output_tokens="${${usage_line#* }%%$'\n'*}"
        else
          prompt_tokens=0
          output_tokens=0
        fi
        chat_record_response_usage "$STREAM_PAYLOAD" "$prompt_tokens" "$output_tokens"

        STREAM_PID=""
        STREAM_PAYLOAD=""
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

    if [[ "$cur_key" == "RESIZE" ]]; then
      ui_poll_resize
      continue
    fi

    # Decode multiline input protocols before ordinary key dispatch. A paste
    # is inserted as one editor action and therefore can never submit itself.
    if [[ "$FOCUS_PANE" == "input" ]] && input_decode_terminal_event "$cur_ch" "$cur_key"; then
      if [[ "$INPUT_EVENT_ACTION" == "newline" ]]; then
        input_insert $'\n'
        ui_input_changed
      elif [[ "$INPUT_EVENT_ACTION" == "paste" && -n "$INPUT_EVENT_TEXT" ]]; then
        input_insert "$INPUT_EVENT_TEXT"
        ui_input_changed
      fi
      continue
    fi

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
        STREAM_PAYLOAD=""
        zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
        UI_STATUS_TEXT="Stopped"
        state_append_message "system" "⏹ Response generation cancelled."
        ui_refresh_all 0
      else
        input_clear
        ui_input_changed
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
      input_reset
      ui_setup_windows
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
        prompt_text="$INPUT_SUBMITTED"
        ui_input_changed

        if [[ -n "$prompt_text" ]]; then
          # Check for slash commands
          case "$prompt_text" in
            /model)
              modal_select_model
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /model\ *)
              local requested_model="${prompt_text#/model }"
              requested_model="${requested_model##[[:space:]]#}"
              if [[ -n "$requested_model" ]]; then
                SESSION_MODEL="$requested_model"
                state_save_session
                state_append_message "system" "Model changed to ${SESSION_MODEL}."
              fi
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
            /compact)
              if [[ -n "$STREAM_PID" ]]; then
                state_append_message "system" "Wait for the current response to finish before compacting."
              else
                UI_STATUS_TEXT="Compacting"
                ui_refresh_all 0
                if chat_compact_history manual; then
                  UI_STATUS_TEXT="Ready"
                elif (( CHAT_COMPACTION_CANCELLED )); then
                  state_append_message "system" "⏹ Compaction stopped."
                  UI_STATUS_TEXT="Stopped"
                elif [[ -z "$CHAT_COMPACTION_ERROR" ]]; then
                  state_append_message "system" "Nothing to compact yet."
                  UI_STATUS_TEXT="Ready"
                else
                  state_append_message "system" "Compaction failed: ${CHAT_COMPACTION_ERROR}"
                  UI_STATUS_TEXT="Error"
                fi
              fi
              ui_refresh_all 0
              ;;
            /context)
              chat_context_summary
              state_append_message "system" "$REPLY"
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

              # 2. Compact when needed and build the bounded model payload.
              UI_STATUS_TEXT="Preparing"
              ui_refresh_all 0
              if ! chat_prepare_payload; then
                state_append_message "system" "Could not prepare the conversation: ${CHAT_COMPACTION_ERROR:-unknown compaction error}"
                UI_STATUS_TEXT="Error"
                ui_refresh_all 0
                ui_draw_input
                continue
              fi
              payload="$REPLY"

              # 3. Create initial assistant message for UI (expanded thinking mode)
              state_append_message "assistant" "" "" 1

              CHAT_AUTO_SCROLL=1
              UI_STATUS_TEXT="Thinking ⠋"
              ui_refresh_all 1

              # 4. Start background streaming
              api_start_stream "$OLLAMA_HOST" "$payload" "$STREAM_BASE_FILE"
              STREAM_PID="$API_STREAM_PID"
              STREAM_PAYLOAD="$payload"
              ;;
          esac
        fi
        ui_draw_input

      # Line editing keys
      elif [[ "$cur_key" == "BACKSPACE" || "$cur_ch" == $'\x7f' || "$cur_ch" == $'\b' ]]; then
        input_backspace
        ui_input_changed
      elif [[ "$cur_key" == "DC" || "$cur_key" == "DELETE" ]]; then
        input_delete
        ui_input_changed
      elif [[ "$cur_key" == "LEFT" ]]; then
        input_left
        ui_input_changed
      elif [[ "$cur_key" == "RIGHT" ]]; then
        input_right
        ui_input_changed
      elif [[ "$cur_key" == "HOME" || "$cur_ch" == $'\x01' ]]; then
        input_home
        ui_input_changed
      elif [[ "$cur_key" == "END" || "$cur_ch" == $'\x05' ]]; then
        input_end
        ui_input_changed
      elif [[ "$cur_ch" == $'\x15' ]]; then
        # Ctrl+U: Clear line
        input_clear
        ui_input_changed
      elif [[ "$cur_ch" == $'\x17' ]]; then
        # Ctrl+W: Kill word
        input_kill_word
        ui_input_changed
      elif [[ "$cur_key" == "UP" ]]; then
        ui_input_width
        input_move_vertical -1 "$REPLY" $(( INPUT_H - 2 )) || input_history_previous
        ui_input_changed
      elif [[ "$cur_key" == "DOWN" ]]; then
        ui_input_width
        input_move_vertical 1 "$REPLY" $(( INPUT_H - 2 )) || input_history_next
        ui_input_changed
      elif [[ -n "$cur_ch" && "$cur_ch" != $'\x1b' ]]; then
        # Printable character input
        input_insert "$cur_ch"
        ui_input_changed
      fi
    fi
  done
}

main "$@"
