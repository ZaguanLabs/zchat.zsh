.PHONY: check test compile clean zdraw curses

check:
	zsh -fc 'for f in zchat.zsh chat.sh lib/*.zsh scripts/*.zsh tests/*.zsh tests/fixtures/*.zsh(N); do zsh -n "$$f" || exit $$?; done'

zdraw: check
	zsh -df scripts/build-zdraw.zsh

# Compatibility with the original build command.
curses: zdraw

test: check
	zsh -df tests/run.zsh

# Precompile libraries to Zsh wordcode (.zwc). `source` uses a current .zwc
# automatically and ignores a stale one, so compilation is an optional startup
# optimization rather than a correctness requirement.
compile: check
	zsh -fc 'for f in lib/*.zsh; do zcompile -R $$f || exit; done'

clean:
	zsh -fc 'zmodload zsh/files; zf_rm -f lib/*.zwc(N)'
