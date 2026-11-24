#!/usr/bin/env zsh
# Explicit local build. Neither startup nor Ollama needs a compiler or download.
emulate -R zsh
setopt errexit nounset pipefail
typeset project_root=${0:A:h:h}
typeset dependency=$project_root/vendor/zcurl
[[ -f $dependency/Makefile ]] || {
  print -u2 -r -- 'Initialize zcurl: git submodule update --init -- vendor/zcurl'
  exit 1
}

typeset source_root=${1:-${ZSH_SRC:-}}
typeset -a build_args=()
if [[ -n $source_root ]]; then
  source_root=${source_root:A}
  [[ -f $source_root/config.h && -f $source_root/Src/zsh.mdh && -f $source_root/Src/version.h ]] || {
    print -u2 -r -- 'ZSH_SRC must point to a configured Zsh source tree with generated headers.'
    exit 1
  }
  build_args+=("ZSH_SRC=$source_root")
else
  # The pinned dependency downloads checksum-verified Zsh 5.9.2 sources and
  # generates headers locally; it never installs or replaces the user's shell.
  zsh -df "$dependency/scripts/prepare-zsh.zsh"
  # Upstream's headers target omits version.h, which zcurl also includes.
  # Generate it using Zsh's own rule rather than synthesizing an ABI version.
  make -C "$dependency/.deps/zsh-$ZSH_VERSION/Src" -f Makemod version.h
fi

make -C "$dependency" "${build_args[@]}" all
# Exercise the actual loader in a fresh process, as remote workers will do.
zsh -dfc 'source "$1" && zcurl --version' zchat-zcurl "$dependency/zcurl.zsh"
print -r -- 'Local zcurl ready. Remote profiles use it automatically; run make test-remote to verify HTTP/HTTPS.'
