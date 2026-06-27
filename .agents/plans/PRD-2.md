# PRD-2: Flat network + DNS + IP discovery

> Slice 2 of the apple/container work breakdown (see `.agents/plans/OUTLINE.md` §9). Establishes the shared network that all services use; covers `svc` de-guard, network model selection, DNS strategy, IP discovery via inspect, and env-down routing on the container path. Depends on PRD-1. **D-2.1 RATIFIED: option (a) — the apple/container DEFAULT network + `<name>.test` FQDN DNS** (see Implementation Decisions).

## Problem Statement

With PRD-1's translator in place, the three core services start as containers but are network-isolated: no container can reach any other, and no global service (Traefik, tunnel, mailhog) is reachable from project containers. The mechanism that bridges these today is `connectPeeredServices` / `disconnectPeeredServices` in `utils/core.sh:44-68`, which loops over `docker network connect <projnet> <svc>` after Docker Compose has already started the per-project stack. apple/container has no `container network connect` command (OQ-4 CONFIRMED — the subcommand does not exist in container 1.0.0; command-reference.md lists the complete set as `create`, `delete`, `prune`, `list`, `inspect`). Network assignment is creation-time only via `--network` on `container run` or `container create`. The entire post-start peering mechanism must be replaced.

Three additional gaps prevent a working environment on the container path:

1. **`warden svc` is still unported.** `assertCommandSupportedForRuntime` in `utils/runtime.sh:98` lists `_ported=(version doctor help env)` — `env` was added by PRD-1 but `svc` is not present. Any `warden svc up` fatals on the container path before reaching any network code.
2. **`env down` is unguarded on the container path.** The escape hatch at `env.cmd:172` fires only for the `up` sub-operation. `env down` falls through to `disconnectPeeredServices` at line 181 (calls `docker network disconnect`) and eventually to `${DOCKER_COMPOSE_COMMAND}` at line 242 — both crash on the container path. The `TRAEFIK_ADDRESS` export at `env.cmd:210-215` (uses `docker container inspect traefik` with a Go template) is also reached for non-`up` operations and will fail.
3. **DNS strategy is unresolved.** The OUTLINE assumed `<container-name>.test` FQDN would work between containers on a shared custom `warden` network (OQ-5 marked RESOLVED). Empirical grilling refutes this: container-to-container name DNS on custom networks returns NXDOMAIN in container 1.0.0 (issue #1809, open). Bare-name DNS (`<name>`, no suffix) fails on both default and custom networks (issues #856, #1809). The only doc-demonstrated container-to-container name-DNS path requires the apple/container DEFAULT network plus a privileged host step (`sudo container system dns create test` — tutorials/start-here.md:108-116). The OUTLINE's flat custom-network decision therefore forfeits the only doc-backed name-DNS path. OQ-5 is PARTIAL, not RESOLVED.

A fourth correctness bug: `container inspect <name>` returns a JSON array. The OUTLINE's `jq -r '.networks[0].address'` applies to the outer object and silently returns `null`. The correct path is `.[0].networks[0].address`.

## Solution

Per ratified D-2.1 (option a), PRD-2 delivers in four coupled steps:

1. **De-guard `svc`:** add `svc` to the `_ported` array in `utils/runtime.sh:98`. This prerequisite step unblocks all remaining work in this slice.
2. **Network model — DEFAULT network (no custom network):** all global services and project containers run on apple/container's built-in default network. There is **no** `container network create/delete warden` — the default network always exists and cannot be deleted (command-reference.md: "default and system networks are preserved"). Container-to-container resolution is by `<name>.test` FQDN, enabled by the one-time host step `sudo container system dns create test`. The Docker-path label-scan peering loop at `svc.cmd:118-131` (label `dev.warden.environment.name`, no `container` equivalent) and its `connectPeeredServices` call at line 125 are bypassed on the container path; the Docker path is unchanged.
3. **Create-time attachment + `.test` FQDN service config:** all global services (traefik, tunnel, mailhog) and all project containers start on the default network (omit `--network`, or pass `--network default` explicitly) at `container run` time. `connectPeeredServices` / `disconnectPeeredServices` (`utils/core.sh:44-68`) are bypassed on the container path — no post-start network attach step exists or is needed. Compose YAML environment variables that name inter-container targets by bare hostname (e.g., `DB_HOST=db`, nginx `fastcgi_pass php-fpm:9000`) are audited and rewritten to `<name>.test` FQDNs on the container path, because bare-name DNS is NXDOMAIN on the default network (issues #856, #1809).
4. **`env down` route + `TRAEFIK_ADDRESS` guard:** add a container-path branch for `env down` in `env.cmd` mirroring the `up` hatch at line 172 — it stops the project's containers by name (no network teardown; the default network persists). Guard the `TRAEFIK_ADDRESS` export at `env.cmd:210-215` so the `docker container inspect` Go-template call is not reached on the container path (Traefik wiring is PRD-3; the export is a no-op in this slice). IP discovery (used for Traefik in PRD-3, and for the smoke test here) uses the corrected path: `container inspect <name> | jq -r '.[0].networks[0].address' | cut -d/ -f1`.

The `svc` de-guard lands first; the remaining steps follow now that D-2.1 is settled.

## User Stories

1. As a developer on the container path, I want `warden svc up` to proceed past the unported-command guard, so that global services can start and the network can be created.
2. As a developer, I want all containers to share the apple/container default network rather than per-project networks, so that global services and project containers have connectivity without any per-project network management.
3. As a developer, I want all project containers started on the default network at `container run` time, so that inter-container connectivity is available from the moment each container starts.
4. As a developer, I want all global services (traefik, tunnel, mailhog) started on the default network at `container run` time, so that Traefik can route to project containers without any post-start attach step.
5. As a developer, I want `warden svc down` to stop the global service containers (the default network is never deleted, since it cannot be), so that teardown is a simple container-stop with no network-delete step that could fail.
6. As a developer on the Docker path, I want `warden svc up/down` and `warden env up/down` to behave exactly as before, so that nothing changes for existing Docker users.
7. As a developer, I want `warden env down` on the container path to route to an orchestrator-aware teardown rather than falling through to `disconnectPeeredServices` and `docker compose down`, so that `env down` does not crash on the container path.
8. As a developer, I want the `TRAEFIK_ADDRESS` export at `env.cmd:210-215` guarded so it is not reached on the container path, so that its `docker container inspect` Go-template call does not crash non-`up` operations before Traefik is wired in PRD-3.
9. As a developer, I want `connectPeeredServices` and `disconnectPeeredServices` bypassed on the container path, so that no code path calls `docker network connect/disconnect` on the container runtime.
10. As a developer, I want container IPs read from `container inspect <name> | jq -r '.[0].networks[0].address' | cut -d/ -f1`, so that the correct jq path (accounting for the outer array wrapper) is used — the OUTLINE's `.networks[0].address` path silently returns null.
11. As a developer, I want IP re-read on every `warden env up` rather than cached, so that DHCP-assigned addresses that change across restarts do not produce stale routes.
12. As a developer, I want `warden install` to ensure the `sudo container system dns create test` host step has run (idempotently), so that `<name>.test` resolution works for both host dev-URLs and container-to-container DNS without a manual setup step.
13. As a developer, I want container-to-container targets (nginx → php-fpm, php-fpm → db) referenced by `<name>.test` FQDN in service config on the container path, so that resolution works — bare names are NXDOMAIN on the default network (issues #856, #1809).
14. As a developer, I want `warden svc.cmd`'s Docker-path label-scan loop (`docker network ls -f label=...` at svc.cmd:124) bypassed on the container path, so that a call with no `container` equivalent is never made.
15. As a developer, I want `renderEnvNetworkName` (which produces per-project `<env>_default` Docker network names) unused on the container path, so that per-project network creation is not attempted on the default-network model.
16. As a developer, I want global services to use the same container names the rest of warden references (`traefik`, `tunnel`, `mailhog`), so that existing call sites referencing those names stay valid on the container path.
17. As a developer, I want `svc` added to the `_ported` list in `utils/runtime.sh:98` atomically with the `svc up/down` container-path implementation, so that the guard and its implementation land together.
18. As a developer, I want `warden svc down` to stop global service containers cleanly without attempting any `container network delete` (the default network persists), so that teardown has no network-delete failure mode.
19. As a maintainer, I want bats tests covering the container-path `env down` route and the `svc up/down` container-stop lifecycle, so that teardown regressions are caught before merge.
20. As a developer, I want all three core services reachable from each other by `<name>.test` FQDN after `warden env up` on the container path, so that the network slice delivers observable inter-container name resolution as its exit criterion.

## Implementation Decisions

### DECISION D-2.1 — Network + DNS strategy — **RATIFIED: option (a)**

The OUTLINE recorded "single flat custom `warden` network, driven by OQ-4," premised on OQ-5's (refuted) claim that `<name>.test` DNS works between containers on a shared custom network. Grilling demoted OQ-5 to PARTIAL. The decision was re-opened and **ratified as option (a): the apple/container DEFAULT network + `<name>.test` FQDN DNS.** The three options considered are retained below as the decision audit trail; options (b) and (c) are NOT taken.

**(a) DEFAULT network + `container system dns create test` — ✅ CHOSEN (only doc-backed name-DNS path)**

All global services and project containers use apple/container's built-in default network (no `--network` flag, or explicit `--network default`). The one-time host step `sudo container system dns create test` (already required for host-level `*.warden.test` DNS, confirmed by OQ-6) writes `/etc/resolver/test`, making `<name>.test` FQDNs resolvable container-to-container via the default network's DNS gateway (tutorials/start-here.md:274-278 demonstrates this). Service config must reference inter-container targets by `<name>.test` FQDN (e.g., `php-fpm.test:9000`, `db.test`) rather than bare names, which are NXDOMAIN on both network types (issues #856, #1809). Isolation between default-network and custom-network containers is preserved (how-to.md:323 confirms cross-network isolation); isolation *within* the default network is the same flat model as option (b). Teardown: `container network prune` and `container network delete default` both leave the default network untouched (command-reference.md: "default and system networks are preserved"). Full teardown of a default-network deployment requires `container system stop`; per-project `env down` stops individual containers without touching the network.

*Cost:* warden compose YAML environment variables that set inter-container hostnames (e.g., `DB_HOST=db`) must be audited and updated to `.test` FQDNs. Alternatively, `--dns-search test` may allow bare-name resolution as `<name>.test`, but this flag's behavior on apple/container is undocumented — treat as unverified until tested.

**(b) Custom `warden` network + IP-wire via `container inspect` — NOT TAKEN (works today; most moving parts)**

All services start with `--network warden` (one-time `container network create warden` at `svc up`). On each `env up`, the orchestrator re-reads every peer container's IP (`container inspect <name> | jq -r '.[0].networks[0].address' | cut -d/ -f1`) and injects IPs into dependent containers via `extra_hosts` or config-file templating (e.g., nginx upstream block with IP, `DB_HOST` env var set to IP). IPs are DHCP-assigned on `192.168.64.0/24`. MAC pinning (`--network warden,mac=XX:XX:XX:XX:XX:XX`) provides best-effort DHCP lease stability (how-to.md:237-239: "consistent network configuration across container restarts") but is not a documented guarantee — issue #282 (open) requests a `--ip` flag that does not exist. Re-read on every `env up` regardless. Teardown is explicit: `container network delete warden` after all attached containers are stopped. The same IP-discovery code PRD-3 needs for Traefik file-provider config is a natural fit here. `ponytail: re-reads IP on each env up; MAC pinning is heuristic, not guaranteed — upgrade to --ip when issue #282 ships`

**(c) Wait for upstream network-alias support — NOT TAKEN (not viable for this slice)**

PRs #1810 (hostname lookup normalization), #1813 (container DNS listener), #1815 (network attachment aliases: `--network warden,alias=db`), and issue #1839 are all OPEN and not merged into any tagged 1.0.x release. PR #1815 is validated on a debug build only. No release date is known. PRD-2 cannot block on these.

**Why (a):** it is the only path with doc-demonstrated container-to-container name DNS in container 1.0.0, and it offers identical isolation to option (b). The `container system dns create test` host step is already required for the warden host-side `.test` URL resolver (OQ-6 confirmed), so it adds no new prerequisite. The principal cost is auditing service config for bare inter-container hostnames and rewriting them to `.test` FQDNs on the container path.

---

**Implementation decisions (D-2.1 settled):**

- **`svc` de-guard (do first):** add `svc` to `_ported` at `utils/runtime.sh:98`. Current list after PRD-1: `(version doctor help env)`. New list: `(version doctor help env svc)`.

- **`svc.cmd` container-path routing:** on the container path, gate the block at `svc.cmd:118-131` by runtime. Replace the Docker Compose invocation and the post-compose peering loop (label scan at line 124 + `connectPeeredServices` at line 125) with: for `svc up` → start the global service containers (`traefik`, `tunnel`, `mailhog`) on the default network — **no `container network create`** (the default network always exists); for `svc down` → stop those global service containers — **no `container network delete`** (the default network cannot be deleted; command-reference.md preserves default/system networks). Docker path at these lines is unchanged.

- **`env down` container-path branch:** add a container-path escape hatch for `down` at `env.cmd` mirroring the `up` hatch at line 172. On the container path, `env down` stops the project's containers by name and returns — no `disconnectPeeredServices`, no `${DOCKER_COMPOSE_COMMAND} down`. `renderEnvNetworkName` is not called; no per-project network to delete.

- **`TRAEFIK_ADDRESS` guard (`env.cmd:210-215`):** this block is reached for all non-`up` operations. On the container path, set `TRAEFIK_ADDRESS=""` and skip the `docker container inspect` call. The export is used by compose YAML interpolation on the Docker path; it is unused on the container path in this slice.

- **IP discovery jq path (OUTLINE CORRECTION):** `container inspect <name>` output is a JSON array (confirmed: how-to.md:116-126 shows `[{"status": "running", "networks": [{"address": "192.168.64.3/24", ...}]}]`). The correct extraction: `container inspect <name> | jq -r '.[0].networks[0].address' | cut -d/ -f1`. The OUTLINE's `jq -r '.networks[0].address'` applies to the outer object and returns `null`.

- **Teardown:** the default network is never deleted (it cannot be — command-reference.md preserves default/system networks; `container network delete` / `prune` only touch user-created networks). `warden svc down` simply stops the global service containers. There is no network-delete ordering constraint to manage. If project containers are still running when `svc down` is called, the default network and those containers are unaffected; surface an informational note but take no network action. *(Had option (b) been chosen, `container network delete warden` would have required all attached containers stopped first per how-to.md:349 — not applicable to option (a).)*

- **Container naming for global services:** `DOCKER_PEERED_SERVICES=(traefik tunnel mailhog)` (utils/core.sh:6). The mailpit compose file sets `container_name: mailhog` (docker-compose.mailpit.yml:3) for backward compatibility; container-path global services must use the same names.

- **`connectPeeredServices` / `disconnectPeeredServices` (`utils/core.sh:44-68`):** remain intact for the Docker path. The container path never calls them. `getPeeredServices` (utils/core.sh:44-52) is also Docker-only by construction; it is bypassed without modification.

- **`renderEnvNetworkName` (`utils/env.sh:106-108`):** produces `<WARDEN_ENV_NAME>_default` (lowercased). Unused on the container path. Remains for the Docker path.

- **Compose-key mapping addendum for `utils/orchestrate.sh`:**

  | Item | Container-path behavior (D-2.1 = option a) |
  |---|---|
  | `networks` stanza | PRD-1 already omits this; containers run on the default network (omit `--network`, or pass `--network default`) at `container run` time |
  | inter-container hostnames | rewrite bare names (`db`, `php-fpm`) to `<name>.test` FQDNs in resolved env vars / generated config |
  | IP discovery | `container inspect <name> \| jq -r '.[0].networks[0].address' \| cut -d/ -f1` (for PRD-3 Traefik + smoke test; not needed for inter-container wiring under option a) |
  | `extra_hosts` | omitted (option a uses `.test` FQDN DNS, not IP injection) |

## Testing Decisions

- **bats — `svc` de-guard:** assert that on the container path, `warden svc up` no longer produces a "not yet supported" fatal; assert global service containers are started on the default network (stubbed) and **no** `container network create` is invoked.
- **bats — `svc` lifecycle:** assert `svc up` starts the global service containers and never calls `container network create/delete`; assert `svc down` stops those containers and never calls `container network delete` (default network is not deletable).
- **bats — `.test` FQDN rewrite:** assert that bare inter-container hostnames in resolved service config (e.g. `DB_HOST=db`) are rewritten to `<name>.test` (`DB_HOST=db.test`) on the container path, and left untouched on the Docker path.
- **bats — `env down` route:** assert `env down` on the container path does not invoke `docker network disconnect` or `${DOCKER_COMPOSE_COMMAND} down`; assert project containers are stopped and no network deletion is attempted.
- **bats — jq path regression:** feed the literal `container inspect` JSON array (`[{"networks": [{"address": "192.168.64.3/24"}]}]`) into the IP-discovery function; assert the output is `192.168.64.3`. This test fails with the old `.networks[0].address` path, passes with `.[0].networks[0].address | cut -d/ -f1`.
- **bats — `TRAEFIK_ADDRESS` guard:** assert that on the container path, `env down` does not invoke `docker container inspect traefik`.
- **Regression:** PRD-0 and PRD-1 bats suites continue to pass.
- **Real-hardware smoke (manual gate before merge):** with `sudo container system dns create test` run once, `warden svc up && warden env up` on the container path; confirm all containers appear in `container ls`; confirm inter-container name resolution (e.g., `container exec <env>-nginx ping -c1 php-fpm.test` and a successful nginx→php-fpm request); confirm `warden env down` and `warden svc down` complete without error (the default network remains).
- **shellcheck:** on all changed shell files, consistent with project convention.

## Out of Scope

- Traefik file-provider config generation and HTTPS project loading (PRD-3). *(Note: the `.test` FQDN rewrite for the three core services' inter-container hostnames IS in scope here — it is how nginx→php-fpm→db resolve under option (a). Traefik's own routing config is PRD-3.)*
- Optional services beyond php-fpm, nginx, db: redis, varnish, elasticsearch, rabbitmq, blackfire, selenium (PRD-6, PRD-7) — their `.test` FQDN rewrites land with those slices.
- Volumes, file sync, SSH agent parity (PRD-4).
- phpMyAdmin DB-discovery call sites in `utils/core.sh:83-86` and `status.cmd` / `db.cmd` inspect ports (PRD-6).
- IP pinning via `--ip` flag — does not exist in container 1.0.0 (issue #282 open).
- Upstream network-alias support — PRs #1810, #1813, #1815 and issue #1839 are open and unmerged; PRD-2 does not wait on them, but they should be tracked before PRD-3 planning (if #1815 merges into a tagged release, option (c) becomes viable and may simplify PRD-3's Traefik wiring).
- Full `warden env` subcommand parity beyond `up` and `down` — deferred.

## Further Notes

- **D-2.1 ratified — option (a).** Consequences now settled: (1) service config for the three core services needs bare→`.test` FQDN rewrites; (2) there is NO `container network create/delete` step — containers use the undeletable default network; (3) no IP-injection plumbing in the orchestrator (name DNS handles inter-container resolution; IP discovery is retained only for PRD-3 Traefik and the smoke test). The `svc` de-guard lands first; the rest follows.

- **OUTLINE corrections encoded in this PRD:**
  - **OQ-5 demoted from RESOLVED to PARTIAL.** The OUTLINE states "`<container-name>.test` DNS works between containers on same user-defined network — macOS 26+ ONLY." This is wrong in two ways: (1) name DNS on a user-defined (custom) network returns NXDOMAIN in container 1.0.0 (issue #1809); the custom-network docs section is entirely IP-based with no hostname mentions. (2) The `.test` suffix is not "built into the VM's internal resolver scoped to the vmnet" — it is a host-side `/etc/resolver/test` file written by `sudo container system dns create test` (a privileged step, tutorials/start-here.md:108-116). The thing that works is `<name>.test` FQDN on the DEFAULT network via the host DNS gateway; bare-name resolution is broken on both network types (issues #856, #1809).
  - **OQ-9 jq path is wrong.** The OUTLINE records `jq -r '.networks[0].address'` as the inspect path. `container inspect` returns a JSON array; this path returns `null`. Correct: `jq -r '.[0].networks[0].address'` (confirmed against how-to.md:116-126 sample output).
  - **"DECISION: single flat `warden` network" is re-opened as D-2.1.** The OUTLINE presents this as resolved. The DNS premise that grounded it does not hold. It is presented here as three options with a recommendation, pending human ratification.
  - **`connectPeeredServices` / `disconnectPeeredServices` line numbers.** OUTLINE §2 cites `utils/core.sh:46-71`; actual range per HEAD is `44-68`.
  - **`env down` gap not mentioned in OUTLINE.** The OUTLINE says `disconnectPeeredServices` "are dropped" on the container path but does not note that `env down` has no container-path route and falls through to Docker calls. PRD-2 must add the route.
  - **`svc` de-guard not called out in OUTLINE §9 PRD-2 scope block.** The OUTLINE says "replace `connectPeeredServices`" but does not explicitly state that `svc` must be added to `_ported` in `utils/runtime.sh:98`. This is a prerequisite, not implied.

- **Code lines that change in this slice** (based on grill-code.md HEAD; re-read files before editing — line numbers drift):

  | File | Approximate line(s) | Change |
  |---|---|---|
  | `utils/runtime.sh` | 98 | add `svc` to `_ported` array |
  | `commands/svc.cmd` | 118-131 | gate on runtime; replace compose + peering loop with start/stop of global service containers on the default network (no `container network create/delete`) |
  | `commands/env.cmd` | ~172 | add `down` branch to the container-runtime escape hatch (stop project containers; no network teardown) |
  | `commands/env.cmd` | 210-215 | guard `TRAEFIK_ADDRESS` export on container path |
  | `utils/orchestrate.sh` | (new sites from PRD-1) | rewrite bare inter-container hostnames to `<name>.test`; default network (omit `--network`); `.[0].networks[0].address` jq path for IP discovery |

- **Near-term upstream to track:** PR #1815 (network attachment aliases) is ready-for-review. If it merges into a tagged 1.0.x before PRD-3 planning, option (c) becomes viable and may allow the custom-network model with compose-style `alias=db` discovery, eliminating the IP-wiring complexity of option (b). Re-evaluate D-2.1 if #1815 ships.

- **`warden install` prerequisite:** `sudo container system dns create test` must be present in `warden install` (or `assertWardenInstall`) regardless of which D-2.1 option is chosen. OQ-6 (empirically verified on macOS 26.6) confirms the resulting `/etc/resolver/test` entry routes `*.warden.test` queries to `127.0.0.1:53`. Option (a) additionally relies on this resolver for container-to-container DNS; option (b) does not, but the install step is needed for host-level dev URLs either way.
