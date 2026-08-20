## zchat.zsh Project Introcution

`zchat.zsh` is a full-screen terminal chat client for Ollama, implemented in Zsh with native curses, TCP/HTTP, JSON handling, Markdown rendering, and session persistence.

## Development rules

- Keep the implementation pure, native Zsh wherever safely possible.
- Use external tools only when the required function cannot be implemented safely in Zsh. Do not add external runtime dependencies for convenience.
- Preserve compatibility with Zsh 5.8 or newer and its loadable modules.
- Before pushing updates to GitHub, increment the patch version unless the user explicitly says otherwise. Keep `ZCHAT_VERSION` in `zchat.zsh` and the version shown in `README.md` synchronized.
- Always push GitHub updates to the `main` branch.

# Atlas Scout

## Code navigation

When Atlas Scout MCP tools are available, **always** use them as the primary navigation path for repository
investigations that need the correct file, source range, or structural relationship. This includes
definitions, named symbols, unknown locations, callers, references, dependency paths, architecture,
and edit impact.

- If the file and range are already known, read that range directly.
- If a file is known but the relevant range is not, use `symbol_outline` before reading the file.
- If the location is unknown, use `symbol_search`, then `symbol_resolve` when exact metadata is
  needed.
- Use `symbol_references`, `symbol_graph`, `symbol_trace`, `symbol_path`, or `edit_impact` for the
  corresponding structural question.
- Read the exact source ranges returned by Atlas Scout before drawing conclusions or editing.
- Use `rg` or other raw-text search for literals, regexes, unmodeled text, unsupported/partial
  language coverage, an explicit user request, or after focused Atlas Scout queries miss.

Do not use shell text search as the default substitute for Atlas Scout when the task is structural
code navigation.
