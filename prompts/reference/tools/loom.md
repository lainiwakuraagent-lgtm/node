# Loom / SOP Reference

Reference material, not injected into every session — read this when a task's tags
need resolving to their SOPs, or when deciding whether a new SOP is warranted.
Execution sessions get the actionable resolution step directly in
`execution_prompt.md`; come here for the Loom CLI itself and the full new-SOP policy.

## Loom CLI

Loom's own bundled docs are the source of truth for command syntax — don't duplicate
it here: `loom/README.md` (CLI usage), `loom/CLAUDE.md` (data model), `loom/MCP.md`
(MCP tool surface). Binary: `jar` (see `bin/loom`, `tools/executional/loom.sh`).

## SOP tags: what they are, and how they differ from skills

A Claude Skill is agent-discretionary — you decide whether to invoke it. An SOP is
not: it's dispatched deterministically off a task's tags, and once a tag resolves to
an SOP, that SOP's procedure is mandatory for the task, not optional reading.

A task can carry multiple tags (Loom's `tags` field is a list) — resolve *every* tag
on the task, not just the first that matches. If more than one tag resolves, all of
those SOPs apply; if two conflict, the more specific one (closer to what's actually
being built, not a domain-wide one like `sop-infra`/`sop-repo-work`) wins — note the
conflict in the task's `handoff_note` either way.

### `tag_skill_lookup.py` — full reference

Three modes, all invoked as `scripts/executional/tag_skill_lookup.py --project-dir . <mode>`:

- **`--tag <tag>`** — resolve one tag to its skill file path, or exit non-zero with no
  match. What an execution session runs per-tag, once per tag on its current task,
  before starting work (see `execution_prompt.md` step 2).
- **`--list`** — print every existing SOP tag, its skill file path, and its one-line
  `description:` (parsed straight from the skill file's YAML frontmatter). This is
  what a **planning session must run before assigning any tag to a task** — the
  description is what makes the check catch a semantic duplicate, not just an exact
  name collision. A task that reads like "code review" in the moment might already be
  covered by `adversarial`; the tag name alone wouldn't surface that, the description
  does. See `planning_prompt.md`'s "Tag discipline" section.
- **`--validate-all`** — meant for CI/health-check use. Scans `skills/sop-*/` directly
  and flags any directory missing a `SKILL.md`, or with one that has no parseable
  `description:`. No fixed manifest, by design (an earlier version hardcoded a tag
  list here — it went stale three times as SOPs were added/removed/renamed across a
  single session, which is exactly the failure mode a self-consistency check avoids).
  This means it validates *structural* completeness (every SOP directory is
  well-formed), not "the expected set of tags exists" — there is no expected set to
  check against, by the same encapsulation logic that governs the rest of this file.

All 14 `skills/sop-*/SKILL.md` files are self-contained as of 2026-08-02 — the four
that used to end with a "Full SOP → `memory/work/sop/sop_<name>.md`" pointer
(`design`, `deployment`, `integration`, `research`) had that stripped; the directory
never existed and nothing in those four needed more depth than the other ten already
carry inline. Don't recreate a skill-plus-companion-doc split without a real reason —
self-contained is the working pattern here.

This file currently documents SOP tag dispatch only. Task/project/goal lifecycle
mechanics (status transitions, how `active_goal_id`/`active_project_id` resolve, the
`files` column being dead, etc.) are covered piecemeal today in `memory_strategy.md`
and by reading `state/loom_context.json`'s own shape — folding a fuller Loom
data-model walkthrough into this file is a natural next expansion, not done here.

## Encapsulation, not discoverability

SOPs are deliberately not built on the Claude Skill browsing model, where every
available skill's name and description gets surfaced into a session's context by
default. That model is fine for skills — they're optional, the agent decides whether
to open one, and the cost of listing all of them is paid once regardless of relevance.
An SOP is different: it's mandatory once it applies, which flips the failure mode to
guard against. It isn't "the agent doesn't know an SOP exists" — it's every session,
including ones that never touch a tagged Loom task, carrying the weight of the full
SOP menu whether or not it's relevant.

So the loading discipline stays deliberately narrow:

- **Execution sessions** resolve only the tags on the *one task currently being
  worked* — never the full list.
- **Planning sessions** run `--list` only at the specific moment of assigning tags to
  a task — a targeted lookup, not a standing preload.
- **No other session type** touches SOP content at all. Philosophy, reflection,
  maintenance — none of them process tagged Loom tasks, so none of them have any
  reason to load `--list`, a skill file, or this document as part of their preload. If
  a future session type starts doing tagged task work, it earns the same narrow
  resolution step execution/planning already have — it doesn't get the whole catalog
  by default.

This applies uniformly regardless of whether a given SOP is domain-agnostic or
domain-specific — "applies to any kind of agent" is a fact about a *topic's* scope
(see "When to propose a new SOP" below), not license to broadcast it more widely.
Encapsulation is the point of the tag-dispatch model; don't let it drift back toward
the browsable-menu shape it was deliberately built to avoid.

## When to propose a new SOP

**Scope test.** An SOP exists to answer a *repeatable procedural question* — "when a
task like this comes up, what fixed steps get followed, every time, without
re-deriving them." Two conditions, both required:

1. It recurs across an identifiable category of tasks, not a one-off.
2. That category can be named by a task-level tag (or a stack of tags).

No restriction on domain — architecture/design work, code-pattern conventions,
inter-agent conversation protocol, anything else all qualify equally if they pass the
test above. No restriction on frequency either — a category that happens to fire on
nearly every task for this particular clone's actual workload is still legitimately
category-scoped; that's a fact about this clone's domain, not a reason to fold it into
always-loaded baseline content. (Baseline/core is reserved for what's true of *every*
clone by virtue of being this kind of agent at all — identity, memory discipline,
orientation — not for whatever a given clone happens to do most often.)

**Trigger.** First occurrence. As soon as you recognize — by the test above — a
genuinely repeatable procedural question with no tag that resolves to an existing SOP,
you may propose one. (This differs from `memory/knowledge/`'s consolidation rule,
which waits for a second occurrence: knowledge entries are cheap and reversible to
split later, but an SOP is mandatory-loaded machinery — the cost of naming it
precisely once you've actually seen the pattern is lower than the cost of a wrong
ad-hoc procedure repeating unexamined until a second data point shows up.)

**Mechanism.** Spawn a Loom task with status `needs_plan` (no SOP tag of its own — this
is a decomposition question, not a category of work with a fixed procedure):

```
jar task add --status needs_plan --name "Define SOP for <tag>" \
  --description "No SOP exists for <tag>. Surfaced by task #<id>: <one-line context>."
```

The next planning session picks it up through its normal decomposition work — stating
the question, converging on what the procedure should actually be, same judgment a
planning session already applies to any other `needs_plan` item. The deliverable is
the new `skills/sop-<tag>/SKILL.md`. Don't skip straight to writing the skill file
from inside the execution session that hit the gap — routing it through planning is
what makes the new procedure something actually converged on, not something invented
mid-task and never reconsidered.

Do not propose a new SOP for something that isn't actually repeatable, and don't fold
a near-universal-but-category-specific concern into baseline just because it happens to
be frequent — see the scope test above.
