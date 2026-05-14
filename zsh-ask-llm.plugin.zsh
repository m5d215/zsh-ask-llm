#!/usr/bin/env zsh
# zsh-ask-llm — ZLE widget that asks an LLM to complete the prompt at the cursor.
# Supports multiple backends (claude, ollama, mock); each can be bound to its own key.

zmodload zsh/system 2>/dev/null
zmodload zsh/zselect 2>/dev/null  # for sub-second timer in the spinner ticker

# === Shared configuration ===
typeset -g  ZAL_PLUGIN_DIR=${0:A:h}
typeset -g  ZAL_PROMPT_DIR=${ZAL_PROMPT_DIR:-$ZAL_PLUGIN_DIR/prompts}
typeset -g  ZAL_CANCEL_KEY=${ZAL_CANCEL_KEY:-^G}
typeset -g  ZAL_CURSOR_MARK=${ZAL_CURSOR_MARK:-§CURSOR§}
if (( ${#ZAL_SPINNER_FRAMES[@]} == 0 )); then
  typeset -ga ZAL_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
fi
# Centiseconds (1/100 sec) between spinner frames. 10 = 100ms.
typeset -gi ZAL_SPINNER_INTERVAL_CS=${ZAL_SPINNER_INTERVAL_CS:-10}

# === Per-backend configuration ===
# Claude — agentic, slower, stronger context. Can read prompts/*.md and run Bash.
typeset -g ZAL_CLAUDE_KEYBIND=${ZAL_CLAUDE_KEYBIND:-^X^T}
typeset -g ZAL_CLAUDE_MODEL=${ZAL_CLAUDE_MODEL:-haiku}
typeset -g ZAL_CLAUDE_SYSTEM_PROMPT_FILE=${ZAL_CLAUDE_SYSTEM_PROMPT_FILE:-$ZAL_PROMPT_DIR/system-claude.md}

# Ollama — fast local, pure text completion. Default for the primary key.
typeset -g ZAL_OLLAMA_KEYBIND=${ZAL_OLLAMA_KEYBIND:-^T}
typeset -g ZAL_OLLAMA_MODEL=${ZAL_OLLAMA_MODEL:-qwen3-coder:30b}
typeset -g ZAL_OLLAMA_URL=${ZAL_OLLAMA_URL:-http://localhost:11434}
typeset -g ZAL_OLLAMA_SYSTEM_PROMPT_FILE=${ZAL_OLLAMA_SYSTEM_PROMPT_FILE:-$ZAL_PROMPT_DIR/system-ollama.md}
typeset -gi ZAL_OLLAMA_NUM_PREDICT=${ZAL_OLLAMA_NUM_PREDICT:-100}
typeset -g ZAL_OLLAMA_TEMPERATURE=${ZAL_OLLAMA_TEMPERATURE:-0.2}

# Mock — debugging only. Unbound unless ZAL_MOCK_KEYBIND is set.
typeset -g  ZAL_MOCK_KEYBIND=${ZAL_MOCK_KEYBIND:-}
typeset -gi ZAL_MOCK_DELAY=${ZAL_MOCK_DELAY:-2}
typeset -g  ZAL_MOCK_RESULT=${ZAL_MOCK_RESULT:-mocked-completion}

# === Internal state ===
typeset -g  _ZAL_SAVED_BUFFER=
typeset -gi _ZAL_SAVED_CURSOR=0
typeset -g  _ZAL_SAVED_POSTDISPLAY=
typeset -g  _ZAL_PREV_KEYMAP=
typeset -g  _ZAL_RESPONSE=
typeset -g  _ZAL_CURRENT_BACKEND=
typeset -gi _ZAL_FD=0
typeset -gi _ZAL_PID=0
typeset -gi _ZAL_TICK_FD=0
typeset -gi _ZAL_SPINNER_IDX=0

# === Locked keymap (one-shot at load time) ===
_zal_install_keymap() {
  bindkey -N zal-locked
  bindkey -M zal-locked -R '^@-^?' _zal_noop
  bindkey -M zal-locked "$ZAL_CANCEL_KEY" _zal_cancel
}

# Widget bound to all keys in the locked keymap.
# - While a request is in flight: swallow the keystroke, show a hint message.
# - After the request has finalized (but the keymap is still locked because
#   ZLE pre-queued this read with the old keymap): restore the keymap and
#   re-feed the keystroke so the user's intended key still takes effect.
_zal_noop() {
  if (( _ZAL_FD == 0 )); then
    _zal_unlock_and_replay
    return
  fi
  zle -M "${_ZAL_CURRENT_BACKEND} に問い合わせ中... ${ZAL_CANCEL_KEY} でキャンセル"
}

# Restore the saved keymap and replay the triggering keystroke into the
# input stack so ZLE re-dispatches it under the restored keymap.
_zal_unlock_and_replay() {
  if [[ -n $_ZAL_PREV_KEYMAP ]]; then
    zle -K "$_ZAL_PREV_KEYMAP"
    _ZAL_PREV_KEYMAP=
  fi
  zle -U -- "$KEYS"
}

# === Animated spinner ===
# Renders the current frame at the saved cursor. Defined as a widget so it can
# be invoked from a `zle -F` callback context via `zle _zal_render_spinner`.
_zal_render_spinner() {
  local n=${#ZAL_SPINNER_FRAMES[@]}
  (( n == 0 )) && return
  local frame=${ZAL_SPINNER_FRAMES[$(( _ZAL_SPINNER_IDX % n + 1 ))]}
  local pre=${_ZAL_SAVED_BUFFER:0:$_ZAL_SAVED_CURSOR}
  local post=${_ZAL_SAVED_BUFFER:$_ZAL_SAVED_CURSOR}
  BUFFER="${pre}${frame}${post}"
  CURSOR=$_ZAL_SAVED_CURSOR
  zle -R
  (( _ZAL_SPINNER_IDX++ ))
}

# Spawn a background ticker that writes one byte per interval. Each byte
# triggers `_zal_on_tick`, which advances the spinner frame.
# Uses zsh's `zselect -t` (centiseconds) instead of external `sleep` because
# recent macOS BSD `sleep` rejects fractional seconds.
_zal_start_spinner() {
  _ZAL_SPINNER_IDX=0
  _zal_render_spinner  # paint first frame immediately, before the first tick
  exec {_ZAL_TICK_FD}< <(
    # `zselect -t` returns non-zero on timeout (normal); ignore. The loop
    # exits naturally when the reader closes its end and `print` gets SIGPIPE.
    while :; do
      print -n -- .
      zselect -t ${ZAL_SPINNER_INTERVAL_CS:-10} 2>/dev/null
    done
  )
  zle -F $_ZAL_TICK_FD _zal_on_tick
}

_zal_on_tick() {
  emulate -L zsh
  local -i fd=$1
  local reason=$2
  local junk
  if [[ -n $reason ]]; then
    # Ticker died (unexpected); just clean up.
    zle -F $fd 2>/dev/null
    # Wrap close in `{ ... } 2>/dev/null` so the redirect is scoped to the
    # group; a bare `exec {fd}<&- 2>/dev/null` would silently set the
    # shell's stderr to /dev/null permanently.
    { exec {fd}<&- } 2>/dev/null
    _ZAL_TICK_FD=0
    return
  fi
  sysread -i $fd junk 2>/dev/null
  zle _zal_render_spinner
}

_zal_stop_spinner() {
  if (( _ZAL_TICK_FD != 0 )); then
    zle -F $_ZAL_TICK_FD 2>/dev/null
    # Closing the read fd makes the ticker subshell get SIGPIPE on its next
    # write (within ZAL_SPINNER_INTERVAL seconds) and exit.
    # Brace group scopes the 2>/dev/null to the close; a bare
    # `exec {fd}<&- 2>/dev/null` would permanently silence the shell's stderr.
    { exec {_ZAL_TICK_FD}<&- } 2>/dev/null
    _ZAL_TICK_FD=0
  fi
}

# === Backends ===
# Each `_zal_run_<name>` writes the raw backend response to stdout.
# Each `_zal_parse_<name>` reads raw response on stdin, writes the completion text.

_zal_run_claude() {
  local user_prompt=$1
  local -a args=(-p --model "$ZAL_CLAUDE_MODEL" --output-format json)
  [[ -r $ZAL_CLAUDE_SYSTEM_PROMPT_FILE ]] && args+=(--append-system-prompt "$(<$ZAL_CLAUDE_SYSTEM_PROMPT_FILE)")
  [[ -d $ZAL_PROMPT_DIR ]] && args+=(--add-dir "$ZAL_PROMPT_DIR")
  print -rn -- "$user_prompt" | claude "${args[@]}" 2>/dev/null
}
_zal_parse_claude() { jq -r '.result // empty' 2>/dev/null }

_zal_run_ollama() {
  local user_prompt=$1
  local system_prompt=
  [[ -r $ZAL_OLLAMA_SYSTEM_PROMPT_FILE ]] && system_prompt=$(<$ZAL_OLLAMA_SYSTEM_PROMPT_FILE)
  jq -n \
    --arg     model       "$ZAL_OLLAMA_MODEL" \
    --arg     system      "$system_prompt" \
    --arg     prompt      "$user_prompt" \
    --argjson num_predict "$ZAL_OLLAMA_NUM_PREDICT" \
    --argjson temperature "$ZAL_OLLAMA_TEMPERATURE" \
    '{model: $model, stream: false, system: $system, prompt: $prompt,
      options: {num_predict: $num_predict, temperature: $temperature}}' \
    | curl -sS --no-buffer "$ZAL_OLLAMA_URL/api/generate" -d @- 2>/dev/null
}
_zal_parse_ollama() { jq -r '.response // empty' 2>/dev/null }

_zal_run_mock() {
  # Use zselect (centiseconds) instead of sleep so we don't depend on the
  # external `sleep` accepting non-integer or empty input.
  zselect -t $(( ${ZAL_MOCK_DELAY:-2} * 100 )) 2>/dev/null
  printf '{"result":"%s"}' "$ZAL_MOCK_RESULT"
}
_zal_parse_mock() { jq -r '.result // empty' 2>/dev/null }

# === Per-backend widgets (bind these to keys) ===
_zal_request_claude() { _zal_run_request claude }
_zal_request_ollama() { _zal_run_request ollama }
_zal_request_mock()   { _zal_run_request mock   }

# === Shared request flow ===
_zal_run_request() {
  local backend=$1
  # Reentrancy guard: a request is in flight if the fd is still open.
  (( _ZAL_FD != 0 )) && return

  _ZAL_CURRENT_BACKEND=$backend
  _ZAL_SAVED_BUFFER=$BUFFER
  _ZAL_SAVED_CURSOR=$CURSOR
  # Clear any inline overlay from zsh-autosuggestions (or similar) so the
  # spinner doesn't render on top of it. Saved for restoration on cancel.
  _ZAL_SAVED_POSTDISPLAY=${POSTDISPLAY-}
  POSTDISPLAY=
  _ZAL_RESPONSE=

  # Save the keymap to restore later. Resolve "main" to its underlying keymap
  # because "main" is an alias and can be re-aliased — `zle -K main` would
  # then route back to the wrong place. Parse `bindkey -lL main`, which prints
  # something like `bindkey -A emacs main`.
  _ZAL_PREV_KEYMAP=$KEYMAP
  if [[ $_ZAL_PREV_KEYMAP == main ]]; then
    local alias_line=$(bindkey -lL main 2>/dev/null)
    if [[ $alias_line == 'bindkey -A '*' main' ]]; then
      _ZAL_PREV_KEYMAP=${${alias_line#bindkey -A }% main}
    fi
  fi

  # Compose the user-facing prompt: full buffer with the cursor position marked.
  local pre=${BUFFER:0:$CURSOR}
  local post=${BUFFER:$CURSOR}
  local user_prompt=$'Buffer (cursor at '"${ZAL_CURSOR_MARK}"$'):\n'"${pre}${ZAL_CURSOR_MARK}${post}"

  # Process substitution: not job-controlled (no `[1] PID` notification),
  # and EOFs cleanly when the spawned process exits.
  exec {_ZAL_FD}< <(_zal_run_$backend "$user_prompt")
  _ZAL_PID=$!  # may be empty for process substitution; cancel will degrade gracefully
  zle -F $_ZAL_FD _zal_on_data

  # Lock input by switching the active keymap, and start the animated spinner.
  zle -K zal-locked
  _zal_start_spinner
}

# fd handler: drains output, finalizes on EOF/error.
_zal_on_data() {
  emulate -L zsh
  local -i fd=$1
  local reason=$2
  local chunk

  # Single non-blocking-ish read; ZLE will re-invoke us if more data arrives.
  if sysread -i $fd chunk 2>/dev/null; then
    _ZAL_RESPONSE+=$chunk
  fi

  # `zle -F` passes a non-empty $reason on hup/err/nval.
  # Also treat empty read as EOF.
  if [[ -n $reason ]] || [[ -z $chunk ]]; then
    _zal_finalize
  fi
}

_zal_finalize() {
  _zal_stop_spinner
  _zal_close_fd

  local insertion
  if (( $+commands[jq] )); then
    insertion=$(print -r -- "$_ZAL_RESPONSE" | _zal_parse_$_ZAL_CURRENT_BACKEND)
  else
    insertion=$_ZAL_RESPONSE
  fi
  # Strip a trailing newline if the model added one.
  insertion=${insertion%$'\n'}

  # BUFFER mutation must happen inside a real ZLE widget context.
  zle _zal_apply_insertion_widget -- "$insertion"
  # Note: keymap restore happens lazily on the next keypress via _zal_noop.
  # `zle -K` from this callback would only take effect after one wasted
  # keystroke because ZLE has already pre-queued the next read.
  _ZAL_PID=0
  zle -M ''
}

# Real ZLE widget — modifies BUFFER. Keymap restore happens lazily.
_zal_apply_insertion_widget() {
  local insertion=$1
  local pre=${_ZAL_SAVED_BUFFER:0:$_ZAL_SAVED_CURSOR}
  local post=${_ZAL_SAVED_BUFFER:$_ZAL_SAVED_CURSOR}
  BUFFER="${pre}${insertion}${post}"
  CURSOR=$(( _ZAL_SAVED_CURSOR + ${#insertion} ))
  # Clear the saved overlay; if zsh-autosuggestions is loaded, re-fetch a
  # suggestion based on the new BUFFER.
  POSTDISPLAY=
  _ZAL_SAVED_POSTDISPLAY=
  if (( $+functions[_zsh_autosuggest_fetch] )); then
    _zsh_autosuggest_fetch 2>/dev/null
  fi
}

_zal_cancel() {
  # If no request is in flight, this ^G arrived after finalize while the
  # keymap is still in the locked state. Just unlock and replay.
  if (( _ZAL_FD == 0 )); then
    _zal_unlock_and_replay
    return
  fi
  # Best-effort kill. Process substitution may not have set $!, in which case
  # closing the fd will give the writer SIGPIPE on its next write attempt.
  if (( _ZAL_PID != 0 )); then
    kill -TERM -- -$_ZAL_PID 2>/dev/null || kill -TERM -- $_ZAL_PID 2>/dev/null
  fi
  _zal_stop_spinner
  _zal_close_fd
  BUFFER=$_ZAL_SAVED_BUFFER
  CURSOR=$_ZAL_SAVED_CURSOR
  # Restore the inline overlay we cleared at request time.
  POSTDISPLAY=$_ZAL_SAVED_POSTDISPLAY
  _ZAL_SAVED_POSTDISPLAY=
  if [[ -n $_ZAL_PREV_KEYMAP ]]; then
    zle -K "$_ZAL_PREV_KEYMAP"
    _ZAL_PREV_KEYMAP=
  fi
  _ZAL_PID=0
  zle -M 'キャンセルした'
}

_zal_close_fd() {
  if (( _ZAL_FD != 0 )); then
    zle -F $_ZAL_FD 2>/dev/null
    # Brace group scopes the 2>/dev/null to the close; a bare
    # `exec {fd}<&- 2>/dev/null` would permanently silence the shell's stderr.
    { exec {_ZAL_FD}<&- } 2>/dev/null
    _ZAL_FD=0
  fi
}

# === Register widgets and bindings ===
_zal_install_keymap

zle -N _zal_request_claude
zle -N _zal_request_ollama
zle -N _zal_request_mock
zle -N _zal_cancel
zle -N _zal_noop
zle -N _zal_apply_insertion_widget
zle -N _zal_render_spinner

_zal_install_bindings() {
  [[ -n $ZAL_OLLAMA_KEYBIND ]] && bindkey "$ZAL_OLLAMA_KEYBIND" _zal_request_ollama
  [[ -n $ZAL_CLAUDE_KEYBIND ]] && bindkey "$ZAL_CLAUDE_KEYBIND" _zal_request_claude
  [[ -n $ZAL_MOCK_KEYBIND ]]   && bindkey "$ZAL_MOCK_KEYBIND"   _zal_request_mock
  return 0
}
_zal_install_bindings
