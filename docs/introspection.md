# Introspection — refactoring and performance work

Step 4 of the self-evolution roadmap adds *self-introspection*: the agent
scans its own source for code smells, structural problems, and performance
opportunities, then writes refactor or performance proposals through the
same evolution workflow described in [evolution.md](evolution.md).

## Components

| File | Role |
| --- | --- |
| `lib/rubycog/static_analysis.rb` | `bundle exec rubocop` + `bundle exec reek` wrappers, JSON parsing |
| `lib/rubycog/heuristic_scan.rb` | Pure-Ruby structural smells (backup files, long methods/files, dup blocks, too many params, commented code) |
| `lib/rubycog/introspection.rb` | Combines both into a markdown report under `.rubycog/introspection/<stamp>.md` |
| `lib/rubycog/tools/introspect_code.rb` | Model-facing tool that drives one scan and returns the summary |
| `benchmarks/alloc_baseline.rb` | Boot-time allocation count (lower is better) |
| `benchmarks/memsize_all.rb` | Retained heap bytes after GC (lower is better) |
| `benchmarks/boot_time.rb` | Wall-clock require time (lower is better) |

## Categories

Proposals now carry a `category` field. Three values:

- **feature** (default) — new functionality. Benchmark regression requires
  `force: true` on `finish_evolution(success: true)`.
- **refactor** — smell removal, dead-code deletion, structural cleanup.
  Benchmark regression is *allowed* and recorded. No force required.
- **performance** — speed or memory work. Benchmark regression *blocks*
  success outright (no force override), and `evolution_benchmark` MUST be
  run before `finish_evolution` will accept success.

The category is rendered as a suffix on `to_line`, e.g.
`[proposed/refactor] prop-add-retry-a1b2c3 — Add retry`. Legacy proposals
without a `category` field default to `feature` when read back.

## Workflow

1. **Scan.** Model calls `introspect_code`. This runs:
   - `bundle exec rubocop --format json lib/`
   - `bundle exec reek --format json lib/`
   - the heuristic scanner (no external tools)
2. **Report.** A markdown report lands at `.rubycog/introspection/<stamp>.md`
   with every finding grouped by file. The model sees a compact summary:
   counts per tool, counts per heuristic rule, top 10 offenders.
3. **Read.** Model uses `read_source` on the worst files to understand each
   smell in context.
4. **Propose.** Model writes 1-2 `propose_evolution` entries:
   - smell removal → `category: 'refactor'`
   - speed/memory → `category: 'performance'`
5. **Drive the loop.** `approve → run → edit → test → benchmark → finish`
   exactly as in step 2/3. Category-specific rules apply at finish.

The TUI command `/introspect` injects a pre-written user message that walks
the model through steps 1-4 only (it does not auto-approve or run).

## Heuristic rules

Cheap, parser-free checks that catch smells rubocop doesn't:

| Rule | Trigger |
| --- | --- |
| `BackupFile` | `lib/**/*.bak` exists |
| `LongFile` | file exceeds 250 lines |
| `LongMethod` | method body exceeds 25 lines (approximate `def … end` matching) |
| `TooManyParams` | more than 5 positional parameters |
| `CommentedCode` | comment lines that look like commented-out code |
| `DuplicateBlock` | 6-line block appearing in 3+ files |

These are deliberately approximate. False negatives are fine; false
positives would waste reviewer time.

## Benchmarks

Three scripts ship under `benchmarks/` to give the regression detector
something to compare:

- `alloc_baseline.rb` — `GC.stat(:total_allocated_objects)` delta across
  `require 'rubycog'`. Lower is better. Catches "we now allocate more at
  boot".
- `memsize_all.rb` — `ObjectSpace.memsize_of_all` after require + two GC
  runs. Lower is better. Catches retained-heap growth.
- `boot_time.rb` — `Benchmark.realtime { require 'rubycog' }`. Lower is
  better. Catches boot slowdowns.

Each has a `.direction` sidecar of `lower` so the benchmark runner treats
increases as regressions.

Performance proposals that fail to improve (or at least not regress) these
numbers will be rejected by `finish_evolution`. Adding more benchmarks is
as simple as dropping a new `.rb` file plus a `.direction` sidecar.

## TUI

`/introspect` — injects a prompt that drives one scan + proposal-writing
pass. Does not auto-approve or auto-run.

`/proposals` — lists proposals with their category tag, so refactor and
performance work is visually distinct from feature work.

## Safety notes

- rubocop and reek are wrapped in 60s timeouts each. If either is missing
  or crashes, the report records an error but the heuristic scan still
  runs, so the model always has *some* signal.
- The heuristic scanner reads `lib/**/*.rb` directly with no execution —
  it never `require`s project code.
- The benchmark scripts DO require project code; they run inside the
  worktree during evaluation, not in the main checkout.
- Introspection reports live under `.rubycog/introspection/`, which is
  git-ignored like the rest of `.rubycog/`.

## What this is not (yet)

- **No automatic refactoring.** The model still has to write a proposal,
  get it approved, and drive the edit loop. Introspection only produces
  the *input* for that loop.
- **No rubocop auto-correct.** Running `rubocop -A` would touch many files
  at once and bypass per-edit approval. If we add it later, it must go
  through a proposal like any other change.
- **No historical trend analysis.** Reports are timestamped but we don't
  yet diff "smells this week vs last week". The report files exist; a
  diff tool is future work.
- **No flamegraph / sampling profiler.** The benchmarks are coarse. For
  real performance work the model should add a targeted benchmark script
  first, then optimize against it.
