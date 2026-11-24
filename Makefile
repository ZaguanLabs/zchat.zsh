.PHONY: check test test-remote compile clean clean-zcurl zdraw curses zcurl

check:
	zsh -fc 'for f in zchat.zsh chat.sh lib/*.zsh scripts/*.zsh tests/*.zsh tests/fixtures/*.zsh(N); do zsh -n "$$f" || exit $$?; done'

zdraw: check
	zsh -df scripts/build-zdraw.zsh

# Compatibility with the original build command.
curses: zdraw

# Prepare local Zsh headers, build the pinned dependency, and verify loading.
# Set ZSH_SRC to reuse an already configured matching header tree.
zcurl: check
	+zsh -df scripts/build-zcurl.zsh "$(ZSH_SRC)"

test-remote: zcurl
	ZCHAT_ZCURL_LOADER="$(CURDIR)/vendor/zcurl/zcurl.zsh" zsh -df tests/remote.zsh

clean-zcurl:
	$(MAKE) -C vendor/zcurl clean

test: check
	zsh -df tests/run.zsh
	zsh -df tests/remote.zsh

# Precompile libraries to Zsh wordcode (.zwc). `source` uses a current .zwc
# automatically and ignores a stale one, so compilation is an optional startup
# optimization rather than a correctness requirement.
compile: check
	zsh -fc 'for f in lib/*.zsh; do zcompile -R $$f || exit; done'

clean:
	zsh -fc 'zmodload zsh/files; zf_rm -f lib/*.zwc(N)'
