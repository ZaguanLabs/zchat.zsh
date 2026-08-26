.PHONY: check test compile clean

check:
	zsh -n zchat.zsh chat.sh lib/*.zsh tests/*.zsh

test: check
	zsh tests/run.zsh

# Precompile libraries to Zsh wordcode (.zwc). `source` uses a current .zwc
# automatically and ignores a stale one, so compilation is an optional startup
# optimization rather than a correctness requirement.
compile: check
	zsh -fc 'for f in lib/*.zsh; do zcompile -R $$f || exit; done'

clean:
	zsh -fc 'zmodload zsh/files; zf_rm -f lib/*.zwc(N)'
