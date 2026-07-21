# Development process — `ramith/smpp`

How each sprint in [docs/sprint-plan.md](sprint-plan.md) actually gets executed. Five
phases, in order, per sprint: **team review → plan → implementation → testing →
adversarial review**. A sprint isn't done until phase 5 passes — "it compiles" and "it
looks right" are not exit criteria anywhere in this process; a passing test and a
survived adversarial pass are.

This is a solo-maintainer project run through Claude Code, so "team" below means the
project's established panel of specialist subagents (`.claude/agents/`:
`architect-reviewer`, `java-architect`, `ballerina-developer`, `code-reviewer`,
`qa-expert`), not literal human meetings. Each phase names which of them to involve.

## Phase 1 — Team review

Before writing any code for a sprint, convene the SMEs whose domain that sprint's work
items touch (see the sprint's table in sprint-plan.md — each item is already tagged by
who scoped it). Their job here is **not** to redesign the fix from scratch — the design
already exists in sprint-plan.md — it's to catch drift:

- Has anything in the code changed since the plan was written that invalidates the
  planned approach (e.g. a prior sprint's diff touched the same lines differently than
  expected)?
- Is the exit gate still the right bar, or did an earlier sprint's adversarial-review
  phase (see Phase 5) surface something that changes this sprint's scope?
- Any new concern worth surfacing before work starts, now that the SME can see the
  current state of the code rather than the snapshot the plan was written against?

Output: either "proceed as planned," or a short scope adjustment written back into the
relevant section of sprint-plan.md before moving on. Don't skip this even when the diff
looks obviously unaffected — it's the cheapest phase and it's what catches a sprint built
against a stale premise before any code is written.

## Phase 2 — Plan

Turn the sprint's work items into a concrete, ordered task list (tracked with TodoWrite
for the duration of the sprint): one task per work item, plus one task per exit-gate
test that doesn't exist yet. Respect the sequencing already called out in
sprint-plan.md's reconciliation notes and dependency graph (e.g. Sprint 2's items are
explicitly ordered: state machine → bound-race fix → TOCTOU fix → onError tracking,
because the later three ride on the first one's lock). If Phase 1 produced a scope
adjustment, this is where it gets reflected in the actual task breakdown.

## Phase 3 — Implementation

Execute the task list. The fix *design* was already done by the SME who scoped it in
sprint-plan.md — this phase is building exactly that, not re-deriving an approach.
Mark each task complete as it lands, not in a batch at the end. If implementation
surfaces something the design didn't anticipate (a wrong assumption, a detail the fix
plan missed), stop and route it back through Phase 1 for the affected item rather than
improvising a divergent fix silently — the whole point of this process is that fixes are
reviewed before they're built, not just after.

## Phase 4 — Testing

Run (or, if it doesn't exist yet, write) the automated tests that this sprint's exit gate
in sprint-plan.md depends on, per the phased rollout in
[docs/qa-strategy.md](qa-strategy.md). A sprint is not "implementation complete" until
its exit gate objectively passes — no sprint here has an exit gate defined as anything
other than tests passing, and that's deliberate. If a sprint's exit gate can't be
verified yet because a prerequisite test-infrastructure item from qa-strategy.md hasn't
landed, that infrastructure gap gets pulled forward ahead of this sprint's other work,
not waived.

## Phase 5 — Adversarial review

Before the sprint is considered done, repeat the review pattern the original audit used,
scoped to just this sprint's diff:

1. **Independent SME review.** The subset of {`architect-reviewer`, `java-architect`,
   `ballerina-developer`, `code-reviewer`} relevant to what changed, each reviewing the
   diff independently (parallel, not sequential, so one reviewer's framing doesn't
   anchor another's) — architect-reviewer for anything touching design/scope decisions,
   java-architect for native-layer changes, ballerina-developer for `.bal`-surface
   changes, code-reviewer for a general adversarial pass over whatever changed.
2. **Hostile red-team pass.** Feed the combined findings through the `the-fool` skill
   (red-team / evidence-audit mode) the same way the original review did: try to kill
   every finding, adjudicate any disagreement between reviewers, and don't let a finding
   survive on an SME's say-so alone — check it against the actual diff.
3. **Disposition.** Anything CONFIRMED either (a) gets fixed within the current sprint if
   it's a regression introduced by this sprint's own change, or (b) gets appended to
   sprint-plan.md as a new backlog/future-sprint item if it's a genuinely separate,
   newly-discovered issue — never silently dropped, and never fixed by improvisation
   without going back through Phase 1 for that item.

Only once phase 5 comes back clean (or its findings are dispositioned per above) does the
sprint's exit gate in sprint-plan.md get marked passed. Commit, push, and move the next
sprint into Phase 1.

## Between sprints

- Update sprint-plan.md: mark the sprint's exit gate passed, note anything Phase 5 added
  to the backlog.
- Commit and push to
  [github.com/ramith/smpp-workspace](https://github.com/ramith/smpp-workspace).
- Start the next sprint's Phase 1. Sprints 0, 1, 3, and 5 have no hard dependency on each
  other (see sprint-plan.md's dependency graph) — if capacity ever allows more than one
  sprint in flight, only Sprint 2 (the lifecycle state machine) needs to run in isolation
  with nothing else touching the same native-layer lock concurrently.
