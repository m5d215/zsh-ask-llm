# zsh-ask-llm

A ZLE widget that asks an LLM to complete the shell command at the cursor.

```text
git commit -m '<C-t>'                      git commit -m 'fix: handle empty input case'
                  ^^^                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
              press a key                        result inserted at the cursor
```

Multiple backends are available, each bound to its own key:

| Backend | Default key | Use case |
|---|---|---|
| Ollama  | `^T`        | Fast inline completion (sub-second on warm cache) |
| Claude  | `^X^T`      | Slower but understands context, can read docs and run `git status`, etc. |
| Mock    | unbound     | Debugging the ZLE flow without hitting an LLM |

## Requirements

- zsh 5.9+
- `jq` (always required for response parsing)
- `curl` (for the Ollama backend)
- `ollama` running locally (for the Ollama backend)
- `claude` CLI (for the Claude backend)

## Install

```zsh
# Source from .zshrc
source /path/to/zsh-ask-llm/zsh-ask-llm.plugin.zsh
```

That's it — `^T` and `^X^T` are bound automatically (provided their respective
CLIs are available).

## Usage

Place the cursor inside a command and press the key for your chosen backend.
An animated spinner appears at the cursor while the backend is thinking;
the keymap is locked during the wait.

- **`^G`** cancels the in-flight request and restores the buffer.
- After the response arrives, the spinner is replaced with the suggested text
  and your normal keymap is restored on the next keystroke.

### Examples

```text
git commit -m '<C-t>'           →   git commit -m 'fix: handle empty input case'
docker run --rm -it <C-t>       →   docker run --rm -it ubuntu:latest bash
ls -la<C-t>                     →   ls -la ~/
```

## Configuration

Override any of these before sourcing the plugin (e.g. in `.zshrc`).

### Shared

| Variable | Default | Meaning |
|---|---|---|
| `ZAL_PROMPT_DIR` | `<plugin-dir>/prompts` | Directory holding system prompts |
| `ZAL_CANCEL_KEY` | `^G` | Key that cancels an in-flight request |
| `ZAL_CURSOR_MARK` | `§CURSOR§` | Marker passed to the LLM to indicate cursor position |
| `ZAL_SPINNER_FRAMES` | braille spinner (10 frames) | Animation frames cycled through during the wait |
| `ZAL_SPINNER_INTERVAL_CS` | `10` | Centiseconds (1/100 sec) between frame changes |

### Claude backend

| Variable | Default | Meaning |
|---|---|---|
| `ZAL_CLAUDE_KEYBIND` | `^X^T` | Key to trigger the Claude backend (empty = unbound) |
| `ZAL_CLAUDE_MODEL` | `haiku` | Model alias passed to `claude --model` |
| `ZAL_CLAUDE_SYSTEM_PROMPT_FILE` | `prompts/system-claude.md` | System prompt file |

### Ollama backend

| Variable | Default | Meaning |
|---|---|---|
| `ZAL_OLLAMA_KEYBIND` | `^T` | Key to trigger the Ollama backend (empty = unbound) |
| `ZAL_OLLAMA_MODEL` | `qwen3-coder:30b` | Model name in your local Ollama |
| `ZAL_OLLAMA_URL` | `http://localhost:11434` | Ollama server URL |
| `ZAL_OLLAMA_SYSTEM_PROMPT_FILE` | `prompts/system-ollama.md` | System prompt file |
| `ZAL_OLLAMA_NUM_PREDICT` | `100` | Max tokens to generate |
| `ZAL_OLLAMA_TEMPERATURE` | `0.2` | Sampling temperature |

### Mock backend

| Variable | Default | Meaning |
|---|---|---|
| `ZAL_MOCK_KEYBIND` | (unbound) | Set to bind a debug key, e.g. `^X^M` |
| `ZAL_MOCK_DELAY` | `2` | Seconds to sleep before "responding" |
| `ZAL_MOCK_RESULT` | `mocked-completion` | Canned text to insert |

## Customising prompts

The system prompts live under `prompts/` and are loaded fresh on every
invocation, so you can edit them without re-sourcing.

- `prompts/system-claude.md` — agentic instructions for the Claude backend.
  Includes a routing table that points at domain docs.
- `prompts/system-ollama.md` — pure text-completion instructions for Ollama.
- `prompts/git.md` — example domain doc consulted by Claude when the buffer
  starts with `git` or `gh`. Add your own (`prompts/docker.md`, etc.) and
  reference them in the routing table inside `system-claude.md`.

The Ollama backend does not use domain docs — small local models don't tool-use
reliably. Keep its system prompt focused on raw text completion.

## Adding a backend

A backend is just two functions plus a wrapper widget:

```zsh
# 1. Run: write the raw response to stdout.
_zal_run_openai() {
  local user_prompt=$1
  jq -n \
    --arg model "gpt-4o-mini" \
    --arg system "$(<$ZAL_PROMPT_DIR/system-openai.md)" \
    --arg prompt "$user_prompt" \
    '{model: $model, messages: [{role:"system", content:$system}, {role:"user", content:$prompt}]}' \
    | curl -sS https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d @-
}

# 2. Parse: read raw response on stdin, write the completion text to stdout.
_zal_parse_openai() { jq -r '.choices[0].message.content // empty' }

# 3. Wrapper widget that routes to the shared flow.
_zal_request_openai() { _zal_run_request openai }
zle -N _zal_request_openai
bindkey '^X^O' _zal_request_openai
```

## Troubleshooting

### Sourcing returns exit code 1

Should not happen — if it does, please report it. The plugin's last operation
is gated to always succeed.

### After completion, the keymap stays locked

This usually means the `main` keymap was aliased to `zal-locked` (or
`zac-locked` from an older dev version) and never restored. Reset:

```zsh
bindkey -A emacs main   # or `viins` if you're in vi mode
```

The current plugin avoids touching the `main` alias — it switches the active
keymap via `zle -K`. So this should only ever be a one-time recovery.

### `^G` while waiting doesn't cancel

Try `^C`. If even that fails, the only recovery is to close the terminal. This
hasn't been observed since switching from `coproc` / `mkfifo + &!` to process
substitution, but mention it in an issue if you see it.

### Ollama call is slow

The first request after starting Ollama (or after the model is evicted from
RAM) loads the model — that can take 10–30s for a 30B model. Subsequent
requests with the same system prompt are cached and return in 200–500ms.

## Implementation notes

A few things were non-obvious enough that they're worth recording here:

- **`coproc` triggers job-control notifications** (`[1] PID`) that pollute the
  prompt during a ZLE widget. We use process substitution `<(...)` instead;
  it's not tracked by job control.
- **`zle -F` callbacks cannot directly modify `BUFFER` in a way that ZLE will
  redraw.** They must dispatch to a real widget via `zle widget-name`. The
  callback context can read state but not mutate it visibly.
- **`zle -K` from a callback (or from a callback-dispatched widget) takes
  effect on the *next-but-one* keystroke**, because ZLE has already pre-queued
  its next read with the old keymap. We work around this by leaving the keymap
  locked at finalize time and having the locked keymap's noop widget detect
  the post-finalize state, then `zle -K` to restore + `zle -U "$KEYS"` to
  replay the user's keystroke under the restored keymap.
- **`KEYMAP=main` resolves through an alias** that other code (or older
  versions of this plugin) might have re-aliased. We resolve `main` to its
  underlying keymap by parsing `bindkey -lL main` before saving it as the
  restore target.
