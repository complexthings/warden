# PRD-1: Compose-to-container translator (core stack: php-fpm, nginx, db)

> Slice 1 of the apple/container work breakdown (see `.agents/plans/OUTLINE.md` §9). Starts the three core services on the container runtime; no networking, proxy, or peering yet. Depends on PRD-0.

## Problem Statement

With PRD-0's runtime foundation in place, warden can detect and validate the apple/container backend but cannot start any environment — `warden env up` remains guarded as unported on the container path. The entire env lifecycle is built on docker-compose: warden assembles 70+ compose YAML partials using a 6-path × 3-suffix override hierarchy (`appendEnvPartialIfExists` in `utils/env.sh`), then passes the assembled list to `${DOCKER_COMPOSE_COMMAND}`. These partials use YAML anchors, merge keys, and shell-variable interpolation — none of which can be parsed reliably with plain bash. A translator that reads those partials and emits equivalent `container run` invocations is the prerequisite for every subsequent slice.

## Solution

On the container runtime, `warden env up` routes to a new bash+jq orchestrator (`utils/orchestrate.sh`) that:

1. Reuses warden's existing `appendEnvPartialIfExists` assembly to build the same `-f <file>` partial list the Docker path produces — override hierarchy unchanged.
2. Shells out to `docker compose -f <list> config --format json` to get the fully merged, interpolated, and anchor-resolved service config as JSON. This delegates all YAML complexity to docker-compose-CLI.
3. Uses jq to extract per-service fields (image, hostname, environment, volumes, depends_on, etc.) from the resolved JSON.
4. Emits and executes `container run` invocations per service in topological start order derived from `depends_on`.

Scope is the three core services — php-fpm, nginx, db — such that all three appear in `container ls` after `warden env up` on the container runtime. Networking, proxy, and peering are explicitly deferred to PRD-2+.

This reverses the OUTLINE §1 / OQ-1 "external helper binary" decision. The binary's sole justification was YAML parsing; `docker compose config` removes that justification. See Implementation Decisions and Further Notes.

## User Stories

1. As a developer on the container runtime, I want `warden env up` to start php-fpm, nginx, and db as running containers, so that I have a working core environment.
2. As a developer, I want the translator to consume the same compose partial assembly order and override hierarchy as the Docker path, so that per-project `.warden/environments/` overrides still apply on the container runtime.
3. As a developer, I want shell-variable interpolation (e.g., `${PHP_VERSION}`, `${WARDEN_ENV_NAME}`, `${WARDEN_IMAGE_REPOSITORY}`) in compose YAML to be fully resolved before translation, so that containers get concrete image tags and names rather than literal variable strings.
4. As a developer, I want YAML anchors and merge keys in compose partials to be expanded before translation, so that complex YAML structures (such as the `x-volumes` anchor in `php-fpm.base.yml`) translate correctly.
5. As a developer, I want containers to start in topological order (db first, then php-fpm, then nginx, per `depends_on`), so that no service starts before its declared dependencies.
6. As a developer, I want the orchestrator to poll until each dependency container reaches "running" state before starting its dependents, so that services do not fail with connection errors during startup.
7. As a developer, I want each started container's name to be derived from the compose service name scoped to the current environment (e.g., `<WARDEN_ENV_NAME>-nginx`), so that container names are predictable and consistent with warden conventions.
8. As a developer, I want all environment variables declared in compose to be forwarded to containers as repeated `-e` flags, so that PHP applications receive the same runtime configuration as they do on the Docker path.
9. As a developer, I want bind mounts from compose to be translated to `container run -v` flags, with the `:cached` mount option stripped, so that project files are accessible inside containers.
10. As a developer, I want the SSH agent socket wired up via the `--ssh` flag rather than the Docker Desktop `/run/host-services/ssh-auth.sock` volume mount, so that SSH agent forwarding works correctly on the container runtime.
11. As a developer, I want named volumes (bashhistory, sshdirectory, dbdata, sqlhistory) created via `container volume create` before containers start, so that containers have persistent storage without startup errors.
12. As a developer, I want the `userns_mode` key in compose YAML silently dropped during translation, so that it does not cause errors with a runtime that does not support it.
13. As a developer, I want `traefik.*` labels in compose YAML omitted from translation, so that proxy routing concerns are cleanly deferred to PRD-2/3 without broken flags.
14. As a developer, I want the `networks` stanza in compose YAML omitted from translation, so that flat-network wiring (PRD-2) is not prematurely handled.
15. As a developer, I want all three containers to actually appear in `container ls` after `warden env up`, so that I can verify the environment is running without a dry-run mode.
16. As a developer on the Docker path, I want `warden env up` to continue invoking `docker compose` exactly as before, so that nothing changes for existing Docker users.
17. As a maintainer, I want the `env` command removed from the unported-command guard that PRD-0 seeded, so that the guard list shrinks as each command is ported.
18. As a developer, I want a clear error if `docker compose config` fails (e.g., due to missing partial files or unresolvable interpolation), so that misconfigured environments surface at partial-assembly time rather than as cryptic jq errors.
19. As a contributor, I want the new orchestration logic in a dedicated `utils/orchestrate.sh` that the `env` command sources via PRD-0's `utils/runtime.sh` seam, so that the translator is easy to locate, extend, and test in isolation.
20. As a developer, I want the orchestrator to log which `container run` invocation it is executing for each service (at least in verbose mode), so that I can trace what happened when a container fails to start.

## Implementation Decisions

- **Config rendering (key decision):** the translator calls `docker compose -f <assembled-list> config --format json`, passing the exact file list that `appendEnvPartialIfExists` in `utils/env.sh` already assembles. This delegates YAML anchor resolution, merge-key expansion, and shell-variable interpolation entirely to docker-compose-CLI. The resulting flat JSON is the sole input to the bash+jq translation step. Trade-off: the container path retains a docker-compose-CLI dependency. This is acceptable for a migration tool in its early slices; it may be revisited once the fleet matures and the tool is no longer needed.

- **Translator (reversal of OQ-1 / OUTLINE §1):** the translator is bash + jq, housed in `utils/orchestrate.sh`. The external Go/Python binary is not introduced. See Further Notes for the explicit reversal rationale.

- **Invocation seam:** on the container runtime, the `up` branch of `commands/env.cmd` detects the runtime via PRD-0's resolver in `utils/runtime.sh` and calls the orchestrator entry point from `utils/orchestrate.sh` instead of invoking `${DOCKER_COMPOSE_COMMAND}`. The `env` command is removed from the unported-command guard list that PRD-0 established (the guard list seeded `env` as unported; it is now ported for the `up` sub-operation at minimum).

- **Compose-key → `container run` flag mapping** for the three core services:

  | Compose key | `container run` flag | Notes |
  |---|---|---|
  | `image` | positional image arg | required |
  | `services.<name>` | `--name <env>-<name>` | scoped to `WARDEN_ENV_NAME` |
  | `hostname` | omitted | apple/container 1.0.0 has no `--hostname` flag (verified); container DNS/hostname handled in PRD-2 |
  | `environment` (list or map) | repeated `-e KEY=VAL` | both list and map forms handled by jq |
  | `volumes` — bind mount | `-v src:dst` | strip `:cached`; `:ro` passthrough deferred |
  | `volumes` — named | `-v name:/path` | pre-create with `container volume create` |
  | SSH auth socket (darwin) | `--ssh` | replaces `/run/host-services/ssh-auth.sock` volume entry |
  | `command` / `entrypoint` | appended after image | if present in resolved JSON |
  | `depends_on` | start ordering + readiness poll | not a flag; drives sequencing logic |
  | `userns_mode` | dropped | VM-level isolation makes it unnecessary |
  | `labels` (traefik.*) | omitted | PRD-3 |
  | `networks` | omitted | PRD-2 |
  | `extra_hosts` | omitted | PRD-3 (Traefik address resolution) |

- **Startup ordering:** jq extracts the `depends_on` graph from the resolved JSON and produces a topological start sequence. For the three core services the sequence is: db → php-fpm → nginx. Before starting each service the orchestrator polls `container inspect <dep-name>` until the dependency reports "running" state (simple loop; configurable poll interval and max retries via constants in `utils/orchestrate.sh`). Healthcheck-based readiness is deferred.

- **Named volumes:** before any `container run`, the orchestrator enumerates all top-level named volumes from the resolved JSON and runs `container volume create <name>` for each. The command is idempotent — an already-existing volume is not an error.

- **Exit = execute:** `container run` is called unconditionally; containers appear in `container ls` after successful `env up`. No dry-run mode in this slice.

- **Mutagen:** before partial assembly on the container path, `WARDEN_MUTAGEN_ENABLE` is forced to `0`; `.mutagen_compose.yml` partials are therefore excluded and their `x-mutagen` keys never reach `docker compose config`.

## Testing Decisions

- **Translation unit tests (bats):** add a bats test file that feeds a fixed resolved-config JSON fixture — representative of `docker compose config --format json` output for the three services — into the jq/bash translation functions in `utils/orchestrate.sh` and asserts the exact `container run` argv produced per service. The fixture captures representative fields: image, hostname, environment entries (both list and map forms), bind and named volume entries, and depends_on edges. Stubs for `container` and `docker compose config` are installed at the command boundary so tests require neither Docker nor apple/container; CI runs clean.
- **Ordering test:** a bats test feeds a depends_on graph and asserts the topological start sequence output by the ordering function — db before php-fpm, php-fpm before nginx.
- **Error-path test:** bats asserts that a non-zero exit from the stubbed `docker compose config` propagates as a fatal error with a descriptive message, not a silent jq failure.
- **Real-hardware smoke:** on apple/container 1.0.0 (macOS 26.6), run `warden env up` against a minimal warden project (e.g., a bare `magento2` env type with only the three core services) and confirm all three containers appear in `container ls`. This is a manual gate before merge, not a CI check — the same approach used to validate PRD-0.
- **shellcheck:** runs on `utils/orchestrate.sh` and any other changed shell files, consistent with the project's existing convention.
- **Regression:** the PRD-0 bats suite continues to pass. Tests added here extend the suite under `tests/` using the same bats framework seam.

## Out of Scope

- Networking, Traefik file-provider config generation, and peered-service wiring (PRD-2, PRD-3).
- Optional services beyond the three: redis, varnish, elasticsearch, rabbitmq, blackfire, selenium (PRD-6, PRD-7).
- Mutagen sync session lifecycle (PRD-4).
- Full volume and SSH-agent parity testing, bind-mount file ownership, `:cached` behavior verification (PRD-4).
- Healthcheck-based container readiness — simple poll only in this slice.
- `warden env down`, `warden env restart`, or `warden svc` on the container path (later slices).
- Release packaging or binary distribution — the reversal of OQ-1 eliminates this concern for this slice.
- `warden env up` for environment types beyond a representative test case (breadth across all env types is PRD-6 scope).

## Further Notes

- **Explicit reversal of OQ-1 / OUTLINE §1:** OUTLINE.md §1 records OQ-1 as RESOLVED-BY-DECISION: "external helper binary (Go/Python) owns YAML→container translation." This PRD supersedes that decision. The binary was justified by YAML parsing complexity — anchors, merge keys, multi-layer interpolation. `docker compose config --format json` removes that justification by doing the parsing itself; the output is flat, concrete JSON that jq handles trivially. No compiled artifact is introduced; no build/distribution dependency is added; the trade-off is retaining docker-compose-CLI on the container path, which is acceptable for a migration tool. OUTLINE.md §1 and §9 are updated to reflect this reversal.
- The `docker compose config --format json` output will include service keys from all assembled partials. The translator must be defensive against keys it does not yet handle (e.g., `cap_add`, `ulimits`) — unknown keys are silently skipped, not fatal, so future partials do not break the translator before they are explicitly mapped.
- The partial-assembly step reuses `appendEnvPartialIfExists` without modification. The only contract PRD-1 adds is: after assembly, on the container path, the file list is passed to `docker compose config` rather than directly to `docker compose up`.
- Story 20 (verbose logging of `container run` invocations) is low-cost and should be included; it is the first debugging surface developers reach for when a container fails to start.
