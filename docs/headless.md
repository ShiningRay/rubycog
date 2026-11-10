# Headless mode — running without curses

A watchdog or CI job often has no terminal to give curses. `--headless` runs the
same agent, tools and session file as the TUI, but writes a plain-text event
stream to stdout and reads tasks from a prompt or a directory. Curses is never
required or loaded by this path.

## Files

| File | Role |
| --- | --- |
| `lib/rubycog/headless.rb` | Event rendering, one-shot tasks, inbox polling, heartbeat, signals. |
| `lib/rubycog/cli.rb` | Parses `--headless`/`--task`/`--daemon`/`--inbox`/`--heartbeat`/`--interval` and picks the runtime. |
| `bin/rubycog` | Exits with the CLI status so a supervisor sees pass/fail. |
| `test/headless_test.rb` | One-shot stream, tool approval, inbox processing, failure isolation, heartbeat. |

`lib/rubycog/tui.rb` is unchanged and still loaded eagerly; the curses TUI keeps
working exactly as before.

## Usage

```sh
# Answer one prompt, then exit.
bin/rubycog --task 'Use Ruby to calculate 21 * 2'

# Keep polling an inbox.
bin/rubycog --headless --daemon

# Same with explicit paths (the defaults are shown).
bin/rubycog --headless --daemon \
  --inbox .rubycog/headless/inbox \
  --heartbeat .rubycog/headless/heartbeat.json \
  --interval 5
```

| Flag | Meaning |
| --- | --- |
| `--headless` | Select the non-curses runtime. Needs `--task` or `--daemon`. |
| `--task TEXT` | Answer one prompt and exit. Implies headless. |
| `--daemon` | Poll the inbox until SIGINT/SIGTERM. Implies headless. |
| `--inbox DIR` | Task inbox, default `.rubycog/headless/inbox`. |
| `--heartbeat PATH` | Heartbeat JSON, default `.rubycog/headless/heartbeat.json`. |
| `--interval SECONDS` | Seconds between polls, default `5`; must be positive. |

`--task` without `--daemon` is a one-shot run. `--daemon` without `--task`
starts the loop. If both are given, the prompt is answered first and the daemon
then keeps polling. The other flags (`--model`, `--session`, `--name`,
`--isolated-eval`) apply to both runtimes.

## Output stream

stdout is line oriented so a log collector can parse it:

- `[startup] ...` — one line on stderr with pid, model and Ruby version.
- `[task] <prompt>` — a task begins (one-shot or inbox file).
- `[status] thinking|running eval|ready|...` — status changes from the agent.
- `[tool] <name>` followed by the indented tool preview.
- `[approval] auto-approved <name>: <preview>` — one line per approval.
- `[result]` followed by indented tool output (trimmed at 4000 characters).
- `[error] ...` — agent or task error.
- `[done] ok` / `[done] failed` — the task finished.
- `[inbox] <file> -> done|failed` — an inbox file was filed.
- `[interrupted]` / `[daemon] stopped` — shutdown.

Model text is streamed to stdout without reformatting, so the reply appears as
the model produces it.

## Approvals

Headless has nobody to answer a prompt, so every tool call is approved
automatically and logged as `[approval] auto-approved ...`. This is equivalent
to `--yolo`: the model can run arbitrary Ruby and edit project files. Only run
it in a directory you trust, and read the approval lines afterwards.

Approval blocking comes from the chat (`awaiting_approval?`), exactly like the
TUI loop: after `ask` returns, each pending call is approved and `complete` is
called again until no round is pending.

## Inbox protocol

`--daemon` creates `inbox/`, `inbox/done/` and `inbox/failed/` on startup, then
on every tick:

1. Globs `inbox/*.txt` and sorts by file name.
2. Reads the file, strips it, and uses the content as the prompt.
3. Moves the file to `inbox/done/` when the task succeeded and to
   `inbox/failed/` when it failed.
4. Writes the heartbeat again, so `tasks_done` advances during a long tick.

An empty file counts as a bad task and moves to `failed/`. A name already
present in the target directory gets a `-1`, `-2`, ... suffix instead of being
overwritten. Files are only picked up from the top level; subdirectories are
ignored.

A task that raises does not stop the daemon: the error is logged, the file is
moved to `failed/`, and the remaining files keep processing. Errors outside
task handling (an inbox path that cannot be created or read) are fatal: a
backtrace goes to stderr and the process exits 1. A heartbeat write that fails
is only logged, so the daemon keeps answering tasks.

## Heartbeat

Written atomically at the start of every tick and after every processed file:

```json
{
  "pid": 12345,
  "started_at": "2026-11-10T15:13:25Z",
  "last_tick": "2026-11-10T15:13:30Z",
  "tasks_done": 3
}
```

`started_at` is the process start time, `last_tick` the latest tick, and
`tasks_done` counts successful tasks only. A supervisor can treat an old
`last_tick` as a hung process, and a changed pid as a restart.

## Exit codes and signals

- `0` — one-shot task finished without an agent error, or the daemon stopped
  after SIGINT/SIGTERM.
- `1` — the one-shot task reported an error, `--headless` had neither `--task`
  nor `--daemon`, an invalid `--interval`, or a fatal error occurred (the
  backtrace is printed).
- SIGINT and SIGTERM set a stop flag; the task in flight finishes, then the
  daemon exits cleanly. A one-shot run exits 0 as well.

## Session

Session restore and saving go through `Rubycog::Session` inside the Agent, so
`-s/--session` (or `RUBYCOG_SESSION`) names the same file the TUI uses. A
headless run resumes the stored turns and saves each step the same way. Tool
calls are not replayed, matching TUI behaviour.

## Supervisor example

```sh
#!/bin/sh
mkdir -p .rubycog/headless/inbox
exec bin/rubycog --headless --daemon --interval 5
```

```ruby
# Watchdog sketch: restart when the heartbeat goes stale.
require 'json'
require 'time'

beat = JSON.parse(File.read('.rubycog/headless/heartbeat.json'))
stale = Time.now - Time.iso8601(beat['last_tick']) > 60
restart if stale
```

## Limitations

- No TUI commands (`/yolo`, `/restart`, `/clear`, ...). Use the CLI flags.
- No interactive approval; everything is auto-approved.
- One task at a time; extra inbox files wait for the next tick.
- stdout is not colorised, and tool results are trimmed for readability.
