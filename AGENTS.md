## zchat.zsh Project Introcution

`zchat.zsh` is a full-screen terminal chat client for Ollama, implemented in Zsh with native curses, TCP/HTTP, JSON handling, Markdown rendering, and session persistence.

## Development rules

- Keep the implementation pure, native Zsh wherever safely possible.
- Use external tools only when the required function cannot be implemented safely in Zsh. Do not add external runtime dependencies for convenience.
- Preserve compatibility with Zsh 5.8 or newer and its loadable modules.
- Before pushing updates to GitHub, increment the patch version unless the user explicitly says otherwise. Keep `ZCHAT_VERSION` in `zchat.zsh` and the version shown in `README.md` synchronized.
- Always push GitHub updates to the `main` branch.

# Atlas Scout

**Do not** use atlas-scout in this project. It has very limited support for Zsh shell scripts.
