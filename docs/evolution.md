# Evolution — turning experiences into code changes

This is step 2 of the self-evolution roadmap. Step 1 (see
[experience.md](experience.md)) lets RubyCog read external sources and store
reusable patterns. Step 2 (this document) turns a stored experience into a
real, tested, isolated code change.

The hard rule: **all edits happen inside a git worktree**. The main checkout
is never touched by the evolution loop.

## Components

| File | Role |
| --- | --- |
| `lib/rubycog/proposal.rb` | YAML store + state machine for proposals |
| `lib/rubycog/worktree.rb` | `git worktree` wrapper (Open3, argv-only, 30s timeout) |
| `lib/rubycog/evolution.rb` | `Evolution::Context` — bundles store, worktree, project root |
| `lib/rubycog/tools/propose_evolution.rb` | Create a proposal |
| `lib/rubycog/tools/list_proposals.rb` | List proposals (optionally by status) |
| `lib/rubycog/tools/approve_proposal.rb` | Move `proposed → approved` |
| `lib/rubycog/tools/run_evolution.rb` | Move `approved → running`, create worktree |
| `lib/rubycog/tools/evolution_edit.rb` | `edit_source` against the worktree |
| `lib/rubycog/tools/evolution_run_tests.rb` | `run_tests` against the worktree |
| `lib/rubycog/tools/finish_evolution.rb` | Move `running → evaluated | failed` |
| `lib/rubycog/tools/rollback_evolution.rb` | Discard worktree, `evaluated | failed → rolled_back` |
| `lib/rubycog/tools/suggest_proposals.rb` | List experiences with no proposal yet (auto-target) |
| `lib/rubycog/benchmark_runner.rb` | Run `benchmarks/*.rb` in main + worktree, compare scores |
| `lib/rubycog/tools/evolution_benchmark.rb` | Compare benchmarks, persist result on the proposal |

## State machine

```
                 ┌──────────────┐
                 │  proposed    │
                 └──────┬───────┘
                        │ approve_proposal
                        ▼
                 ┌──────────────┐
       ┌────────▶│  approved    │────────┐
       │         └──────┬───────┘        │
       │                │ run_evolution  │ reject
       │                ▼                ▼
       │         ┌──────────────┐   ┌──────────┐
       │         │  running     │   │ rejected │
       │         └──────┬───────┘   └──────────┘
       │                │ finish_evolution
       │                │ success / failure
       │                ▼
       │         ┌──────────────┐
       │         │  evaluated   │◀──diff stats, branch info
       │         └──────┬───────┘
       │                │ user merges branch manually
       │                ▼
       │         ┌──────────────┐
       │         │   merged     │  (terminal)
       │         └──────────────┘
       │
   ┌───┴──────┐       rollback_evolution        ┌──────────────┐
   │  failed  │────────────────────────────────▶│ rolled_back  │  (terminal)
   └──────────┘                                 └──────────────┘
```

Invalid transitions raise `ArgumentError`. The model sees the error and can
adjust; the human approval gate on each mutation tool means no transition
happens without consent.

## End-to-end flow

1. **Propose.** Model calls `propose_evolution(title, motivation, touches,
   test_plan, budget)`. A YAML lands at `.rubycog/proposals/<id>.yaml` with
   `status: proposed`.
2. **Approve.** Human (via RubyLLM approval) approves `approve_proposal(id)`.
   State → `approved`.
3. **Run.** `run_evolution(id)` does:
   - `git worktree add .rubycog/worktrees/<id> -b evo/<id> HEAD`
   - State → `running`, records `worktree_path` and `branch`.
4. **Edit.** Model uses `evolution_edit(path, old_string, new_string)`. Same
   mechanics as `edit_source` (unique match, backup, `ruby -c`, atomic write)
   but paths resolve against the worktree. **Main checkout is read-only.**
5. **Test.** `evolution_run_tests` runs `bundle exec rake test` inside the
   worktree.
6. **Finish.** `finish_evolution(notes, success:)` either:
   - `success: true` → state `evaluated`, records diff stats
   - `success: false` → state `failed`, records error
7. **Decide.** User either:
   - `git merge evo/<id>` manually, then the proposal can be marked `merged`
   - `rollback_evolution(id)` → worktree + branch removed, state `rolled_back`

Only one proposal can be `running` at a time. `run_evolution` rejects a
second concurrent run.

## Schema

`.rubycog/proposals/<id>.yaml`:

```yaml
id: prop-add-retry-a1b2c3
title: Add retry to LLM calls
status: evaluated
motivation: Experience exp-… shows other agents retry on network errors.
experience_id: exp-20261030-…
expected_benefit: Survive transient network failures
risk: Retrying may double-charge on provider errors
touches: [lib/rubycog/agent.rb]
test_plan: test/agent_test.rb
budget: { max_files: 2, max_lines: 60 }
created_at: 2026-10-30T10:00:00Z
updated_at: 2026-10-30T10:05:00Z
result:
  worktree_path: /…/.rubycog/worktrees/prop-add-retry-a1b2c3
  branch: evo/prop-add-retry-a1b2c3
  started_at: …
  evaluation: …
  evaluated_at: …
```

`result` is merged across transitions — `worktree_path` set during `run_…`
survives into `evaluated`.

## Safety properties

- **Path whitelist still applies** inside the worktree. `SourcePath.resolve`
  runs against the worktree root, so `.git`, `.env`, `Gemfile.lock`,
  `source_path.rb`, `source_edit.rb`, `self_iteration.rb`,
  `tools/edit_source.rb` are all still protected.
- **Atomic write + backup + `ruby -c`** — same as `edit_source`.
- **30s timeout** on every git invocation.
- **Single running proposal** — the context refuses concurrent runs.
- **Human approval** on every mutation tool (`approve`, `run`, `edit`,
  `run_tests`, `finish`, `rollback`).
- **Worktree deletion is destructive but recoverable**: the proposal YAML
  keeps the result hash even after rollback, so audit survives.

## TUI

`/proposals` lists up to 20 proposals with their current status.

## What this is not (yet)

- **No automatic merge.** The human merges the branch.
- **No scheduler / cron.** The model only acts when the user (or `/evolve`)
  prompts it.
- **No cross-proposal conflict resolution.** Two approved proposals can edit
  the same file in separate worktrees; only one runs at a time but merges
  can still conflict.

## Step 3 — landed

### Budget enforcement

`Evolution::Context#check_budget!` is called from `evolution_edit` before
every write. It counts files and lines via `git diff --name-only HEAD` and
`git diff --numstat HEAD` against the worktree's HEAD, plus untracked files
(`ls-files --others`). The edit is rejected with `budget exceeded: …` if
either limit would be crossed. `max_files` or `max_lines` may be omitted to
skip that check.

### Auto-target generation

`suggest_proposals` lists experiences no proposal has referenced yet. The
model picks the most valuable and writes a `propose_evolution` with
`experience_id` set. Once an experience is referenced by any proposal (any
status), it disappears from the candidate list.

### Benchmark regression detection

`benchmarks/*.rb` scripts are numeric benchmarks: each script prints a number
(or `name<TAB>number`). `evolution_benchmark` runs the same set in both main
and the worktree, computes deltas, and flags regressions beyond a 5%
tolerance. Direction defaults to "higher is better"; drop a
`<name>.direction` file containing `lower` to flip.

`finish_evolution(success: true)` is blocked when a regression is on record.
Override with `force: true` (the result records `forced despite regression`)
or call `rollback_evolution` instead.

Scripts that exist in only one checkout are skipped and reported. Each script
has a 30s timeout. A script that exits non-zero or prints no parseable
number is reported as an error, not a regression.

### TUI `/evolve`

`/evolve` injects a pre-written user message that walks the model through one
full self-evolution loop (suggest → propose → approve → run → edit → test →
benchmark → finish). Every tool call still goes through the normal approval
gate; `/evolve` only saves the user from typing the prompt.
