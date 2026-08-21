# ⚡ zchat.zsh v1.0.3 — Native ZSH & Curses AI Terminal Interface

> A full-screen, split-pane Terminal User Interface (TUI) AI chat client written in **pure ZSH**, connecting directly to **Ollama's Chat API** through Zsh's native TCP module with live token streaming, collapsible reasoning, and rich Markdown rendering.

---

## 🚀 Quick Start

With [Ollama](https://ollama.com/) installed and running:

```bash
ollama pull gemma4:12b
git clone https://github.com/ZaguanLabs/zchat.zsh.git
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

## 🌟 Overview

**`zchat.zsh`** explores what is possible when pushing modern ZSH to its limits. Instead of relying on frameworks, Electron, or external runtime utilities, `zchat.zsh` uses Zsh's loadable modules to provide the interface, networking, JSON processing, persistence, and rendering itself.

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ⚡ zchat.zsh v1.0.3 │ Model: gemma4:12b (localhost:11434)     [ Ready ]   │
├───────────────┬───────────────────────────────────────────────────────────┤
│ Sessions (3)  │  Chat Transcript (4 msgs)                                 │
│ ▶ Hello World │  🧑 You  11:00                                            │
│   Python Math │    What is Rayleigh scattering?                           │
│   Refactor    │                                                           │
│               │  🤖 Assistant (gemma4:12b)  11:00                         │
│               │    ▶ 💭 Reasoning (18 lines) [Press ^R to expand]         │
│               │                                                           │
│               │    Rayleigh scattering refers to the scattering of light  │
│               │    by particles much smaller than the wavelength of...    │
├───────────────┴───────────────────────────────────────────────────────────┤
│ Prompt (Enter to Send, Ctrl+C to cancel)                                  │
│ ❯ Explain it like I'm 5                                                   │
├───────────────────────────────────────────────────────────────────────────┤
│ [Enter] Send  [^O] Model  [^R] Reason  [^N] New  [^S] System  [^Q] Quit   │
└───────────────────────────────────────────────────────────────────────────┘
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

### 2. Terminal Markdown & Syntax Engine
* **Headings**: `# H1` (bold magenta), `## H2` (cyan), `### H3` (yellow), `#### H4` (white).
* **Fenced Code Blocks**: Language badges (`┌──   [python] ──`), line numbers, comment highlighting, and clean box borders.
* **Unicode Tables**: Automatically converts standard Markdown tables (`| Col 1 | Col 2 |`) into clean Unicode box tables (`┌─┬─┐`, `│ │ │`, `├─┼─┤`, `└─┴─┘`).
* **Lists & Hanging Indents**: Bullet lists (`•`), numbered lists (`1.`), and checkboxes (`☐ Todo` / `☑ Done`) wrapped cleanly with hanging indents.
* **Blockquotes**: Single (`>`) and nested (`>>`) blockquotes styled with vertical accent bars (`▎`).
* **Inline Spans**: Multi-span rendering for `**bold**`, `*italic*`, `` `inline_code` ``, `~~strikethrough~~`, and `[links](url)`.

### 3. Multi-Pane Responsive TUI
* **Header Bar**: Displays active model, Ollama endpoint, and animated status badges (`[ Thinking ⠋ ]`, `[ Streaming ⠋ ]`, `[ Ready ]`).
* **Sidebar Pane**: Lists saved chat sessions with the active conversation highlighted.
* **Chat Viewport**: Scrollable message transcript with automatic viewport scrolling during generation.
* **Multiline Prompt Editor**: A one-to-four-row cursor-following viewport with soft wrapping, hard newlines via `Shift+Enter` or `Alt+Enter`, vertical cursor movement, draft-preserving prompt history, and safe bracketed multiline paste.
* **Footer Bar**: Live keybinding shortcuts and status hints.
* **Dynamic Sizing**: Automatically adapts to window resizing (`SIGWINCH`) and gracefully scales on smaller terminal dimensions.

### 4. Session Persistence & Sidebar History
* All sessions are saved automatically in native directory-backed storage under `~/.config/zchat/sessions/`.
* Switch between past conversations instantly from the sidebar using `Tab` and `↑`/`↓`.
* Delete sessions directly with `d` or `x`.
* Long conversations retain their complete visible transcript while the model receives a persisted compact checkpoint plus a bounded recent raw exchange.

### 5. Model Switcher & System Prompts
* **Model Picker (`Ctrl+O`)**: Queries your Ollama server's `/api/tags` endpoint and opens an interactive modal to browse and switch models live.
* **Context-aware model loading**: In `auto` mode, zchat uses the active allocation reported by Ollama's `/api/ps`, falls back conservatively for unloaded models, then refreshes after the first response. The chosen `num_ctx` is pinned in chat requests.
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
| **`Ctrl + O`** (`^O`) | **Model Selector** | Opens interactive modal to select installed Ollama models |
| **`Ctrl + N`** (`^N`) | **New Chat** | Starts a fresh chat session with the current model |
| **`Ctrl + S`** (`^S`) | **System Prompts** | Opens system prompt persona preset selector |
| **`Ctrl + C`** (`^C`) | **Cancel / Clear** | Cancels active generation or clears the input box |
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
chat.sh/
├── zchat.zsh           # Main application entry point & curses event loop
├── chat.sh             # Portable launcher script
├── README.md           # Documentation & user guide
└── lib/
    ├── api.zsh         # Native TCP/HTTP Ollama client & stream splitter
    ├── json.zsh        # Native JSON tokenizer, decoder & encoder
    ├── util.zsh        # Native wrapping, padding, time & file helpers
    ├── state.zsh       # Directory-backed session persistence & state
    ├── compact.zsh     # Context sizing, token estimates & checkpoints
    ├── render.zsh      # Markdown parser, table formatter & reasoning styling
    ├── input.zsh       # Multiline editor, viewport, history & event decoder
    ├── modal.zsh       # Overlay modals for models, system prompts & help
    └── ui.zsh          # Multi-window curses layout, geometry & rendering
```

### Event Loop Flow
1. **Input Polling**: `zcurses input` polls non-blocking with a 50ms timeout. Native event decoding recognizes Shift/Alt+Enter and bracketed paste.
2. **Stream Processing**: A background Zsh worker uses `zsh/net/tcp`, `sysread`, and a native HTTP chunk decoder to consume Ollama's NDJSON stream into `.thinking` and `.content` spool files.
3. **In-Memory Frame Updates**: As new tokens arrive, `lib/state.zsh` updates in-memory arrays and triggers `ui_refresh_all 1` without disk I/O lag.
4. **Completion**: On stream finish, `state_save_session` persists the completed conversation, captures Ollama's prompt usage for token-estimate calibration, and transitions reasoning to collapsed state.

### Context Compaction

Compaction follows the continuation-checkpoint design used by `zcoder.zsh`, adapted for ordinary chat rather than tools or coding work:

1. Ollama's `prompt_eval_count` calibrates a conservative pre-request estimate. Before the first usage sample, zchat estimates three bytes per token plus fixed chat-template headroom.
2. Automatic compaction starts at 85% of the allocated context by default. Change it with `--compact-at PERCENT` or `ZCHAT_COMPACT_PERCENT`.
3. A non-streaming, non-thinking model turn creates a concise chat checkpoint, capped at the smaller of 2,048 tokens or 10% of the active context.
4. The model context becomes that checkpoint plus a recent raw tail of the conversation. The full TUI transcript remains visible and saved.
5. Checkpoints, the retained-tail boundary, and the bounded exact-user ledger are persisted with each session, so resumed conversations keep their compacted context.

Context sizing defaults to `auto`. If the selected model is loaded, zchat uses the allocation from Ollama's `/api/ps`; otherwise it starts with a 65,536-token fallback and refreshes after the first response. Use `--context-window TOKENS` or `ZCHAT_CONTEXT_WINDOW` to request a fixed allocation. Larger contexts consume more memory.

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
* **Saved Sessions**: `~/.config/zchat/sessions/<timestamp>_<id>.session/`

Session fields and message bodies are stored as raw files inside each session directory and accessed through `zsh/mapfile`; no serialization subprocess is needed. Existing `.json` sessions are migrated automatically on startup and retained as backups.

---

## ❓ Troubleshooting & FAQ

### Q: Why do I see `zcurses module required`?
**A:** Your ZSH installation does not have `zsh/curses` compiled in. On Debian/Ubuntu, ensure `zsh` and `zsh-common` are installed.

### Q: Can I use local models without LAN?
**A:** Yes! Launch with `--host localhost:11434` or update `~/.config/zchat/config.json`.

### Q: How do I change the Ollama URL?
**A:** From inside `zchat.zsh`, enter `/host http://hostname:11434`. This saves the new URL immediately. For a temporary launch override, use `--host URL` or set the `OLLAMA_HOST` environment variable. The precedence is command-line/environment override, saved configuration, then `localhost:11434`.

### Q: Why didn't reasoning show for my model?
**A:** Reasoning tokens are only produced by models that support thinking (e.g. `gemma4:12b`, `deepseek-r1`, `qwen3.6`, etc.). Standard non-reasoning models stream straight into the main response.

---

## 📄 License

Apache-2.0 License — feel free to explore, hack on, and extend this ZSH experiment!
