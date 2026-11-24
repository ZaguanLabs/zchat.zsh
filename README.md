# ⚡ zchat.zsh v1.0.12 — Native ZSH & Curses AI Terminal Interface

> A full-screen, split-pane Terminal User Interface (TUI) AI chat client written in **pure ZSH**, connecting directly to **Ollama's Chat API** through Zsh's native TCP module, with optional provider-agnostic remote APIs through [zcurl](https://github.com/ZaguanLabs/zcurl), live token streaming, collapsible reasoning, and rich Markdown rendering.

---

## 🚀 Quick Start

With [Ollama](https://ollama.com/) installed and running:

```bash
ollama pull gemma4:12b
git clone --recurse-submodules https://github.com/ZaguanLabs/zchat.zsh.git
cd zchat.zsh
./zchat.zsh
```

Start typing and press `Enter` to chat. Press `Ctrl+Q` to quit.

To use another installed model or a remote Ollama server:

```bash
./zchat.zsh --model MODEL_NAME --host HOST:11434
```

See [System Requirements & Prerequisites](#-system-requirements--prerequisites) if Zsh reports a missing module.

---

## 📖 Table of Contents

- [Quick Start](#-quick-start)
- [Remote models through zcurl](#remote-models-through-zcurl)
- [Overview](#-overview)
- [System Requirements & Prerequisites](#-system-requirements--prerequisites)
- [Key Features](#-key-features)
  - [Live Reasoning & Auto-Collapsing](#1-live-reasoning--auto-collapsing)
  - [Terminal Markdown & Syntax Engine](#2-terminal-markdown--syntax-engine)
  - [Multi-Pane Responsive TUI](#3-multi-pane-responsive-tui)
  - [Session Persistence & Sidebar History](#4-session-persistence--sidebar-history)
  - [Model Switcher & System Prompts](#5-model-switcher--system-prompts)
- [Keyboard Shortcuts Reference](#-keyboard-shortcuts-reference)
- [Slash Commands](#-slash-commands)
- [Project Architecture](#-project-architecture)
- [Configuration & Data Storage](#-configuration--data-storage)
- [Troubleshooting & FAQ](#-troubleshooting--faq)

---

## Remote models through zcurl

Ollama continues to use the existing native TCP transport and needs no new
module. Remote profiles use the optional [zcurl](https://github.com/ZaguanLabs/zcurl)
Zsh module for HTTP/HTTPS, with certificate and hostname verification enabled.
zcurl is pinned as a project-local submodule under `vendor/zcurl`. Build it from
the zchat directory:

```zsh
git submodule update --init -- vendor/zcurl
make zcurl
export CHAT_API_KEY='your-api-key'
```

The default build currently targets **Zsh 5.9.2**. It downloads the pinned Zsh
source archive over HTTPS, verifies its SHA-256 checksum, configures it, generates
module headers, and builds `vendor/zcurl/build/zcurl.so`. It then verifies that
the module loads in a fresh Zsh process. Sources and headers remain under
`vendor/zcurl/.deps`; nothing is installed globally and your shell is not replaced.

Build prerequisites are Zsh 5.9.2, a C compiler, make, pkg-config, libcurl
development files **>= 8.16.0** with WebSocket support, plus curl, tar with xz
support, sha256sum, and Zsh's configure dependencies. Remote support is not
currently validated on Zsh 5.8. Ordinary Ollama use requires no zcurl build.

To reuse a configured source tree with generated headers that matches your Zsh
build, run `make zcurl ZSH_SRC=/absolute/path/to/zsh-source`. Matching the version
alone does not guarantee ABI compatibility across distribution patches and build
options; use matching sources when the default headers are unsuitable.

Remote requests automatically load `vendor/zcurl/zcurl.zsh`; no environment
override is required. You can still use a separately built module by setting
`ZCHAT_ZCURL_LOADER=/absolute/path/to/zcurl/zcurl.zsh`. Build/download steps run
only when explicitly requested, never during chat startup. Re-run `make zcurl`
after updating the dependency or your Zsh installation. `make clean-zcurl`
removes compiled zcurl modules while retaining downloaded sources and headers.

Create `~/.config/zchat/remotes.json` (or
`$XDG_CONFIG_HOME/zchat/remotes.json`). Start with
[examples/remotes.json](examples/remotes.json), replacing the endpoint and model
IDs with those supplied by your provider. Each entry is independently configured;
there is no provider allowlist or automatic endpoint rewriting. Use the **full
endpoint URL**, including its API path.

A minimal profile:

```json
{
  "models": {
    "work": {
      "protocol": "chat-completions",
      "url": "https://your-provider.example/v1/chat/completions",
      "model": "your-model-id",
      "api_key_env": "CHAT_API_KEY"
    }
  }
}
```

Select it with `./zchat.zsh --model remote:work`, `/model remote:work`, or the
`Ctrl+O` model picker. Session persistence remembers the profile alias. Ordinary
model names still select Ollama; `/host` still configures only Ollama. Set
`ZCHAT_REMOTE_CONFIG` to an absolute filename to use another configuration file.
Configuration is read at startup; restart after editing profiles.

Profile names are your local display/selection aliases, separate from the
provider's `model` ID. Start them with a letter or digit; subsequent characters
may include letters, digits, dots, underscores, and hyphens. For example,
`"glm-5.3-flash"` is selected with `/model remote:glm-5.3-flash`.

| Profile field | Meaning |
| --- | --- |
| `protocol` | Required: `chat-completions`, `responses`, or `messages` |
| `url`, `model` | Required: full HTTP(S) endpoint and provider model ID |
| `auth` | `bearer` (default), `api-key` (`x-api-key`), or `none` |
| `api_key_env` | Name of an **exported** environment variable containing the key; required unless `auth` is `none` |
| `context_window` | Provider/model context capacity, 4096–1048576; defaults to 65536 |
| `max_output_tokens` | Output allowance, less than context capacity; defaults to 4096 |
| `token_field` | Chat Completions only: `max_tokens` (default) or `max_completion_tokens`, depending on the endpoint |
| `headers` | Literal extra headers, such as `anthropic-version` or routing metadata |
| `header_env` | Extra header names mapped to exported environment-variable names; useful for other authentication schemes with `auth: "none"` |
| `ca_file` | Optional absolute path to a PEM CA trust file for private HTTPS endpoints; verification stays enabled |
| `parameters` | Extra JSON request fields, such as `temperature`, `reasoning`, or `stream_options` |

Set context and output limits to values your model actually supports. Remote
profiles use these configured limits, independently of Ollama's context discovery
and `--context-window`. Remote automatic and `/compact` checkpoints use the
selected remote model. No remote request, including compaction, is sent to Ollama.

Temperature is omitted unless configured in `parameters`, allowing models that
reject that option. To request Chat Completions usage events, use
`"parameters": {"stream_options": {"include_usage": true}}` if the endpoint
supports it. Without usage, context accounting uses estimates. Messages providers
may require a version header; configure that in `headers` as shown in the example.

For Responses, `max_output_tokens` covers reasoning as well as visible text.
If the server reports `response.incomplete` with reason `max_output_tokens`,
increase the profile's output allowance or use a lower supported
`parameters.reasoning.effort`. zchat reports provider error messages, codes, and
parameter names for JSON HTTP errors and SSE errors. A successful Responses
stream must contain `response.completed` with `response.status: "completed"`;
an optional gateway `[DONE]` marker is accepted only after that event.
Compressed HTTP streams are decoded by zcurl before SSE parsing.

These adapters support text conversations, system instructions, streamed text,
reasoning where supplied, token usage, cancellation, and protocol/API errors.
They follow the [Chat Completions/Responses streaming formats](https://developers.openai.com/api/docs/guides/streaming-responses)
and [Messages streaming format](https://platform.claude.com/docs/en/build-with-claude/streaming).
Tools, multimodal inputs, and multiple simultaneous choices are not supported.
Core request fields and token limits cannot be overridden through `parameters`.
Credentials remain outside session files when referenced through environment
variables. Only configure endpoints you intend to send the conversation to.

zcurl is loaded inside a fresh Zsh worker because its handles cannot be inherited
by forked workers. It streams into private handoff files while the interface
remains responsive. The integration uses zcurl's concurrent HTTP and regular-file
output APIs (tested with `0.27.0-dev`). zchat adds no Python, curl executable, or jq
runtime dependency. Python is used only by the optional local integration tests:

```zsh
make test-remote  # Build local zcurl and run remote protocol/HTTP/HTTPS checks
make test         # Full suite; includes integration checks when zcurl is built
```

---

## 🌟 Overview

**`zchat.zsh`** explores what is possible when pushing modern ZSH to its limits. Instead of relying on frameworks, Electron, or external runtime utilities, `zchat.zsh` uses Zsh's loadable modules to provide the interface, networking, JSON processing, persistence, and rendering itself.

```text
╭──────────────────────────────────────────────────────────────────────╮
│ zchat.zsh · gemma4:12b (localhost:11434)                    [ Ready ] │
╰──────────────────────────────────────────────────────────────────────╯
╭─ Sessions (2) ───╮╭─ Chat Transcript (2 msgs) ───────────────────────╮
│ ▶ Sunset colors ││ You  18:42                                       │
│   Weekend plans ││   Why does the sky turn pink at sunset?          │
│                 ││                                                 │
│                 ││ Assistant (gemma4:12b)  18:42                     │
│                 ││   Sunlight travels through more air at sunset.  │
│                 ││   Blue light scatters away, leaving warmer       │
│                 ││   colors.                                       │
╰─────────────────╯╰─────────────────────────────────────────────────╯
╭─ Message ───────────────────────────────────────────────────────────╮
│ ❯ Does the same thing happen at sunrise?                            │
╰─────────────────────────────────────────────────────────────────────╯
 Enter Send   Alt+Enter Newline   ^O Model   ^N New   ^H Help   ^Q Quit
```

---

## 🛠️ System Requirements & Prerequisites

To run `zchat.zsh`, your system requires:

| Tool | Required Version | Purpose | How to Verify |
| :--- | :--- | :--- | :--- |
| **`zsh`** | $\ge$ 5.8 | The complete client runtime | `zsh --version` |
| **Zsh modules** | Included with Zsh | `curses`, `datetime`, `files`, `mapfile`, `net/tcp`, `system`, `terminfo`, and `zselect` | `zsh -c 'zmodload zsh/curses zsh/net/tcp zsh/system && echo OK'` |
| **`Ollama`** | Running instance | AI model inference backend (local LAN or localhost) | `curl http://localhost:11434/api/tags` |

`curl` in the Ollama verification example is optional. The application itself does not invoke curl, jq, Python, fold, coreutils, or any other external runtime utility.

### Terminal theme and zdraw

The interface uses deep teal surfaces, seafoam focus accents, and amber labels
for your messages. The transcript has an open reading area with a capped line
width. The composer, sessions rail, and shortcut bar adapt to the terminal size.

The [`zdraw`](https://github.com/ZaguanLabs/zdraw) v0.1.4 submodule adds rounded
borders, native terminal geometry, cell-clipped spans, and region fills for rules
and selection highlights. The theme uses RGB where supported and also works in
256-color, basic ANSI, and monochrome terminals.

Build the module against a configured, built Zsh source tree matching the Zsh
you use to launch zchat.

```sh
git submodule update --init --recursive
ZSH_BUILD_ROOT=/path/to/matching/configured/zsh make zdraw
./zchat.zsh
```

Build tools are needed only for this optional step: a C compiler, GNU Make,
curses development headers, Autoconf/Autoheader, M4, Patch and standard Unix build
utilities. See [the vendored build guide](vendor/zdraw/docs/building.md)
for public-source setup. The application integration requires a matching built
shell; the module's standalone guide can also build an extracted release.
If you built an older zdraw before updating the submodule, run
`make -C vendor/zdraw clean` before rebuilding.

Startup selects the locally built module only when its recorded Zsh version,
patch level, platform and host match. It never builds at startup or changes the
system module. An absent or incompatible local build falls back to stock curses;
an already loaded module is retained. Rebuild after changing Zsh or hosts.
The bundle loads as `zmodload zdraw`, with its own `zdraw` builtin and parameters;
stock `zsh/curses` remains separate. The application selects one drawing backend
for the entire terminal session.

`make curses` and `ZCHAT_CURSES=stock` remain accepted for existing launchers;
use `make zdraw` and `ZCHAT_DRAW` for new setups. If both environment variables
are set, `ZCHAT_DRAW` takes precedence.

| Environment variable | Default | Override |
| :--- | :--- | :--- |
| `ZCHAT_DRAW` | `auto` | `stock` uses the installed module |
| `ZCHAT_COLOR` | `auto` | `basic` uses ANSI colors and `mono` disables color. `auto` respects `NO_COLOR`. |
| `ZCHAT_BORDERS` | `auto` | `plain` uses standard curses borders |
| `ZCHAT_SPANS` | `true` | `false` uses individual drawing calls |
| `ZCHAT_SYNC_OUTPUT` | `auto` | `false` disables synchronized frames; `true` forces them |

For example, `ZCHAT_DRAW=stock ./zchat.zsh` starts with stock curses. Both paths
use native Zsh at runtime. Stock curses keeps the muted 256-color palette when
available, with standard borders and a native terminfo resize fallback.

### Native input and presentation

The updated zdraw integration uses structured input events, bounded streaming
paste, grapheme boundaries, synchronized presentation, and suspend/resume when
available. Feature detection keeps stock curses and older modules usable.
With the matching native module, cursor movement and deletion preserve whole
accented letters, emoji modifiers, flags and joined emoji. Paste chunks are
reassembled before CRLF normalization; tabs expand to spaces, terminal controls
are removed, and pastes above 1 MiB are discarded in full. A paste started in a
picker stays discarded even if resizing closes the picker.

Stock curses retains its terminal's input processing, including CR translation
and signal handling; native zdraw paste bypasses that processing. Synchronized
output is enabled after a terminal capability reply, with balanced frame markers
and cleanup. `/copy` uses native suspend/resume when available.

### Installing Missing Prerequisites

#### Debian / Ubuntu / Mint:
```bash
sudo apt update
sudo apt install zsh zsh-common
```

#### Arch Linux / Manjaro:
```bash
sudo pacman -S zsh
```

#### Fedora / RHEL:
```bash
sudo dnf install zsh
```

#### macOS (Homebrew):
```bash
brew install zsh
```

---

## ✨ Key Features

### 1. Live Reasoning & Auto-Collapsing
* **Real-Time Token Separation**: Native Zsh HTTP and JSON code decodes Ollama's chunked NDJSON stream and separates reasoning/thinking tokens from response tokens as they arrive.
* **Immediate Feedback**: The moment you press Enter, a `▼ 💭 Thinking...` block appears in the chat transcript with an animated spinner in the header.
* **Auto-Collapsing**: As soon as the main response starts arriving, the reasoning block collapses automatically into a compact single-line banner: `▶ 💭 Reasoning (N lines) [Press ^R to expand]`.
* **Interactive Toggle (`Ctrl+R` / `/think`)**: Expand or collapse reasoning blocks anytime without disrupting your chat view.
* **Incremental HTTP Framing**: Partial chunks display immediately. Content-Length and chunk boundaries are validated, and a final Ollama event cannot conceal truncated HTTP or trailing response data. Metadata requests finish at their declared body boundary.
* **Fail-Closed Streaming**: Each response is bound to its originating session, malformed or incomplete streams surface an error, and cancelled requests leave no empty assistant placeholder.

### 2. Terminal Markdown & Syntax Engine
* **Headings**: `# H1` (bold magenta), `## H2` (cyan), `### H3` (yellow), `#### H4` (white).
* **Fenced Code Blocks**: Language labels, line numbers, muted comments, and wrapped long lines.
* **Unicode Tables**: Automatically converts standard Markdown tables (`| Col 1 | Col 2 |`) into clean Unicode box tables (`┌─┬─┐`, `│ │ │`, `├─┼─┤`, `└─┴─┘`).
* **Lists & Hanging Indents**: Bullet lists (`•`), numbered lists (`1.`), and checkboxes (`☐ Todo` / `☑ Done`) wrapped cleanly with hanging indents.
* **Blockquotes**: Single (`>`) and nested (`>>`) blockquotes styled with vertical accent bars (`▎`).
* **Inline Spans**: Multi-span rendering for `**bold**`, `*italic*`, `` `inline_code` ``, `~~strikethrough~~`, and `[links](url)`.

### 3. Multi-Pane Responsive TUI
* **Header Bar**: Shows the active model, backend, and live status. The Ollama endpoint appears when space permits.
* **Sidebar Toggle (`Ctrl+B` / `/sidebar`)**: Hide the sessions pane for more reading space; the choice persists across launches. Narrow terminals still hide it automatically.
* **Slash Suggestions**: Type `/` to discover chat commands. Use Up/Down to select, Tab or Enter to complete, then Enter to run. Escape closes suggestions.
* **Sidebar Pane**: Lists saved chats and keeps the active conversation visible as you browse.
* **Chat Viewport**: Scrollable message transcript with automatic viewport scrolling during generation.
* **Stable Transcript Copy (`Ctrl+Y` / `/copy`)**: Temporarily leaves curses and prints the visible transcript as plain text for reliable native terminal selection and copying. Expanded reasoning is included; collapsed reasoning stays hidden.
* **Incremental Rendering**: Finalized messages are cached while only newly appended stream bytes and the active response are processed; terminal windows refresh as one frame.
* **Multiline Prompt Editor**: A one-to-four-row cursor-following viewport with soft wrapping, hard newlines via `Shift+Enter` or `Alt+Enter`, vertical cursor movement, draft-preserving prompt history, and safe bracketed multiline paste.
* **Footer Bar**: Shortcuts change with focus and while a response streams. Help and Quit stay visible at the minimum supported size.
* **Dynamic Sizing**: Polls terminal geometry, hides the sidebar on narrow terminals, and shows a resize hint below 32 columns or 12 rows. Open pickers close on resize so their windows cannot remain off-screen.

### 4. Session Persistence & Sidebar History
* All sessions are saved automatically in native directory-backed storage under `~/.config/zchat/sessions/`.
* Configuration, transcripts, and temporary request files are private to the current user by default (`0600` files in `0700` directories).
* Switch between past conversations instantly from the sidebar using `Tab` and `↑`/`↓`.
* Delete sessions directly with `d` or `x`.
* Long conversations retain their complete visible transcript while the model receives a persisted compact checkpoint plus a bounded recent raw exchange.

### 5. Model Switcher & System Prompts
* **Model Picker (`Ctrl+O`)**: Queries your Ollama server's `/api/tags` endpoint and opens an interactive modal to browse and switch models live.
* **Context-aware model loading**: In `auto` mode, zchat uses the active allocation reported by Ollama's `/api/ps`. For an unloaded model, the 65,536-token fallback is used only for provisional accounting: the first request omits `num_ctx` so Ollama can apply the model or server default. After the response, zchat discovers and pins the authoritative allocation for later requests.
* **System Prompt Presets (`Ctrl+S`)**: Quick-switch between personas:
  * *Default* (Helpful & Knowledgeable)
  * *Coding* (Expert Software Engineer)
  * *Concise* (Direct, minimal fluff)
  * *Explain Like I'm 5* (Simple analogies)
  * *Custom Prompt*

---

## ⌨️ Keyboard Shortcuts Reference

| Keybinding | Action | Description |
| :--- | :--- | :--- |
| **`Enter`** | **Send Message** | Submits the current input prompt to Ollama |
| **`Shift + Enter`** / **`Alt + Enter`** | **Newline** | Inserts a newline without sending; Alt+Enter is the terminal-compatible fallback |
| **`Ctrl + R`** (`^R`) | **Toggle Reasoning** | Expands or collapses the reasoning block of the current response |
| **`Ctrl + Y`** (`^Y`) | **Copy Transcript** | Opens a stable plain-text view for native terminal selection and copying |
| **`Ctrl + O`** (`^O`) | **Model Selector** | Opens interactive modal to select installed Ollama models |
| **`Ctrl + N`** (`^N`) | **New Chat** | Starts a fresh chat session with the current model |
| **`Ctrl + S`** (`^S`) | **System Prompts** | Opens system prompt persona preset selector |
| **`Ctrl + C`** (`^C`) | **Cancel / Clear** | Cancels active generation or clears the input box |
| **`Ctrl + B`** | **Toggle Sidebar** | Saves your preference for showing the sessions pane |
| **`Alt + 1`** / **`Alt + 2`** | **Focus Pane** | Focuses visible sessions / message input |
| **`Tab`** | **Cycle Focus** | Switches focus between Input $\rightarrow$ Sidebar $\rightarrow$ Chat |
| **`PgUp` / `PgDn`** | **Scroll Chat** | Scrolls chat transcript history up or down |
| **`Home` / `End`** | **Jump Chat** | Jumps directly to the start or end of the conversation |
| **`Up` / `Down`** | **Prompt / History / Nav** | Moves through multiline prompt rows, then recalls history at prompt boundaries; navigates sessions in the sidebar |
| **`Ctrl + U`** (`^U`) | **Clear Line** | Clears the entire current input line |
| **`Ctrl + W`** (`^W`) | **Kill Word** | Deletes the word immediately preceding the cursor |
| **`Ctrl + H`** / **`F1`** | **Help** | Displays the full keyboard shortcut overlay |
| **`d`** / **`x`** | **Delete Session** | Deletes the highlighted conversation (when sidebar is focused) |
| **`Ctrl + Q`** / **`Ctrl + D`** | **Quit** | Gracefully restores the terminal and exits `zchat.zsh` |

---

## 💬 Slash Commands

You can type these directly into the prompt box and hit `Enter`:

| Command | Action |
| :--- | :--- |
| `/reason` or `/think` | Toggle reasoning expand/collapse |
| `/copy` | Open the plain-text transcript copy view |
| `/sidebar` | Toggle and remember sessions sidebar visibility |
| `/model` | Open the model selector dialog |
| `/model NAME` | Switch directly to an Ollama model |
| `/host` | Show the current Ollama URL and change-command help |
| `/host http://hostname:11434` | Change and persist the Ollama URL |
| `/sys` or `/system` | Open the system prompt presets dialog |
| `/new` or `/clear` | Start a new chat session |
| `/compact` | Manually create a conversation continuation checkpoint |
| `/context` | Show context allocation, estimate, threshold, and checkpoint count |
| `/help` or `/?` | Show keyboard shortcut help overlay |
| `/quit` or `/exit` or `/q` | Exit application |

---

## 🏛️ Project Architecture

```
zchat.zsh/
├── zchat.zsh           # Main application entry point & curses event loop
├── chat.sh             # Portable launcher script
├── Makefile            # Checks, tests, optional module build & wordcode
├── scripts/build-zdraw.zsh # Build and validate the local module
├── vendor/zdraw/     # Pinned standalone module submodule
├── README.md           # Documentation & user guide
└── lib/
    ├── api.zsh         # Native TCP Ollama client & stream splitter
    ├── http.zsh        # Incremental, bounded HTTP response framing
    ├── json.zsh        # Native JSON tokenizer, decoder & encoder
    ├── util.zsh        # Native wrapping, padding, time & file helpers
    ├── state.zsh       # Directory-backed session persistence & state
    ├── compact.zsh     # Context sizing, token estimates & checkpoints
    ├── render.zsh      # Markdown parser, table formatter & reasoning styling
    ├── input.zsh       # Cell-aware editor, viewport, history & paste decoder
    ├── draw.zsh        # Compatible local module selection and stock fallback
    ├── drawing.zsh     # Palette, rounded borders & bounded styled rows
    ├── terminal.zsh    # Structured events, paste, synchronized frames & handoff
    ├── commands.zsh    # Chat-only inline slash-command suggestions
    ├── ui_preferences.zsh # Private, atomic sidebar preference storage
    ├── modal.zsh       # Model/prompt pickers & scrollable keyboard help
    └── ui.zsh          # Multi-window curses layout, geometry & rendering
```

### Library Loading & Optional Compilation

`zchat_require` sources every library at most once. The core chat, state, and
rendering libraries load for the full-screen client, while `modal.zsh` loads
only when a model picker, system-prompt picker, or help overlay is opened.
Fast `--help` and `--version` exits do not load the TUI runtime.

Run `make compile` to precompile the libraries to Zsh `.zwc` wordcode. Zsh
automatically uses a compiled file when it is current and ignores it when the
matching `.zsh` source is newer, so compilation is optional and never required
for correctness. Run `make clean` to remove generated wordcode.

`make test` runs syntax checks, chat regressions, module selection tests and real
PTY drawing/input/resize checks. The PTY checks need Zsh's `zpty` module and
`stty` as test tools; neither is an application runtime dependency. They always
exercise stock curses and also exercise the bundled module when a compatible
local build is available. Tests also cover fragmented HTTP over real sockets,
Unicode editing, synchronized frames, paste isolation and command completion.

### Event Loop Flow
1. **Input Polling**: Structured `zdraw event` (or stock `zcurses input`) polls with a 50ms timeout. One input owner decodes paste, capability replies and keys before editor or command dispatch.
2. **Stream Processing**: A background Zsh worker uses `zsh/net/tcp`, `sysread`, and a native HTTP chunk decoder to consume Ollama's NDJSON stream in a private runtime directory, publishing an explicit completion status.
3. **Incremental Frame Updates**: The event loop reads only newly appended reasoning/content bytes, reuses the rendered transcript prefix, and batches curses windows into one terminal refresh at a throttled frame rate.
4. **Completion**: Only a valid stream ending in Ollama's final `done:true` event is persisted. Prompt usage calibrates future context estimates; failures and cancellation discard the in-memory placeholder.

### Context Compaction

Compaction follows the continuation-checkpoint design used by `zcoder.zsh`, adapted for ordinary chat rather than tools or coding work:

1. Ollama's `prompt_eval_count` calibrates a conservative pre-request estimate. Before the first usage sample, zchat estimates three bytes per token plus fixed chat-template headroom.
2. Automatic compaction starts at 85% of the allocated context by default. Change it with `--compact-at PERCENT` or `ZCHAT_COMPACT_PERCENT`.
3. A logarithmic cutoff search finds the earliest user-turn-aligned history that fits the checkpoint request, avoiding repeated full-history encoding on long conversations.
4. A non-streaming, non-thinking model turn creates a concise chat checkpoint, capped at the smaller of 2,048 tokens or 10% of the active context.
5. The model context becomes that checkpoint plus a recent raw tail of the conversation. The full TUI transcript remains visible and saved.
6. Checkpoints, the user-turn-aligned raw-tail boundary, token calibration, rearm threshold, and bounded non-duplicated exact-user ledger are persisted with each session, so resumed conversations keep their compacted context.

Context sizing defaults to `auto`. If the selected model is loaded, zchat uses and pins the allocation from Ollama's `/api/ps`. If it is unloaded, zchat temporarily uses 65,536 tokens for its own estimates but omits `num_ctx` from the first request, allowing Ollama to choose the model or server default; it then refreshes and pins that active allocation after the response. Use `--context-window TOKENS` or `ZCHAT_CONTEXT_WINDOW` to request and pin a fixed allocation from the first request. Larger contexts consume more memory.

Use `/compact` to checkpoint manually and `/context` to inspect the current budget. Repeated summaries can gradually lose precision, so a focused new chat is still preferable when an old thread is no longer useful.

---

## ⚙️ Configuration & Data Storage

All user configuration and conversation histories are stored following the XDG Base Directory specification:

* **Config File**: `~/.config/zchat/config.json`
  ```json
  {
    "host": "localhost:11434",
    "default_model": "gemma4:12b",
    "temperature": 0.7,
    "system_prompt": "You are a helpful, knowledgeable, and concise AI assistant."
  }
  ```
* **UI Preferences**: `~/.config/zchat/ui-preferences` stores sidebar visibility as literal data, separately from conversations.
* **Saved Sessions**: `~/.config/zchat/sessions/<timestamp>_<id>.session/`

Session fields and message bodies are stored as raw files inside each session directory and accessed through `zsh/mapfile`; no serialization subprocess is needed. Files use mode `0600`, directories use `0700`, and metadata counts are written last as commit markers. Existing `.json` sessions are migrated automatically on startup, retained as backups, and secured on the next launch.

---

## ❓ Troubleshooting & FAQ

### Q: Why are the drawing modules unavailable?
**A:** Build the vendored `zdraw` module with `make zdraw`, or install Zsh with its stock `zsh/curses` module. On Debian/Ubuntu, ensure `zsh` and `zsh-common` are installed.

### Q: Can I use local models without LAN?
**A:** Yes! Launch with `--host localhost:11434` or update `~/.config/zchat/config.json`.

### Q: How do I change the Ollama URL?
**A:** From inside `zchat.zsh`, enter `/host http://hostname:11434`. This saves the new URL immediately. For a temporary launch override, use `--host URL` or set the `OLLAMA_HOST` environment variable. The precedence is command-line/environment override, saved configuration, then `localhost:11434`.

### Q: Why didn't reasoning show for my model?
**A:** Reasoning tokens are only produced by models that support thinking (e.g. `gemma4:12b`, `deepseek-r1`, `qwen3.6`, etc.). Standard non-reasoning models stream straight into the main response.

---

## 📄 License

Apache-2.0 License — feel free to explore, hack on, and extend this ZSH experiment!
