assert_status_ok() { (( $2 == 0 )) && pass "$1" || fail "$1"; }
assert_status_failed() { (( $2 != 0 )) && pass "$1" || fail "$1"; }
source "$PROJECT_DIR/lib/draw.zsh"

# Exercise selection independently of curses, a compiler, or terminal state.
() {
  local test_root="$TEST_STATE_DIR/draw-loader"
  local test_build="$test_root/vendor/zdraw/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  local ZCHAT_DRAW=auto ZCHAT_DRAW_BACKEND=unloaded ZCHAT_DRAW_MODULE ZCHAT_DRAW_COMMAND
  local preloaded=""
  local -a original_path=("${module_path[@]}") loaded_paths=()
  local -i bundled_result=0 stock_result=0
  zf_mkdir -p "$test_build/modules"
  mapfile[$test_build/modules/zdraw.so]=''
  mapfile[$test_build/zchat-abi]="$signature"
  zmodload() {
    [[ $1 == -e ]] && { [[ $2 == "$preloaded" ]]; return $?; }
    loaded_paths+=("$module_path[1]")
    [[ $module_path[1] == "$test_build/modules" ]] && return "$bundled_result"
    return "$stock_result"
  }
  {
    zchat_draw_load "$test_root"
    assert_status_ok 'matching local zdraw build loads' $?
    assert_eq bundled "$ZCHAT_DRAW_BACKEND" 'matching build selects bundled zdraw'
    assert_eq zdraw "$ZCHAT_DRAW_MODULE" 'bundled loader uses the independent zdraw module'
    assert_eq zdraw "$ZCHAT_DRAW_COMMAND" 'bundled drawing dispatches to zdraw'
    assert_eq "$test_build/modules" "$loaded_paths[-1]" 'dependency path precedes system module paths'
    assert_eq "${(j.:.)original_path}" "${(j.:.)module_path}" 'loader restores caller module search path'
    ZCHAT_DRAW=stock
    zchat_draw_load "$test_root"
    assert_eq stock "$ZCHAT_DRAW_BACKEND" 'stock override bypasses a matching dependency'
    assert_eq zcurses "$ZCHAT_DRAW_COMMAND" 'stock fallback dispatches to the original builtin'
    ZCHAT_DRAW=''
    local ZCHAT_CURSES=stock
    zchat_draw_load "$test_root"
    assert_eq stock "$ZCHAT_DRAW_BACKEND" 'legacy environment override retains stock selection'
    ZCHAT_DRAW=auto
    mapfile[$test_build/zchat-abi]="other-host"
    zchat_draw_load "$test_root"
    assert_eq stock "$ZCHAT_DRAW_BACKEND" 'copied or incompatible binary uses stock module'
    zf_rm -- "$test_build/zchat-abi"
    zchat_draw_load "$test_root"
    assert_eq stock "$ZCHAT_DRAW_BACKEND" 'unbuilt dependency uses stock module'
    mapfile[$test_build/zchat-abi]="$signature"
    bundled_result=1; loaded_paths=()
    zchat_draw_load "$test_root"
    assert_status_ok 'failed bundled load recovers with stock module' $?
    assert_eq 2 "${#loaded_paths}" 'failed dependency load retries outside the dependency path'
    assert_eq "$original_path[1]" "$loaded_paths[-1]" 'fallback uses original module path'
    stock_result=1
    zchat_draw_load "$test_root"
    assert_status_failed 'unavailable stock and bundled modules propagate failure' $?
    preloaded=zsh/curses; loaded_paths=(); ZCHAT_DRAW_BACKEND=unloaded
    zchat_draw_load "$test_root"
    assert_eq preloaded "$ZCHAT_DRAW_BACKEND" 'already loaded curses is retained'
    assert_eq 0 "${#loaded_paths}" 'loader never replaces an active module'
    preloaded=zdraw; loaded_paths=(); ZCHAT_DRAW_BACKEND=unloaded
    zchat_draw_load "$test_root"
    assert_eq preloaded "$ZCHAT_DRAW_BACKEND" 'already loaded zdraw is retained'
    assert_eq zdraw "$ZCHAT_DRAW_COMMAND" 'preloaded zdraw uses its own builtin'
    assert_eq 0 "${#loaded_paths}" 'preloaded zdraw never loads stock curses'
    ZCHAT_DRAW=invalid
    zchat_draw_load "$test_root" 2>/dev/null
    assert_status_failed 'invalid curses policy fails explicitly' $?
  } always {
    unfunction zmodload
  }
}
