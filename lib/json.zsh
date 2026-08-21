# lib/json.zsh - Small native JSON codec for Ollama and session migration

typeset -g JSON_SOURCE=""
typeset -gi JSON_POS=1
typeset -gi JSON_LEN=0
typeset -g JSON_TOKEN_TYPE=""
typeset -g JSON_TOKEN_VALUE=""
typeset -g JSON_ERROR=""

typeset -g JSON_MESSAGE_THINKING=""
typeset -g JSON_MESSAGE_CONTENT=""
typeset -g JSON_MESSAGE_ERROR=""
typeset -gi JSON_MESSAGE_DONE=0
typeset -gi JSON_MESSAGE_PROMPT_TOKENS=0
typeset -gi JSON_MESSAGE_OUTPUT_TOKENS=0

typeset -gA JSON_CONFIG=()
typeset -ga JSON_MODEL_NAMES=()
typeset -gi JSON_RUNNING_MODEL_CONTEXT=0

typeset -g JSON_SESSION_ID=""
typeset -g JSON_SESSION_TITLE=""
typeset -g JSON_SESSION_MODEL=""
typeset -g JSON_SESSION_SYSTEM=""
typeset -g JSON_SESSION_TEMPERATURE="0.7"
typeset -ga JSON_SESSION_ROLES=()
typeset -ga JSON_SESSION_CONTENTS=()
typeset -ga JSON_SESSION_THINKINGS=()
typeset -ga JSON_SESSION_EXPANDED=()
typeset -ga JSON_SESSION_TIMES=()

# Encode a string as a JSON string literal. Result is returned in REPLY.
json_quote() {
  local input="$1"
  local output='"'
  local ch="" escaped=""
  local -i i code

  for (( i=1; i<=${#input}; i++ )); do
    ch="${input[i]}"
    case "$ch" in
      '"') output+='\"' ;;
      $'\\') output+='\\' ;;
      $'\b') output+='\b' ;;
      $'\f') output+='\f' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        printf -v code '%d' "'$ch"
        if (( code < 32 )); then
          printf -v escaped '\\u%04x' "$code"
          output+="$escaped"
        else
          output+="$ch"
        fi
        ;;
    esac
  done

  REPLY="${output}\""
}

json_begin() {
  JSON_SOURCE="$1"
  JSON_POS=1
  JSON_LEN=${#JSON_SOURCE}
  JSON_TOKEN_TYPE=""
  JSON_TOKEN_VALUE=""
  JSON_ERROR=""
  json_next
}

# Advance the tokenizer by one JSON token.
json_next() {
  local ch="" esc="" hex="" low_hex="" encoded="" decoded=""
  local value=""
  local -i cp low_cp

  while (( JSON_POS <= JSON_LEN )); do
    ch="${JSON_SOURCE[JSON_POS]}"
    [[ "$ch" == [[:space:]] ]] || break
    (( JSON_POS++ ))
  done

  if (( JSON_POS > JSON_LEN )); then
    JSON_TOKEN_TYPE="eof"
    JSON_TOKEN_VALUE=""
    return 0
  fi

  ch="${JSON_SOURCE[JSON_POS]}"
  case "$ch" in
    '{'|'}'|'['|']'|':'|',')
      JSON_TOKEN_TYPE="$ch"
      JSON_TOKEN_VALUE="$ch"
      (( JSON_POS++ ))
      return 0
      ;;
    '"')
      (( JSON_POS++ ))
      value=""
      while (( JSON_POS <= JSON_LEN )); do
        ch="${JSON_SOURCE[JSON_POS]}"
        (( JSON_POS++ ))
        if [[ "$ch" == '"' ]]; then
          JSON_TOKEN_TYPE="string"
          JSON_TOKEN_VALUE="$value"
          return 0
        fi
        if [[ "$ch" != $'\\' ]]; then
          value+="$ch"
          continue
        fi

        if (( JSON_POS > JSON_LEN )); then
          JSON_ERROR="unterminated JSON escape"
          return 1
        fi
        esc="${JSON_SOURCE[JSON_POS]}"
        (( JSON_POS++ ))
        case "$esc" in
          '"'|$'\\'|'/') value+="$esc" ;;
          b) value+=$'\b' ;;
          f) value+=$'\f' ;;
          n) value+=$'\n' ;;
          r) value+=$'\r' ;;
          t) value+=$'\t' ;;
          u)
            hex="${JSON_SOURCE[JSON_POS,$(( JSON_POS + 3 ))]}"
            if [[ "$hex" != [[:xdigit:]]## ]]; then
              JSON_ERROR="invalid JSON unicode escape"
              return 1
            fi
            (( JSON_POS += 4 ))
            cp=$(( 16#$hex ))

            # Combine UTF-16 surrogate pairs before producing UTF-8.
            if (( cp >= 0xD800 && cp <= 0xDBFF )) && \
               [[ "${JSON_SOURCE[JSON_POS,$(( JSON_POS + 1 ))]}" == $'\\u' ]]; then
              low_hex="${JSON_SOURCE[$(( JSON_POS + 2 )),$(( JSON_POS + 5 ))]}"
              if [[ "$low_hex" == [[:xdigit:]]## ]]; then
                low_cp=$(( 16#$low_hex ))
                if (( low_cp >= 0xDC00 && low_cp <= 0xDFFF )); then
                  cp=$(( 0x10000 + ((cp - 0xD800) << 10) + low_cp - 0xDC00 ))
                  (( JSON_POS += 6 ))
                fi
              fi
            fi

            if (( cp <= 0xFFFF )); then
              printf -v encoded '\\u%04x' "$cp"
            else
              printf -v encoded '\\U%08x' "$cp"
            fi
            printf -v decoded '%b' "$encoded"
            value+="$decoded"
            ;;
          *)
            JSON_ERROR="invalid JSON escape"
            return 1
            ;;
        esac
      done
      JSON_ERROR="unterminated JSON string"
      return 1
      ;;
    -|[0-9])
      value=""
      while (( JSON_POS <= JSON_LEN )); do
        ch="${JSON_SOURCE[JSON_POS]}"
        [[ "$ch" == [0-9eE+.-] ]] || break
        value+="$ch"
        (( JSON_POS++ ))
      done
      JSON_TOKEN_TYPE="number"
      JSON_TOKEN_VALUE="$value"
      return 0
      ;;
    [tfn])
      value=""
      while (( JSON_POS <= JSON_LEN )); do
        ch="${JSON_SOURCE[JSON_POS]}"
        [[ "$ch" == [[:alpha:]] ]] || break
        value+="$ch"
        (( JSON_POS++ ))
      done
      case "$value" in
        true|false|null)
          JSON_TOKEN_TYPE="$value"
          JSON_TOKEN_VALUE="$value"
          return 0
          ;;
      esac
      JSON_ERROR="invalid JSON literal"
      return 1
      ;;
  esac

  JSON_ERROR="unexpected JSON character at $JSON_POS"
  return 1
}

# Skip the value at the current token, leaving the next token current.
json_skip_value() {
  local depth_type="$JSON_TOKEN_TYPE"

  case "$depth_type" in
    string|number|true|false|null)
      json_next
      ;;
    '{')
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
        [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
        json_next || return 1
        [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
        json_next || return 1
        json_skip_value || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
          return 1
        fi
      done
      json_next
      ;;
    '[')
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        json_skip_value || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          return 1
        fi
      done
      json_next
      ;;
    *) return 1 ;;
  esac
}

_json_parse_message_object() {
  local key=""
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1

  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1

    case "$key:$JSON_TOKEN_TYPE" in
      thinking:string) JSON_MESSAGE_THINKING="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      content:string) JSON_MESSAGE_CONTENT="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      *) json_skip_value || return 1 ;;
    esac

    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next
}

# Decode the fields used from one Ollama /api/chat NDJSON object.
json_parse_ollama_event() {
  local key=""
  JSON_MESSAGE_THINKING=""
  JSON_MESSAGE_CONTENT=""
  JSON_MESSAGE_ERROR=""
  JSON_MESSAGE_DONE=0
  JSON_MESSAGE_PROMPT_TOKENS=0
  JSON_MESSAGE_OUTPUT_TOKENS=0

  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1

  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1

    case "$key:$JSON_TOKEN_TYPE" in
      message:'{') _json_parse_message_object || return 1 ;;
      done:true) JSON_MESSAGE_DONE=1; json_next || return 1 ;;
      done:false) JSON_MESSAGE_DONE=0; json_next || return 1 ;;
      error:string) JSON_MESSAGE_ERROR="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      prompt_eval_count:number)
        [[ "$JSON_TOKEN_VALUE" == <0-> ]] && JSON_MESSAGE_PROMPT_TOKENS="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      eval_count:number)
        [[ "$JSON_TOKEN_VALUE" == <0-> ]] && JSON_MESSAGE_OUTPUT_TOKENS="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      *) json_skip_value || return 1 ;;
    esac

    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done

  return 0
}

# Decode the flat zchat configuration object.
json_parse_config() {
  local key=""
  JSON_CONFIG=()
  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1

  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1

    case "$JSON_TOKEN_TYPE" in
      string|number|true|false|null)
        JSON_CONFIG[$key]="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      *) json_skip_value || return 1 ;;
    esac

    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
}

_json_parse_model_object() {
  local key="" model_name=""
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    if [[ "$key" == name && "$JSON_TOKEN_TYPE" == string ]]; then
      model_name="$JSON_TOKEN_VALUE"
      json_next || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1
  [[ -n "$model_name" ]] && JSON_MODEL_NAMES+=("$model_name")
}

# Decode model names from Ollama /api/tags.
json_parse_models() {
  local key=""
  JSON_MODEL_NAMES=()
  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1

    if [[ "$key" == models && "$JSON_TOKEN_TYPE" == '[' ]]; then
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        _json_parse_model_object || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          return 1
        fi
      done
      json_next || return 1
    else
      json_skip_value || return 1
    fi

    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
}

_json_model_names_match() {
  local left="$1" right="$2"
  [[ "$left" == *:* ]] || left+=":latest"
  [[ "$right" == *:* ]] || right+=":latest"
  [[ "$left" == "$right" ]]
}

_json_parse_running_model() {
  local target="$1" key="" name="" model=""
  local -i context_length=0
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    case "$key:$JSON_TOKEN_TYPE" in
      name:string) name="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      model:string) model="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      context_length:number)
        [[ "$JSON_TOKEN_VALUE" == <1-> ]] && context_length="$JSON_TOKEN_VALUE"
        json_next || return 1
        ;;
      *) json_skip_value || return 1 ;;
    esac
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1
  if _json_model_names_match "$name" "$target" || _json_model_names_match "$model" "$target"; then
    JSON_RUNNING_MODEL_CONTEXT="$context_length"
  fi
}

# Read the context Ollama actually allocated to a loaded model from /api/ps.
json_parse_running_model_context() {
  local source="$1" target="$2" key=""
  JSON_RUNNING_MODEL_CONTEXT=0
  json_begin "$source" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1
  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1
    if [[ "$key" == models && "$JSON_TOKEN_TYPE" == '[' ]]; then
      json_next || return 1
      while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
        _json_parse_running_model "$target" || return 1
        if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
          json_next || return 1
        elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
          return 1
        fi
      done
      json_next || return 1
    else
      json_skip_value || return 1
    fi
    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  return 0
}

_json_parse_session_message() {
  local key="" role="" content="" thinking="" time="" expanded=0
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1

  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1

    case "$key:$JSON_TOKEN_TYPE" in
      role:string) role="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      content:string) content="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      thinking:string) thinking="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      time:string) time="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      thinking_expanded:true) expanded=1; json_next || return 1 ;;
      thinking_expanded:false) expanded=0; json_next || return 1 ;;
      *) json_skip_value || return 1 ;;
    esac

    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
  json_next || return 1

  JSON_SESSION_ROLES+=("$role")
  JSON_SESSION_CONTENTS+=("$content")
  JSON_SESSION_THINKINGS+=("$thinking")
  JSON_SESSION_EXPANDED+=("$expanded")
  JSON_SESSION_TIMES+=("$time")
}

# Decode the legacy JSON session format for one-time native migration.
json_parse_session() {
  local key=""
  JSON_SESSION_ID=""
  JSON_SESSION_TITLE="New Chat"
  JSON_SESSION_MODEL=""
  JSON_SESSION_SYSTEM=""
  JSON_SESSION_TEMPERATURE="0.7"
  JSON_SESSION_ROLES=()
  JSON_SESSION_CONTENTS=()
  JSON_SESSION_THINKINGS=()
  JSON_SESSION_EXPANDED=()
  JSON_SESSION_TIMES=()

  json_begin "$1" || return 1
  [[ "$JSON_TOKEN_TYPE" == '{' ]] || return 1
  json_next || return 1

  while [[ "$JSON_TOKEN_TYPE" != '}' ]]; do
    [[ "$JSON_TOKEN_TYPE" == string ]] || return 1
    key="$JSON_TOKEN_VALUE"
    json_next || return 1
    [[ "$JSON_TOKEN_TYPE" == ':' ]] || return 1
    json_next || return 1

    case "$key:$JSON_TOKEN_TYPE" in
      id:string) JSON_SESSION_ID="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      title:string) JSON_SESSION_TITLE="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      model:string) JSON_SESSION_MODEL="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      system_prompt:string) JSON_SESSION_SYSTEM="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      temperature:number) JSON_SESSION_TEMPERATURE="$JSON_TOKEN_VALUE"; json_next || return 1 ;;
      messages:'[')
        json_next || return 1
        while [[ "$JSON_TOKEN_TYPE" != ']' ]]; do
          _json_parse_session_message || return 1
          if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
            json_next || return 1
          elif [[ "$JSON_TOKEN_TYPE" != ']' ]]; then
            return 1
          fi
        done
        json_next || return 1
        ;;
      *) json_skip_value || return 1 ;;
    esac

    if [[ "$JSON_TOKEN_TYPE" == ',' ]]; then
      json_next || return 1
    elif [[ "$JSON_TOKEN_TYPE" != '}' ]]; then
      return 1
    fi
  done
}
