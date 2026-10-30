# Experience store — learning from external sources

RubyCog can fetch an external URL (a blog post, a GitHub README, a paper, a
competitor agent's source) and distill it into a reusable *experience*. The
next time RubyCog is about to change itself, it searches those experiences
first so it can apply patterns other agents already proved out.

This is the first step of the self-evolution roadmap. It does **not** modify
code on its own — it only accumulates a searchable pattern library.

## Components

| File | Role |
| --- | --- |
| `lib/rubycog/experience.rb` | YAML-backed store, search, render |
| `lib/rubycog/web_fetcher.rb` | Stdlib HTTP fetch + crude HTML→text |
| `lib/rubycog/tools/learn_from_url.rb` | Tool: fetch URL → return text |
| `lib/rubycog/tools/save_experience.rb` | Tool: persist a distilled pattern |
| `lib/rubycog/tools/search_experiences.rb` | Tool: AND-search past patterns |

Experiences live under `.rubycog/experiences/<id>.yaml` next to the project
root. The directory is intentionally plain files so users can edit, delete
or version them by hand.

## Schema

```yaml
id: exp-20261030-a1b2c3d4
source: https://github.com/anthropics/skills
learned_at: 2026-10-30T09:00:00Z
tags: [agent, skills]
summary: Anthropic packages capabilities as SKILL.md bundles loaded on demand.
applicable_to: [tool_design, instructions]
patterns:
  - name: skill_bundle
    idea: Each skill is a directory with a SKILL.md and helper scripts.
    rubycog_fit: Map to tools/<name>/ with a SKILL.md the agent reads before use.
confidence: medium
notes: optional free-form
```

Required: `source`, `summary`. Duplicate source URLs are rejected — edit the
existing file instead of saving twice.

## Flow

1. User: "learn from https://example.com/other-agent"
2. Model calls `learn_from_url(url)` → tool fetches, strips HTML, returns text
3. Model reads the text, extracts reusable ideas
4. Model calls `save_experience(source:, summary:, tags:, patterns:)`
5. Later, before any self-edit, model calls `search_experiences(query)` and
   applies relevant patterns

Step 5 is wired into `Agent::INSTRUCTIONS` rule 7.

## Search semantics

- Space-separated words are ANDed, case-insensitive.
- Haystack includes `summary`, `source`, `tags`, `applicable_to`, `notes`,
  and every `patterns[].{name,idea,rubycog_fit}`.
- Empty query returns everything (newest first).
- Result is one-line per hit by default; pass `full: true` for the full text.

## Limits

- Fetch: 3 redirects, 5s open / 10s read timeout, 200 KB body cap.
- HTML→text strips `<script>`, `<style>`, comments, all tags; collapses
  whitespace. Not beautiful — but the consumer is an LLM.
- Summary ≤ 1000 chars, each pattern idea/fit ≤ 500 chars.
- Only `http`/`https`. No `file:`, no auth, no cookies.

## TUI

`/experiences` lists up to 20 stored experiences (newest first) with tags and
truncated summary.

## What this is not

- **Not auto-improvement.** The model still has to decide which experiences
  are relevant and how to apply them. There is no scheduler.
- **Not a vector DB.** Plain substring AND-search. When the library grows
  past a few hundred entries we can add an index, but YAML + grep is enough
  at this scale.
- **Not a replacement for `search_docs`.** `search_docs` indexes the code
  RubyCog has; `search_experiences` indexes ideas it has read about.

## Roadmap

- Step 2 (not implemented): proposal objects + approval flow + worktree
  executor + evaluator, so a saved experience can become a real code change.
- Step 3 (not implemented): benchmark suite + canary prompts + auto-target
  generation.
