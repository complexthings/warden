# PRD-0: Runtime backend selection foundation (`WARDEN_CONTAINER_RUNTIME`)

> Slice 0 of the apple/container work breakdown (see `.agents/plans/OUTLINE.md` §9). Foundation only — ships behind a flag, changes nothing for existing Docker users.

## Problem Statement

Warden assumes Docker is the only container runtime on macOS. Developers on Apple silicon who want to evaluate or adopt Apple's `container` runtime (now 1.0.0) as a Docker alternative have no way to tell Warden which backend to use. Before any apple/container support can be built incrementally, Warden needs a way to select a runtime and to validate that the selected runtime is installed, the correct version, and running — without disturbing the existing Docker experience.

## Solution

Introduce an opt-in runtime selector, `WARDEN_CONTAINER_RUNTIME`, with values `docker` (default) and `container`. Add a single runtime-abstraction layer that performs backend-aware preflight checks (installed, version, service running). When the value is unset or `docker`, behavior is byte-for-byte identical to today. When it is `container`, Warden validates the apple/container runtime and then cleanly refuses any subcommand not yet ported, with an explicit message naming the command. This is the foundation every later slice builds on: it lands behind the flag and is observable and testable in isolation.

## User Stories

1. As a Warden maintainer, I want a single environment variable that selects the container runtime, so that later apple/container work can land incrementally behind a flag.
2. As a Magento developer on Docker, I want Warden's behavior to be unchanged when I don't set the flag, so that this initiative never risks my existing environments.
3. As a developer evaluating apple/container, I want to set the runtime globally in my user-level Warden config, so that all my projects use it by default.
4. As a developer, I want to override the runtime per project, so that I can trial apple/container on one project while others stay on Docker.
5. As a developer who selected the container runtime, I want Warden to verify the `container` binary is installed, so that I get a clear error instead of a cryptic downstream failure.
6. As a developer, I want Warden to verify the apple/container version meets a minimum (1.0.0), so that I am not running on an unsupported pre-release.
7. As a developer, I want Warden to verify the apple/container service is running, so that I am told to start it rather than hitting confusing errors later.
8. As a developer on the Docker runtime, I want the existing docker and docker-compose version checks to remain exactly as they are, so that nothing regresses.
9. As a developer who selects the container runtime before a command is ported, I want Warden to fail with an explicit "not yet supported on the container runtime" message that names the command, so that I understand the current state of support.
10. As a maintainer, I want all runtime detection centralized in one module, so that each later slice removes a guard in one place rather than touching scattered branches.
11. As a developer, I want an invalid runtime value to fail fast with the accepted values listed, so that typos are caught immediately.
12. As a maintainer, I want automated tests for the runtime selector, so that the foundation has a regression net as breadth grows.
13. As a contributor, I want the new logic linted by shellcheck like the rest of the codebase, so that it meets project conventions.
14. As a developer, I want to confirm which backend is active (e.g. via verbose or doctor output), so that I can tell at a glance whether I am on Docker or apple/container.

## Implementation Decisions

- **Single seam:** a new runtime-abstraction module (`utils/runtime.sh`) is the one place backend selection lives. It is sourced by the dispatcher alongside the existing core/svc/env utilities. Every later slice hangs new backend logic off this module rather than adding scattered conditionals.
- **Module interface (not call sites):** the module exposes backend-aware assertions keyed on the selected runtime — `assertRuntimeInstalled`, `assertRuntimeVersion`, `assertRuntimeRunning` — plus a resolver that normalizes and validates the selected runtime value.
- **Selector:** `WARDEN_CONTAINER_RUNTIME` accepts `docker` (the default when unset or empty) and `container`. Any other value is fatal and lists the accepted values.
- **Configuration precedence:** follows Warden's existing config model — the user-level Warden config provides the default; a project's environment config may override it; the project wins. Selection is **explicit opt-in**; Warden never auto-switches based on which binaries happen to be installed.
- **Docker path unchanged:** when the runtime is `docker`, the existing binary check and the `docker compose >= 2.2.3` assertion run exactly as before. The existing "is Docker running" check is preserved, now reached through the runtime layer (it delegates rather than duplicating).
- **Container path checks:** installed = the `container` CLI is present; version floor = 1.0.0 (the first stable release); running = the apple/container service reports running via its system status command.
- **Unported-command guard:** once a runtime is validated, any subcommand not yet implemented for the container backend exits via `fatal` with a message naming the command. The allowlist of permitted commands is seeded with the meta/read-only commands that need no orchestration — `version`, `doctor`, `help` — so Warden stays inspectable on the container runtime (notably, `doctor` must run to surface the active backend). Every orchestration command (`env`, `svc`, `db`, `shell`, …) stays guarded; later slices remove a command's guard as they port it. The Docker backend carries no guards.
- **De-duplication:** the existing Docker "running" check is refactored to delegate to the runtime layer so there is a single running-check, not two.

## Testing Decisions

- **What makes a good test:** assert the *external behavior* of the runtime layer — which runtime is selected, the pass/fail of each preflight check, and the exact refusal behavior — not internal implementation details.
- **Framework:** introduce **bats-core** as Warden's first test framework. Add a test file for the runtime module covering: default resolves to `docker`; explicit `container` is honored; a project override beats the global default; missing `container` binary is fatal; a below-floor version is fatal; service-not-running is fatal; an unported command on the container runtime is fatal and names the command; an invalid runtime value is fatal and lists accepted values.
- **Isolation:** the binary, version, and status invocations are stubbed at the command boundary so tests do not require Docker or apple/container to be installed (CI-friendly).
- **Lint:** shellcheck runs on all changed shell files, consistent with the project's existing expectation (the codebase already uses `# shellcheck disable=` directives).
- **Prior art:** none — there is no existing test suite. This PRD establishes the bats seam that later slices reuse.

## Out of Scope

- Any actual orchestration, container running, networking, volumes, or service definitions on the container runtime (PRD-1 onward).
- Porting any specific subcommand (`env`, `svc`, `db`, etc.) to the container backend.
- Any change to mutagen, Traefik, peered services, or the compose-file layering.
- Intel Mac, Linux, or non-Apple-silicon support — the container runtime path is Apple-silicon + macOS 26+ only and is gated by the flag regardless.
- Documentation-site updates (tracked separately).

## Further Notes

- **Verified facts behind this slice** (real hardware, macOS 26.6, apple/container 1.0.0, 2026-06-27): the service status command is `container system status`; the runtime is at 1.0.0, so the earlier pre-1.0 caveat no longer applies.
- Surfacing the active runtime in doctor/verbose output (story 14) is a low-cost nice-to-have; include if cheap, otherwise defer to a later slice.
- This is the foundation for the 8-slice breakdown in `.agents/plans/OUTLINE.md` §9; PRD-1 through PRD-7 depend on the module this PRD introduces.
