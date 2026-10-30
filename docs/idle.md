# Idle watcher — unattended evolution and introspection

When the user stops interacting with RubyCog's TUI, a background thread
detects the idle period and, after a configurable threshold, asks the agent
to run an evolution or introspection pass on its own. The two alternate so a
long idle window produces a mix of both rather than N of one kind.

## Components

| File | Role |
| --- | --- |
| `lib/rubycog/idle_watcher.rb` | Background thread + state machine. Host-agnostic, fully unit-testable. |
| TUI wiring in `lib/rubycog/tui.rb` | Starts the watcher on boot, resets the idle timer on every user input, drives the agent loop on fire. |

## Behaviour

- **Trigger.** 15 minutes without user input → fire one action.
- **Cooldown.** 60 minutes after a fire before another can happen.
- **Alternation.** First fire is `:evolve`, next is `:introspect`, then back
  to `:evolve`, and so on.
- **Reset on input.** Every keystroke that submits a message (the `submit`
  path) calls `notify_activity`, which resets both the idle timer and any
  active cooldown.
- **Skip when busy.** If a turn is already running (`@busy`) or an approval
  is pending, the watcher does not fire.

The watcher never calls tools directly. It invokes a single block with a
symbol (`:evolve` or `:introspect`) on its own thread; the TUI callback
spawns a worker thread that runs `converse(message)` exactly as if the user
had typed the prompt. This keeps the curses UI single-threaded.

## Yolo interaction

The action taken depends on the current `/yolo` state at fire time.

| /yolo | Effect |
| --- | --- |
| **on** | Full self-evolution / introspection loop, including `approve_proposal`, `run_evolution`, `evolution_edit`, `evolution_run_tests`, `evolution_benchmark`, `finish_evolution`. Still no auto-merge. |
| **off** | Proposal only. The injected prompt explicitly forbids approve/run/edit/test/merge. The watcher only produces new `propose_evolution` entries for the user to review on return. |

The prompt text in both cases is tagged `[idle-triggered …]` so the agent
knows (and the transcript records) that the message originated from the
watcher rather than the user.

## Commands

```
/idle            show status (idle for, threshold, cooldown, next action)
/idle on         enable the watcher (default state at boot)
/idle off        disable the watcher
/idle status     same as bare /idle
```

The status report looks like:

```
idle watcher: on
  idle for: 243s / threshold 900s
  time to next fire: 657s
  next action: evolve
  yolo: false (proposal only)
```

## Configuration

Defaults are constants on `IdleWatcher`:

```ruby
IdleWatcher::TICK            = 5            # how often the thread wakes up
IdleWatcher::IDLE_THRESHOLD  = 15 * 60      # 15 minutes
IdleWatcher::COOLDOWN        = 60 * 60      # 1 hour
```

To change them at runtime, construct the watcher yourself before starting
the TUI and pass `idle_threshold:`, `cooldown:`, `tick:`. The TUI currently
always uses the defaults; expose a CLI flag when there is demand.

## Failure modes

- **Watcher thread crash.** Rescued inside `loop_tick`; the watcher stops
  but the TUI keeps running. `/idle on` after a crash starts a fresh
  watcher.
- **on_fire raises.** Also rescued; the watcher survives and will fire
  again on the next idle window.
- **TUI exits during a fire.** `stop_idle_watcher` joins the watcher thread
  with a 2-second timeout, then the usual busy-turn cleanup runs.

## Testing

`test/idle_watcher_test.rb` covers the state machine with a fake clock so
no test depends on real time. One test (`test_background_thread_actually_fires`)
uses a real 0.1s threshold to confirm the thread loop works end-to-end; it
is the only test that sleeps.

## What this is not (yet)

- **No CLI / headless mode.** The watcher is wired into the TUI only. A
  `rubycog idle` daemon is future work if it becomes useful.
- **No automatic merge.** Even with `/yolo on`, the loop stops at
  `finish_evolution`. The user always reviews the branch and merges.
- **No persistent state.** Cooldown and last-activity are in-memory only;
  restarting the TUI resets them.
- **No adaptive threshold.** The 15-min/60-min constants are not learned
  from usage. If you want the watcher to be more aggressive at night or
  less during the day, change the constants or add scheduling.
