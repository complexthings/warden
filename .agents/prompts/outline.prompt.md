# Create an Outline: apple/container as a Docker Replacement for Warden (macOS)

You are an orchestrator. You never execute directly. You delegate every task to subagents.

## Goal

Use /grill-with-docs to produce an exploratory outline of the changes required to replace Docker with apple/container in `warden` (a Docker-based CLI for managing magento-2 / Adobe Commerce development environments) when running on macOS. Save the outline to `.agents/plans/OUTLINE.md`.

## Resources

- apple/container docs: https://github.com/apple/container/tree/main/docs
- warden docs: https://github.com/wardenenv/docs
- Local warden images fork: /Users/greg/sites/wardenenv/images

## Orchestration Rules

Subagent models:

| Model | Use for |
|---|---|
| Claude Sonnet 4.6 | Logic and reasoning, writing and editing, general knowledge |
| Claude Haiku 4.5 | Read-only, exploration, summarization |

- Execution mode: subagents run with `ponytail full`.
- Subagents requesting subagents: a subagent may request support subagents for read-only exploration or simple tasks. If it cannot spawn them directly, it asks you to spawn them and coordinates the context handoff. The requesting subagent stays responsible for its own execution and final-output validation.
- File ops: USE rtk. You and all subagents MUST READ the leveraging-cli-tools skill before any execution. Subagent scratch notes go in `.agents/workspaces/` and are removed on completion; only `.agents/plans/OUTLINE.md` persists.
- Parallelism: spawn parallel subagents whenever subtasks are independent (multi-file reads, fan-out research). Size the pool per fan-out; no fixed cap.
- Git: no commits, no PRs. Work on main; the user reviews and commits manually.

## Success Criteria

`.agents/plans/OUTLINE.md` exists and captures the changes required to run warden on apple/container instead of Docker on macOS, at the structure and depth /grill-with-docs produces. Where the resources are silent, the outline records open questions rather than guesses. Stop when the file is written. This is outline-only: do not write or change any warden code.

## Drafting Rules (for the subagent writing OUTLINE.md)

- Do not invent warden internals or apple/container behavior. Ground every claim in the provided resources or /grill-with-docs output; where a resource is silent, record an open question rather than guessing.
- Keep the outline scoped to the macOS Docker-to-apple/container swap; do not branch into unrelated warden refactors.