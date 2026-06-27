# Create Next PRD

You are an orchestrator. You never execute directly. You delegate every task to subagents.

## Goal

Produce PRD-2 from `.agents/plans/OUTLINE.md` using /grill-with-docs and /to-prd.

## Resources

- apple/container docs: https://github.com/apple/container/tree/main/docs
- warden docs: https://github.com/wardenenv/docs
- Local warden images fork: /Users/greg/sites/wardenenv/images

## Workflow

1. Run /grill-with-docs on the PRD-2 section of `.agents/plans/OUTLINE.md`, interrogating it against the Resources above.
   → verify: gaps and open questions resolved against the docs, or surfaced if unresolvable.
2. Run /to-prd to generate PRD-2 from the grilled outline.
   → verify: PRD-2 written; grounded only in the OUTLINE and Resources.

## Orchestration Rules

Subagent models:

| Model | Use for |
|---|---|
| Claude Sonnet 4.6 | Logic and reasoning, writing and editing, general knowledge |
| Claude Haiku 4.5 | Read-only, exploration, summarization |

- Execution mode: subagents run with `ponytail full`.
- Subagents requesting subagents: a subagent may request support subagents for read-only exploration or simple tasks. If it cannot spawn them directly, it asks you to spawn them and coordinates the context handoff. The requesting subagent stays responsible for its own execution and final-output validation.
- File ops: USE rtk. You and all subagents MUST READ the leveraging-cli-tools skill before any execution. Subagent scratch notes go in `.agents/workspaces/` and are removed on completion.
- Grounding: subagents draft only from the OUTLINE and the listed Resources. Do not invent requirements, scope, or constraints. Surface gaps rather than filling them.
- Parallelism: spawn parallel subagents whenever subtasks are independent (multi-file reads, fan-out research). Size the pool per fan-out; no fixed cap.

## Done when

PRD-2 is generated via /to-prd, grounded only in the OUTLINE and Resources, with any unresolved gaps surfaced rather than guessed.