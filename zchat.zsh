#!/usr/bin/env zsh
# ==============================================================================
# zchat.zsh - Interactive AI Terminal Chat Interface in Pure ZSH & Curses
# ==============================================================================

# This is a standalone native-Zsh program. Reset options inherited through
# .zshenv before enabling the small set of non-default semantics we rely on.
emulate -R zsh
setopt EXTENDED_GLOB NO_NOMATCH NO_MONITOR NO_NOTIFY NO_CHECK_JOBS NO_HUP 2>/dev/null

typeset -gr ZCHAT_NAME="zchat.zsh"
typeset -gr ZCHAT_VERSION="1.0.12"
typeset -gr ZCHAT_DEFAULT_OLLAMA_HOST="localhost:11434"
typeset -g ZCHAT_HOST_OVERRIDE=0
typeset -g ZCHAT_MODEL_OVERRIDE=0
typeset -g ZCHAT_REQUESTED_MODEL=""
[[ -n "${OLLAMA_HOST:-}" ]] && ZCHAT_HOST_OVERRIDE=1

# Locate script directory
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
ZCHAT_DIR="${0:A:h}"

# Load each library once, on demand. The modal library stays unloaded until an
# overlay is opened, while fast CLI exits avoid loading the full TUI runtime.
# `source` automatically uses a current sibling .zwc created by `make compile`.
typeset -gA ZCHAT_LOADED_LIBS=()
zchat_require() {
  local lib=""
  for lib in "$@"; do
    (( ${+ZCHAT_LOADED_LIBS[$lib]} )) && continue
    ZCHAT_LOADED_LIBS[$lib]=1
    source "${ZCHAT_DIR}/lib/${lib}.zsh" || {
      unset "ZCHAT_LOADED_LIBS[$lib]"
      return 1
    }
  done
}

zchat_select_model() {
  zchat_require modal || return 1
  modal_select_model
}

zchat_select_system_prompt() {
  zchat_require modal || return 1
  modal_system_prompt
}

zchat_show_help() {
  zchat_require modal || return 1
  modal_show_help
}

# CLI Argument parsing
while (( $# > 0 )); do
  case "$1" in
    --host|-h)
      (( $# >= 2 )) || {
        print -u2 -r -- "Error: $1 requires a value"
        exit 2
      }
      shift
      zchat_require api || exit 1
      if ! api_normalize_host "$1"; then
        print -u2 -r -- "Error: $API_HOST_ERROR"
        exit 2
      fi
      OLLAMA_HOST="$REPLY"
      ZCHAT_HOST_OVERRIDE=1
      ;;
    --model|-m)
      (( $# >= 2 )) || {
        print -u2 -r -- "Error: $1 requires a value"
        exit 2
      }
      shift
      [[ -n "$1" && "$1" != -* ]] || {
        print -u2 -r -- "Error: --model requires a non-empty model name"
        exit 2
      }
      SESSION_MODEL="$1"
      ZCHAT_REQUESTED_MODEL="$1"
      ZCHAT_MODEL_OVERRIDE=1
      ;;
    --context-window)
      (( $# >= 2 )) || {
        print -u2 -r -- "Error: $1 requires a value"
        exit 2
      }
      shift
      if [[ "$1" != auto ]] && { [[ "$1" != <4096-> ]] || (( ${#1} > 7 )) || (( 10#$1 > 1048576 )); }; then
        print -u2 -r -- "Error: --context-window expects auto or an integer from 4096 through 1048576"
        exit 2
      fi
      ZCHAT_CONTEXT_WINDOW="$1"
      ;;
    --compact-at)
      (( $# >= 2 )) || {
        print -u2 -r -- "Error: $1 requires a value"
        exit 2
      }
      shift
      if [[ "$1" != <25-90> ]]; then
        print -u2 -r -- "Error: --compact-at expects an integer from 25 through 90"
        exit 2
      fi
      ZCHAT_COMPACT_PERCENT="$1"
      ;;
    --help)
      print -r -- "Usage: ${ZCHAT_NAME} [options]"
      print -r -- "Options:"
      print -r -- "  --host, -h <URL>         Ollama server (default: ${ZCHAT_DEFAULT_OLLAMA_HOST})"
      print -r -- "  --model, -m <model>      Default model name"
      print -r -- "  --context-window <N>     Context tokens to request, or auto"
      print -r -- "  --compact-at <percent>   Compact at 25-90% (default: 85)"
      print -r -- "  --version, -V            Show version"
      print -r -- "  --help                   Show this help"
      exit 0
      ;;
    --version|-V)
      print -r -- "${ZCHAT_NAME} v${ZCHAT_VERSION}"
      exit 0
      ;;
    --)
      shift
      (( $# == 0 )) || {
        print -u2 -r -- "Error: unexpected argument: $1"
        exit 2
      }
      break
      ;;
    *)
      print -u2 -r -- "Error: unknown option or argument: $1"
      exit 2
      ;;
  esac
  shift
done

zchat_require draw || exit 1
zchat_draw_load && zmodload zsh/datetime zsh/files zsh/net/tcp \
  zsh/system zsh/terminfo zsh/zselect || {
  print -u2 -r -- "Error: required Zsh loadable modules are unavailable."
  exit 1
}

# Compaction owns state persisted by state.zsh, so it is part of the core load
# rather than a late feature module. Modals are the only mode-gated library.
zchat_require util json api compact state remote render input ui || exit 1

# Environment-provided OLLAMA_HOST must cross the same validation boundary as
# CLI and persisted values before it can become an HTTP Host header.
if (( ZCHAT_HOST_OVERRIDE )); then
  if ! api_normalize_host "$OLLAMA_HOST"; then
    print -u2 -r -- "Error: $API_HOST_ERROR"
    exit 2
  fi
  OLLAMA_HOST="$REPLY"
fi

# Runtime state
typeset -g RUNNING=1
typeset -g STREAM_PID=""
typeset -g STREAM_BASE_FILE=""
typeset -g STREAM_LAST_CONTENT=""
typeset -g STREAM_LAST_THINKING=""
typeset -g STREAM_PAYLOAD=""
typeset -g STREAM_SESSION_ID=""
typeset -gi STREAM_MESSAGE_INDEX=0
typeset -gi STREAM_DIRTY=0
typeset -gF STREAM_NEXT_RENDER=0.0
typeset -grF STREAM_RENDER_INTERVAL=0.08
typeset -ga SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
typeset -g SPINNER_IDX=1
typeset -gi CLEANUP_DONE=0

# Clean exit handler
cleanup() {
  (( CLEANUP_DONE )) && return 0
  CLEANUP_DONE=1
  RUNNING=0
  api_stop_stream "$STREAM_PID"
  [[ -n "$API_ASYNC_PID" ]] && api_async_cancel
  api_runtime_cleanup
  ui_end
}

zchat_signal_exit() {
  local -i signal_status="$1"
  cleanup
  trap - EXIT
  exit "$signal_status"
}

trap cleanup EXIT
trap 'zchat_signal_exit 130' INT
trap 'zchat_signal_exit 143' TERM
trap 'zchat_signal_exit 129' HUP

# Main Application Initialization
main() {
  if ! api_runtime_init; then
    print -r -- "Error: ${API_HTTP_ERROR:-could not initialize private runtime storage}" >&2
    return 1
  fi
  STREAM_BASE_FILE="${API_RUNTIME_DIR}/stream"
  if ! state_init; then
    print -u2 -r -- "Error: ${STATE_ERROR:-could not initialize ${ZCHAT_CONFIG_DIR}}"
    return 1
  fi
  if ! remote_load_config; then
    print -u2 -r -- "Error: $REMOTE_ERROR"
    return 1
  fi
  input_init

  ui_init 0 || {
    print -r -- "Error: could not initialize curses UI" >&2
    return 1
  }

  # Pre-declare all function-scoped variables
  local ch="" key="" mouse=""
  local cur_ch="" cur_key=""
  local stream_error=""
  local done_file="${STREAM_BASE_FILE}.done"
  local usage_file="${STREAM_BASE_FILE}.usage"
  local usage_line="" prompt_tokens="0" output_tokens="0"
  local -i stream_status=0
  local -F stream_now=0.0
  local prompt_text="" payload=""
  local curr_idx=1 i=1

  while (( RUNNING )); do
    ui_poll_resize

    # --------------------------------------------------------------------------
    # 1. Handle Active Background Streaming (Reasoning + Content)
    # --------------------------------------------------------------------------
    if [[ -n "$STREAM_PID" ]]; then
      SPINNER_IDX=$(( (SPINNER_IDX % ${#SPINNER_CHARS}) + 1 ))
      stream_now=$EPOCHREALTIME

      if [[ -f "$done_file" ]] || ! kill -0 "$STREAM_PID" 2>/dev/null; then
        # Generation completed
        api_stream_read_updates || true
        STREAM_LAST_THINKING+="$API_STREAM_THINKING_DELTA"
        STREAM_LAST_CONTENT+="$API_STREAM_CONTENT_DELTA"
        state_update_streaming_message "$STREAM_LAST_CONTENT" "$STREAM_LAST_THINKING"
        api_stream_collect "$STREAM_PID" "$STREAM_BASE_FILE"
        stream_status=$?
        stream_error="$API_STREAM_ERROR"
        api_stream_close_readers

        if (( stream_status == 0 && ${#MSG_ROLES} == STREAM_MESSAGE_INDEX )) \
          && [[ "$CURRENT_SESSION_ID" == "$STREAM_SESSION_ID" ]]; then
          zchat_read_file "$usage_file"
          usage_line="$REPLY"
          if [[ "$usage_line" == <0->' '*<0->* ]]; then
            prompt_tokens="${usage_line%% *}"
            output_tokens="${${usage_line#* }%%$'\n'*}"
          else
            prompt_tokens=0
            output_tokens=0
          fi
          backend_record_response_usage "$STREAM_PAYLOAD" "$prompt_tokens" "$output_tokens"
          if state_set_last_assistant_message "$STREAM_LAST_CONTENT" "$STREAM_LAST_THINKING"; then
            UI_STATUS_TEXT="Ready"
          else
            UI_STATUS_TEXT="Save error"
          fi
        else
          if [[ "$CURRENT_SESSION_ID" == "$STREAM_SESSION_ID" ]]; then
            state_discard_streaming_message "$STREAM_MESSAGE_INDEX" || true
            state_append_message "system" "Response failed: ${stream_error:-request ownership changed before completion}"
          fi
          UI_STATUS_TEXT="Error"
        fi

        STREAM_PID=""
        STREAM_PAYLOAD=""
        STREAM_SESSION_ID=""
        STREAM_MESSAGE_INDEX=0
        STREAM_LAST_THINKING=""
        STREAM_LAST_CONTENT=""
        STREAM_DIRTY=0
        zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
        ui_refresh_all 0

      else
        if api_stream_read_updates; then
          STREAM_LAST_THINKING+="$API_STREAM_THINKING_DELTA"
          STREAM_LAST_CONTENT+="$API_STREAM_CONTENT_DELTA"
          state_update_streaming_message "$STREAM_LAST_CONTENT" "$STREAM_LAST_THINKING"
          STREAM_DIRTY=1
        fi
        if [[ -z "$STREAM_LAST_CONTENT" ]]; then
          UI_STATUS_TEXT="Thinking ${SPINNER_CHARS[SPINNER_IDX]}"
        else
          UI_STATUS_TEXT="Streaming ${SPINNER_CHARS[SPINNER_IDX]}"
        fi
        if (( stream_now >= STREAM_NEXT_RENDER )); then
          STREAM_NEXT_RENDER=$(( stream_now + STREAM_RENDER_INTERVAL ))
          if (( STREAM_DIRTY )); then
            ui_refresh_stream
            STREAM_DIRTY=0
          else
            ui_draw_header
          fi
        fi
      fi
    fi

    # --------------------------------------------------------------------------
    # 2. Non-blocking Input Poll (50ms timeout)
    # --------------------------------------------------------------------------
    ch=""
    key=""
    mouse=""
    zchat_draw timeout "$UI_INPUT_WINDOW" 50
    TERMINAL_DISCARD_PASTE=0
    [[ $FOCUS_PANE != input ]] && TERMINAL_DISCARD_PASTE=1
    terminal_read_event "$UI_INPUT_WINDOW" ch key mouse

    ui_slash_input "$ch" "$key" && continue

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
    if input_decode_terminal_event "$cur_ch" "$cur_key"; then
      if [[ "$INPUT_EVENT_ACTION" == focus_sessions ]]; then
        (( SIDE_W > 0 )) && FOCUS_PANE=sidebar
        ui_refresh_all
      elif [[ "$INPUT_EVENT_ACTION" == focus_prompt ]]; then
        FOCUS_PANE=input
        ui_refresh_all
      elif [[ "$INPUT_EVENT_ACTION" == paste_rejected ]]; then
        UI_STATUS_TEXT=$INPUT_EVENT_TEXT
        ui_draw_header
      elif [[ "$FOCUS_PANE" != input ]]; then
        continue
      elif [[ "$INPUT_EVENT_ACTION" == "newline" ]]; then
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
        if [[ "$CURRENT_SESSION_ID" == "$STREAM_SESSION_ID" ]]; then
          state_discard_streaming_message "$STREAM_MESSAGE_INDEX" || true
        fi
        STREAM_PID=""
        STREAM_PAYLOAD=""
        STREAM_SESSION_ID=""
        STREAM_MESSAGE_INDEX=0
        STREAM_LAST_THINKING=""
        STREAM_LAST_CONTENT=""
        STREAM_DIRTY=0
        zf_rm -f "${STREAM_BASE_FILE}"* 2>/dev/null
        UI_STATUS_TEXT="Stopped"
        state_append_message "system" "⏹ Response generation cancelled."
        ui_refresh_all 0
      else
        input_clear
        ui_input_changed
      fi

    # Ctrl+B: persistently show/hide the sessions sidebar.
    elif [[ "$cur_ch" == $'\x02' ]]; then
      ui_toggle_sidebar

    # Ctrl+R (^R = \x12): Toggle Reasoning block expansion
    elif [[ "$cur_ch" == $'\x12' ]]; then
      if [[ -n "$STREAM_PID" ]]; then
        state_toggle_last_reasoning 1
        ui_draw_chat 1
      else
        state_toggle_last_reasoning
        ui_draw_chat 0
      fi

    # Ctrl+N (^N = \x0e): New chat session
    elif [[ "$cur_ch" == $'\x0e' ]]; then
      if [[ -n "$STREAM_PID" ]]; then
        UI_STATUS_TEXT="Wait for response"
        ui_draw_header
      else
        if ! state_new_session "$SESSION_MODEL" "$SESSION_SYSTEM_PROMPT"; then
          UI_STATUS_TEXT="Save error"
          ui_draw_header
          continue
        fi
        CHAT_SCROLL_OFFSET=0
        CHAT_AUTO_SCROLL=1
        input_reset
        ui_setup_windows
        ui_refresh_all 0
      fi

    # Ctrl+O (^O = \x0f): Switch model dialog
    elif [[ "$cur_ch" == $'\x0f' ]]; then
      if [[ -n "$STREAM_PID" ]]; then
        UI_STATUS_TEXT="Wait for response"
        ui_draw_header
      else
        zchat_select_model
        ui_setup_windows
        ui_refresh_all 0
      fi

    # Ctrl+S (^S = \x13): System prompt presets dialog
    elif [[ "$cur_ch" == $'\x13' ]]; then
      if [[ -n "$STREAM_PID" ]]; then
        UI_STATUS_TEXT="Wait for response"
        ui_draw_header
      else
        zchat_select_system_prompt
        ui_setup_windows
        ui_refresh_all 0
      fi

    # Ctrl+Y (^Y = \x19): Stable plain-text transcript copy view
    elif [[ "$cur_ch" == $'\x19' ]]; then
      if [[ -n "$STREAM_PID" ]]; then
        ui_copy_view 1 || break
      else
        ui_copy_view 0 || break
      fi

    # Ctrl+H (^H = \x08 / \x7f with mod) or F1: Help modal
    elif [[ "$cur_ch" == $'\x08' || "$cur_key" == "F1" ]]; then
      zchat_show_help
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
      if [[ -n "$STREAM_PID" ]]; then
        UI_STATUS_TEXT="Wait for response"
        ui_draw_header
      elif [[ "$cur_key" == "UP" || "$cur_ch" == "k" ]]; then
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
        if [[ -n "$STREAM_PID" ]]; then
          UI_STATUS_TEXT="Wait for response"
          ui_draw_header
          continue
        fi
        input_submit
        prompt_text="$INPUT_SUBMITTED"
        ui_input_changed

        if [[ -n "$prompt_text" ]]; then
          # Check for slash commands
          case "$prompt_text" in
            /model)
              zchat_select_model
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /model\ *)
              local requested_model="${prompt_text#/model }"
              requested_model="${requested_model##[[:space:]]#}"
              if [[ -n "$requested_model" ]]; then
                SESSION_MODEL="$requested_model"
                if state_save_session; then
                  state_append_message "system" "Model changed to ${SESSION_MODEL}." || true
                else
                  UI_STATUS_TEXT="Save error"
                fi
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
                if _state_write_config; then
                  state_append_message "system" "Ollama URL changed to ${OLLAMA_HOST}." || true
                  UI_STATUS_TEXT="Ready"
                else
                  UI_STATUS_TEXT="Save error"
                fi
              else
                state_append_message "system" "Could not change Ollama URL: ${API_HOST_ERROR}"
                UI_STATUS_TEXT="Error"
              fi
              ui_refresh_all 0
              ;;
            /reason|/think)
              state_toggle_last_reasoning
              ui_draw_chat 0
              ;;
            /sidebar)
              ui_toggle_sidebar
              ;;
            /copy)
              ui_copy_view 0 || break
              ;;
            /sys|/system)
              zchat_select_system_prompt
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /new|/clear)
              if ! state_new_session "$SESSION_MODEL" "$SESSION_SYSTEM_PROMPT"; then
                UI_STATUS_TEXT="Save error"
                ui_refresh_all 0
                continue
              fi
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
                if backend_compact_history manual; then
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
              backend_context_summary
              state_append_message "system" "$REPLY"
              ui_refresh_all 0
              ;;
            /help|/\?)
              zchat_show_help
              ui_setup_windows
              ui_refresh_all 0
              ;;
            /quit|/exit|/q)
              break
              ;;
            *)
              # 1. Append user prompt
              if ! state_append_message "user" "$prompt_text"; then
                UI_STATUS_TEXT="Save error"
                ui_refresh_all 0
                ui_draw_input
                continue
              fi

              # 2. Compact when needed and build the bounded model payload.
              UI_STATUS_TEXT="Preparing"
              ui_refresh_all 0
              if ! backend_prepare_payload; then
                state_append_message "system" "Could not prepare the conversation: ${CHAT_COMPACTION_ERROR:-unknown compaction error}"
                UI_STATUS_TEXT="Error"
                ui_refresh_all 0
                ui_draw_input
                continue
              fi
              payload="$REPLY"

              # 3. Create initial assistant message for UI (expanded thinking mode)
              state_begin_streaming_message

              CHAT_AUTO_SCROLL=1
              UI_STATUS_TEXT="Thinking ⠋"
              ui_refresh_all 1

              # 4. Start background streaming
              if backend_start_stream "$OLLAMA_HOST" "$payload" "$STREAM_BASE_FILE" \
                && api_stream_open_readers "$STREAM_BASE_FILE"; then
                STREAM_PID="$API_STREAM_PID"
                STREAM_PAYLOAD="$payload"
                STREAM_SESSION_ID="$CURRENT_SESSION_ID"
                STREAM_MESSAGE_INDEX=${#MSG_ROLES}
                STREAM_LAST_THINKING=""
                STREAM_LAST_CONTENT=""
                STREAM_DIRTY=0
                STREAM_NEXT_RENDER=$(( EPOCHREALTIME + STREAM_RENDER_INTERVAL ))
              else
                api_stop_stream "$API_STREAM_PID"
                state_discard_streaming_message "${#MSG_ROLES}" || true
                state_append_message "system" "Could not start the response: ${API_STREAM_ERROR:-could not open stream handoff files}"
                UI_STATUS_TEXT="Error"
                ui_refresh_all 0
              fi
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
