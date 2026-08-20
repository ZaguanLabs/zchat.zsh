#!/usr/bin/env zsh
# Launcher for zchat
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"
DIR="${0:A:h}"
exec zsh "${DIR}/zchat.zsh" "$@"
