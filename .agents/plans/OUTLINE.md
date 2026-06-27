# Warden on apple/container: Gap-Map & Required Changes (Exploratory Outline)

**Purpose:** Map every Docker dependency in warden against apple/container's documented capabilities,
record the change each dependency requires, and flag OPEN QUESTIONs wherever the docs are silent.
This is NOT a committed orchestration design — it is the input to that design conversation.
macOS-only path; Docker path on Linux and Intel Macs is untouched.

**Resolved since v1:** Research pass complete; 19 OQs have verdicts.
**v2 — empirical (2026-06-27, on macOS 26.6 + apple/container 1.0.0, real hardware):** both former blockers were tested directly. **OQ-6 is FALSE** (warden's `/etc/resolver/test` DNS pattern works on macOS 26.6). **OQ-17 has a confirmed runtime workaround** (privileged `sysctl -w`). **0 hard blockers remain.** apple/container is now **1.0.0**, not pre-1.0. See §8 for the full status table.

---

## Prerequisites & Assumptions

- **Hard floor:** macOS 26+ on Apple silicon (arm64) only.
  - apple/container inter-container networking explicitly broken on macOS 15 (research-apple-container.md:116–117, citing start-here.md).
  - Intel / older macOS remain on Docker Desktop; this path is strictly arm64 + macOS 26+.
- **apple/container stability:** **1.0.0 is released** (verified installed: `container CLI version 1.0.0`). The earlier pre-1.0 churn caveat no longer applies; still a young runtime — pin versions and re-test on upgrades.
- **OQ-6 / DNS on macOS 26 — RESOLVED (verified FALSE, 2026-06-27 on macOS 26.6):** A unicast responder on `127.0.0.1:53` received `*.warden.test` system-resolver queries, which resolved to 127.0.0.1; a `.example` control with no resolver entry did not reach it. `/etc/resolver/test` **is honored** (registered as `scutil` resolver #8); mDNSResponder does **not** hijack multi-label `.test` names. The community-gist claim does not hold for warden's case on 26.6 — warden's dnsmasq + `/etc/resolver/test` DNS pattern works with no change. (Caveat: re-test if Apple alters mDNSResponder in later builds.) See §2.
- **Scope:** This outline covers `bin/warden`, `utils/`, `commands/`, and `environments/` in the warden CLI repo only. The warden/images repo is covered under §7 (Images). The docs (wardenenv/docs) assume Docker Desktop throughout; docs updates are out of scope here.
- **Orchestration design decided:** §1 records the decision — an external helper binary.

---

## §1 — The Core Gap: No docker-compose

### What compose layering does today
- `utils/env.sh:164-193` — `appendEnvPartialIfExists` assembles a `DOCKER_COMPOSE_ARGS` list of `-f <file>` pairs across **6 base paths × 3 suffixes** (`.base.yml`, `.${darwin|linux}.yml`, `.mutagen_compose.yml`).
  - ~70 compose partial files across `environments/includes/` and `environments/<type>/`.
  - Caller: `commands/env.cmd` invokes `${DOCKER_COMPOSE_COMMAND} --project-directory <path> -p <env-name> <files> <op>`.
- Every service (php-fpm, nginx, db, redis, varnish, elasticsearch, rabbitmq, blackfire, selenium, ...) is an optional compose partial; enabled via `WARDEN_<NAME>` flag → `appendEnvPartialIfExists` call.
- Override hierarchy: includes → type → `~/.warden/environments` → `<project>/.warden/environments`. Later files win (per-project overrides work via this mechanism).

### What must replace it
- **Required change:** A translation/orchestration layer that reads the same partial YAML files and converts each service definition into `container run` invocations with equivalent flags (`-e`, `-p`, `-v`, `--network`, `--name`, etc.).
- The ~70 partials are the authoritative service definitions; they must drive the new layer — do not diverge them.
- The override hierarchy must be preserved so per-project `.warden/environments/` overrides still work.
- **RESOLVED-BY-DECISION OQ-1:** The compose→container translation layer is an **external helper binary** (Go or Python). It parses the ~70 YAML partials, preserves the 6-layer override hierarchy, emits/executes `container run` invocations, handles startup ordering, and generates the Traefik file-provider config. Warden stays Bash for dispatch; the binary is a new build/distribution dependency (trade-off: warden gains a compiled artifact it must version and ship).
- **RESOLVED-BY-DECISION OQ-2:** `depends_on` / healthcheck startup ordering is the helper binary's responsibility: explicit ordered starts + readiness polling. The binary sequences container starts; warden Bash does not need to know the ordering graph.

---

## §2 — Networking & Peered Services Gap

### What peering does today
- `utils/core.sh:6,46-71` — `connectPeeredServices` / `disconnectPeeredServices`: loops over `docker network connect <projnet> <svc>` for the shared containers (traefik, tunnel, mailhog/mailpit; optionally phpmyadmin).
- `commands/env.cmd:175-182` — project network created by compose first, then `connectPeeredServices` called.
- `commands/svc.cmd:124` — network cleanup by label filter: `docker network ls -f label=`.
- Traefik's Docker provider reads container labels dynamically via the socket (`config/traefik/traefik.yml:7-10`, `network: warden`, `defaultRule: Host(\`{{.Name}}.warden.test\`)`).

### DECISION: Single shared flat `warden` network (driven by OQ-4)
- **RESOLVED-BY-DECISION OQ-4 (RESOLVED: NO):** There is NO `container network connect` command. The apple/container `container network` subcommand offers only: `create`, `delete`/`rm`, `list`/`ls`, `inspect`, `prune`. Network assignment is **creation-time only** via `--network <name>`. Post-start dynamic attachment (the entire basis of `connectPeeredServices`) is not supported. (oq-networking.md, citing command-reference.md + discussion #244)
- **Required change:** All global services (Traefik, tunnel, mailpit) AND all project containers are started with `--network warden` at creation time. The `warden` network is created once at `svc up` (`container network create warden`). There is no per-project network.
- `connectPeeredServices` / `disconnectPeeredServices` (`utils/core.sh:46-71`) are **replaced** by `--network warden` at container creation; these functions are dropped on the apple/container path.
- **Trade-off:** Per-project network isolation is LOST. All environments and global services share one flat network — any container can reach any other by name. Note the security implication for multi-tenant or sensitive workloads.
- Network cleanup (`commands/svc.cmd:124`, label-based `docker network ls -f label=`) → replaced by explicit `container network delete warden`; label-based filtering has no equivalent.

### Reverse-proxy routing: required change
- Replace label-based Traefik Docker provider with **generated static Traefik file-provider configs**.
- On `warden env up`: generate a per-environment `~/.warden/traefik/conf.d/<env-name>.yml` defining routers/services pointing at each container's address/port. Generated by helper binary as part of `env up`.
- On `warden env down`: remove the per-environment file; Traefik hot-reloads via file-provider watch.

### Container IP / DNS
- **PARTIAL OQ-3:** Containers get DHCP-assigned IPs on `192.168.64.0/24`; address is in `container inspect` at `.networks[0].address`. IPs are **unstable across restarts** unless MAC is pinned (`--network default,mac=...`). MAC pinning is not explicitly guaranteed stable per the docs. Required change: re-read IP via `container inspect` on each `env up` (or pin MAC per-container and accept it as a heuristic). Feature request for stable IPs: issue #282. (oq-networking.md)
- **RESOLVED OQ-5 (macOS 26+ only):** Container-to-container DNS works via `<container-name>.test` hostnames on a shared network (macOS 26+). The `.test` suffix is built into the VM's internal resolver scoped to the vmnet. Impossible on macOS 15 — reinforces the hard floor. (oq-networking.md, citing how-to.md + technical-overview.md)
- **RESOLVED OQ-6 (verified FALSE, macOS 26.6, 2026-06-27):** `/etc/resolver/test` is honored on macOS 26 — `*.warden.test` queries route through mDNSResponder to the unicast `127.0.0.1:53` nameserver and resolve correctly. Tested with a logging DNS responder: both `oq6probe.warden.test` and `anything.warden.test` **arrived** at 127.0.0.1:53 and resolved to 127.0.0.1; a `.example` control (no resolver entry) correctly did not. The gist-reported `.test` mDNS hijack does not affect warden's multi-label dev URLs. **No change needed** to warden's DNS approach. (empirical; supersedes the oq-networking.md gist citation)

---

## §3 — Docker Socket Dependencies

### Traefik Docker provider
- `config/traefik/traefik.yml:7-10` — `provider.docker` reads the socket for routing.
- `docker/docker-compose.yml:12` — mounts `${WARDEN_DOCKER_SOCK}:/var/run/docker.sock` into Traefik.
- **Required change:** Switch to file provider (§2); remove socket mount from Traefik service definition.

### Portainer
- `docker/docker-compose.portainer.yml:6` — mounts `/var/run/docker.sock`.
- **RESOLVED-BY-DECISION OQ-7:** Portainer is dropped on the apple/container path. Replace with native `container list` / `container inspect` CLI tooling for any status/discovery needs. No management socket equivalent exists or is expected.

### `docker inspect` / `docker ps` call sites (~28+ sites, 10 files)
Each must be replaced with `container inspect` / `container list` or an equivalent query:

| Call site | Purpose | Required change |
|-----------|---------|-----------------|
| `bin/warden:24` | `which docker` binary check | Check for `container` binary instead |
| `bin/warden:32` | `docker compose version >=2.2.3` | Remove; assert `container --version` instead |
| `utils/core.sh:40` | `docker system info` daemon ping | **RESOLVED OQ-8:** Replace with `container system status` (oq-runtime.md, citing command-reference.md) |
| `utils/core.sh:85-88` | `docker ps/inspect/exec` for phpMyAdmin DB discovery | Replace with `container list/inspect`; syntax likely compatible |
| `commands/status.cmd:7,15,26,31` | project network/container discovery via labels | No label equivalent; must use naming convention or state file instead |
| `commands/db.cmd:23` | `docker container inspect` for DB metadata | `container inspect` — likely compatible |
| `commands/env.cmd:175` | `docker network ls -f name=` (network exists?) | `container network list` — syntax TBD |
| `commands/env.cmd:195` | `docker container inspect traefik` for Traefik IP | **RESOLVED OQ-9:** `container inspect <name> \| jq -r '.networks[0].address'` (CIDR; strip `/24` with `cut -d/ -f1`). No Docker template syntax equivalent; use jq. (oq-networking.md, citing how-to.md + command-reference.md) |
| `commands/env.cmd:242,260` | `docker container inspect` php-fpm running state | `container inspect` — likely compatible |
| `commands/doctor.cmd:86,88` | `docker images --format`, `docker image inspect` | `container image inspect` — likely compatible |
| `commands/debug.cmd:18` | `docker container inspect` debugger container | `container inspect` — likely compatible |
| `commands/svc.cmd:124` | `docker network ls -f label=` project net cleanup | No label filter; name-based or explicit delete instead |

- **Pattern:** Most `inspect` calls are compatible in principle; label-based filtering calls (`-f label=`) have no documented equivalent → must switch to naming conventions.

---

## §4 — Volumes & File Sync

### Bind mounts
- `environments/includes/php-fpm.base.yml:5` — `.${WARDEN_WEB_ROOT}/:/var/www/html:cached`
  - `cached` flag is Docker Desktop / macOS-specific mount option (ignored on Linux).
  - apple/container supports bind mounts via `--volume` / `--mount` (oq-runtime.md, citing command-reference.md + how-to.md); extended mount options (`:cached`, `:delegated`, etc.) are **not documented**.
- **Required change:** Strip `:cached` from bind mounts on the apple/container path (or conditionally omit it).
- **NEEDS-TEST OQ-10:** Run `container run --volume /path:/path:cached alpine` to confirm `:cached` is silently ignored (not an error). (oq-runtime.md)

### SSH agent socket
- `environments/includes/php-fpm.darwin.yml:3` — mounts `/run/host-services/ssh-auth.sock` (Docker Desktop-specific path).
- **RESOLVED OQ-11:** apple/container exposes the host SSH agent via the `--ssh` flag; it mounts `$SSH_AUTH_SOCK` into the container automatically. Issue #1189 (flag not updating on `SSH_AUTH_SOCK` change) was fixed in PR #1420. Required change: replace the host-services socket volume mount with `--ssh` on the apple/container path. (oq-runtime.md, citing issue #1189 + PR #1420)

### Named volumes
- `environments/includes/*.yml` — `bashhistory`, `sshdirectory` named volumes shared across containers.
- **RESOLVED OQ-12:** Named volumes are fully supported via `container volume create <name>` / `--volume <name>:/path`. `bashhistory` and `sshdirectory` port directly. Note: anonymous volumes do NOT auto-cleanup with `--rm`; manual deletion required. (oq-runtime.md, citing command-reference.md)

### Mutagen (DROPPED on apple/container path — Decision 4)
- `utils/env.sh:95-100` — mutagen enabled by default on `darwin*` OSTYPE.
- `utils/env.sh:177-183` — `.mutagen_compose.yml` partials included when `WARDEN_MUTAGEN_ENABLE=1`.
- `commands/env.cmd:203-269` — mutagen sync session lifecycle (pause/resume/stop) around compose up/down.
- **Required change:** On apple/container path: force `WARDEN_MUTAGEN_ENABLE=0`, skip all `.mutagen_compose.yml` partials, skip sync session lifecycle. Use native bind mounts directly.
- **NEEDS-TEST OQ-13:** Measure apple/container native bind-mount I/O performance vs Docker Desktop + Mutagen on a representative Magento 2 workload. (Decision 4 explicitly defers this measurement.)

### User namespace / file ownership
- `commands/env.cmd:30` and `environments/includes/php-fpm.base.yml:32,49` — `userns_mode: ${WARDEN_DOCKER_USERNS_MODE:-host}`.
- **PARTIAL OQ-14:** `--user`/`--uid`/`--gid` flags set container user identity. Per-container-VM isolation makes traditional Linux user namespaces unnecessary (VM-level isolation replaces them), so `userns_mode: host` can be dropped. However, UID/GID remapping for bind mounts (Podman `keep-id` style) is NOT supported; issue #165 open. Required change: drop `userns_mode` key; flag a bind-mount file-ownership caveat to test (container user vs host user file ownership on mounted dirs). (oq-runtime.md, citing command-reference.md + issue #165)

---

## §5 — CLI / Dispatch Changes in warden

### Version assertions & binary checks
- `bin/warden:24` — `which docker` fatal if missing → gate on `which container` instead (on apple/container path).
- `bin/warden:29-36` — `docker compose version` parsed and asserted `>=2.2.3` → remove; assert `container` version instead (version floor TBD).
- **Required change:** Detect runtime path (Docker vs apple/container) and branch accordingly, or introduce a `WARDEN_CONTAINER_RUNTIME` env var to select the backend.

### Daemon check
- `utils/core.sh:40-43` — `docker system info` used to verify daemon is running.
- **Required change:** Replace with `container system status` (RESOLVED OQ-8 — see §3).

### userns_mode
- See PARTIAL OQ-14 in §4 — drop `userns_mode` key on this path; test bind-mount ownership behavior.

### `docker` / `docker compose` invocation sites
- All `${DOCKER_COMPOSE_COMMAND}` invocations in `commands/env.cmd` and `utils/env.sh` → replaced by the new orchestration layer (§1).
- All `docker <subcommand>` calls enumerated in §3 → replaced with `container <subcommand>`.

---

## §6 — Images

### Multi-arch status
- CI builds both `linux/amd64` and `linux/arm64` (research-images-docs.md, `.github/workflows/php.yml:120`).
- Loader images (`php/cli-loaders`, `php/fpm-loaders`) have explicit `TARGETPLATFORM` conditionals for arm64 (Dockerfiles at lines 4, 8-9, 28-29 and 5, 9-10, 29-30 respectively).
- All other ~37 images rely on base image multi-arch support (Official Library images are multi-arch; confirmed for centos, elasticsearch, opensearch).
- **Risk:** Any image pulling an amd64-only base or containing amd64-specific `RUN` directives will fail silently at pull time on apple/container (arm64 VM). No per-image arm64 pass/fail tests evident in CI.
- **NEEDS-TEST OQ-15:** Pull and smoke-run every warden image on arm64 via apple/container to catch silent amd64-only bases. Risk now assessed LOW (most bases are multi-arch), but empirical verification required before declaring images compatible. Recommendation: always use multi-arch tags; audit any pinned old tags. (oq-build-arch.md)

### Build toolchain
- CI uses `docker buildx` + `docker/setup-buildx-action@v4` for cross-arch builds.
- **RESOLVED OQ-16:** `container build` supports Dockerfiles, multi-stage builds, `--build-arg`, and BuildKit. Compatible with `docker buildx build` for arm64-native builds; warden's Dockerfiles contain no BuildKit-exclusive directives (`RUN --mount=type=cache`, etc.) so no Dockerfile changes needed. Can replace `docker buildx build` in CI for arm64-native builds. (oq-build-arch.md, citing command-reference.md)

### No exotic build syntax
- No `RUN --mount=type=cache`, `RUN --security=insecure`, or other BuildKit-exclusive directives detected across 39 Dockerfiles.
- Multi-stage `COPY --from` is standard OCI; expected to work.

### Blackfire
- **RESOLVED OQ-18:** Native arm64 Blackfire agent binary is published (deb/rpm/standalone since January 2021; 5+ years stable). No cross-compilation or amd64 fallback needed. (oq-build-arch.md, citing blog.blackfire.io/arm64-support.html)

### Selenium
- **MOSTLY RESOLVED OQ-19:** Official SeleniumHQ arm64 images (`selenium/standalone-chromium`, `selenium/standalone-firefox`) are available and maintained (4.21.0+). Official Chrome arm64 Linux images became available in Q2 2026. Required change: default Selenium config on this path should use Chromium; update docs to note Chrome is now available. Community `docker-seleniarm` images remain as fallback. (oq-build-arch.md, citing selenium.dev + SeleniumHQ/docker-selenium)

---

## §7 — Critical-Path Service Walkthrough

### php-fpm
- Compose partials: `environments/includes/php-fpm.base.yml`, `.darwin.yml`, `.linux.yml`.
- Changes: bind mount `:cached` stripped (§4, NEEDS-TEST OQ-10); `/run/host-services/ssh-auth.sock` volume replaced by `--ssh` flag (RESOLVED OQ-11); mutagen partials skipped (§4); `userns_mode` key dropped, ownership caveat to test (PARTIAL OQ-14).
- `container run` equivalent: straightforward once orchestration layer translates the YAML.

### nginx
- Compose partial: `environments/includes/nginx.base.yml`.
- Changes: `--network warden` at creation (DECISION, driven by RESOLVED OQ-4); Traefik routing via generated file-provider entry (§2).

### db (MariaDB / MySQL / PostgreSQL)
- Compose partials: `environments/includes/db.base.yml` (and variants).
- `commands/db.cmd:23` uses `docker container inspect` for metadata → replace with `container inspect` (compatible).
- Named volume for data dir: supported, ports directly (RESOLVED OQ-12).
- Cross-container reachability via `--network warden` + `<name>.test` DNS (RESOLVED OQ-5, macOS 26+ only).

### redis
- Compose partial: `environments/includes/redis.base.yml`.
- Simple service; no socket mounts, no special volumes.
- Changes: `--network warden` at creation only. Low risk.

### Traefik (global svc)
- Currently: `docker/docker-compose.yml` defines Traefik; socket mounted; Docker label provider in `config/traefik/traefik.yml:7-10`.
- **Required changes:**
  1. Remove socket mount from Traefik service definition.
  2. Switch `traefik.yml` provider from `docker` to `file` with a watch directory (e.g., `~/.warden/traefik/conf.d/`).
  3. Start Traefik with `--network warden` (DECISION).
  4. Helper binary generates `~/.warden/traefik/conf.d/<env-name>.yml` on `env up`, removes on `env down`.
- IP for each container target: re-read via `container inspect | jq -r '.networks[0].address'` on each `env up` (PARTIAL OQ-3).
- `connectPeeredServices` (utils/core.sh:61,69) — **dropped**; replaced by `--network warden` at creation (DECISION, RESOLVED OQ-4).

### SSH tunnel
- `docker/docker-compose.tunnel.yml` defines the tunnel container; started with `--network warden` (DECISION).
- SSH agent forwarding: `--ssh` flag (RESOLVED OQ-11).

### mailpit
- `docker/docker-compose.mailpit.yml`; started with `--network warden` (DECISION).
- No bind mounts, no socket.
- Changes: Traefik routing via file-provider (§2). Low additional risk.

### Other services (varnish, elasticsearch/opensearch, rabbitmq, blackfire, selenium, phpmyadmin)
- Follow the same compose → `container run` translation pattern as above.
- Portainer: **dropped** on this path (RESOLVED-BY-DECISION OQ-7).
- phpMyAdmin: DB container discovery via `docker ps/inspect` (utils/core.sh:85-88) → `container list/inspect` substitution; `--network warden` for connectivity.
- Per-service notes:
  - **varnish:** No special issues beyond orchestration translation.
  - **elasticsearch/opensearch:** **OQ-17 — workaround VERIFIED (macOS 26.6, apple/container 1.0.0, 2026-06-27).** No `--sysctl` flag exists (`container run` has only `--ulimit` / `--cap-add`); the VM default `vm.max_map_count` = **65530** (< 262144, so ES won't boot by default). BUT a privileged container raises it at runtime: `container run --cap-add ALL ... sysctl -w vm.max_map_count=262144` succeeded (value became 262144). **Required change:** the ES/OpenSearch service runs an entrypoint/init that executes `sysctl -w vm.max_map_count=262144` (with `--cap-add`) before the daemon starts. Each container is its own VM, so this is per-container and safe. (empirical)
  - **rabbitmq:** Standard official image; no special issues expected.
  - **blackfire:** Native arm64 agent available (RESOLVED OQ-18).
  - **selenium:** Use `selenium/standalone-chromium` arm64; Chrome now available (MOSTLY RESOLVED OQ-19).

---

## §8 — Consolidated OPEN QUESTIONS

| # | Status | Answer / What to run | Blocks |
|---|--------|----------------------|--------|
| OQ-1 | RESOLVED-BY-DECISION | External helper binary (Go/Python) owns YAML→container translation, override hierarchy, startup ordering, and Traefik config gen; warden stays Bash. Trade-off: new build/dist dep. | §1, core orchestration |
| OQ-2 | RESOLVED-BY-DECISION | Startup ordering owned by the helper binary: explicit ordered starts + readiness polling. | §1 |
| OQ-3 | PARTIAL | Container IPs on 192.168.64.0/24, DHCP-assigned, unstable across restarts. Required: re-read via `container inspect \| jq -r '.networks[0].address'` on each `env up`, or pin MAC. (oq-networking.md, issue #282) | §2, Traefik |
| OQ-4 | RESOLVED | NO `container network connect`. Network assigned at creation only via `--network`. Drives flat-network DECISION. (oq-networking.md, command-reference.md, discussion #244) | §2, peered services |
| OQ-5 | RESOLVED | `<container-name>.test` DNS works between containers on same user-defined network — macOS 26+ ONLY; impossible on macOS 15. (oq-networking.md, how-to.md) | §2, nginx→php-fpm |
| OQ-6 | RESOLVED | VERIFIED FALSE on macOS 26.6 (2026-06-27): `/etc/resolver/test` honored; `*.warden.test` queries reach 127.0.0.1:53 and resolve. No `.test` mDNS hijack for warden's multi-label URLs; gist claim does not apply. No DNS change needed. (empirical) | §2, DNS / prerequisites |
| OQ-7 | RESOLVED-BY-DECISION | Portainer dropped on this path; use native `container list/inspect` CLI. | §3, Portainer |
| OQ-8 | RESOLVED | `container system status` is the canonical daemon health check. (oq-runtime.md, command-reference.md) | §3, §5 |
| OQ-9 | RESOLVED | `container inspect <name> \| jq -r '.networks[0].address'` → CIDR e.g. "192.168.64.3/24"; strip `/24` with `cut -d/ -f1`. No Docker template syntax equivalent. (oq-networking.md, how-to.md) | §3, env.cmd:195 |
| OQ-10 | NEEDS-TEST | Docs silent on `:cached`. Required test: `container run --volume /path:/path:cached alpine` — confirm silently ignored vs. error. Strip `:cached` on this path regardless. (oq-runtime.md) | §4, php-fpm |
| OQ-11 | RESOLVED | `--ssh` flag forwards host `$SSH_AUTH_SOCK` into container. Replace Docker Desktop socket mount with `--ssh`. Issue #1189 fixed in PR #1420. (oq-runtime.md, command-reference.md) | §4, §7 tunnel |
| OQ-12 | RESOLVED | Named volumes fully supported: `container volume create <name>`. `bashhistory`/`sshdirectory` port directly. Anonymous volumes don't auto-cleanup with `--rm`. (oq-runtime.md, command-reference.md) | §4 |
| OQ-13 | NEEDS-TEST | Measure apple/container native bind-mount I/O vs Docker Desktop + Mutagen on Magento 2 workload. Deferred by decision; run before GA. | §4, file sync |
| OQ-14 | PARTIAL | `--uid`/`--gid` work; `userns_mode` key dropped (VM isolation replaces it). Bind-mount UID remapping NOT supported (issue #165 open). Test file-ownership behavior on bind mounts before shipping. (oq-runtime.md, command-reference.md) | §5, security |
| OQ-15 | NEEDS-TEST | Pull and smoke-run every warden image on arm64. Risk now LOW (most bases multi-arch), but empirical verification required. Use multi-arch tags; audit pinned old tags. (oq-build-arch.md) | §6, images |
| OQ-16 | RESOLVED | `container build` supports Dockerfiles, multi-stage, BuildKit, `--build-arg`. Replaces `docker buildx build` for arm64-native builds. No Dockerfile changes needed (no exotic BuildKit directives in warden images). (oq-build-arch.md, command-reference.md) | §6, CI |
| OQ-17 | RESOLVED (workaround) | VERIFIED on apple/container 1.0.0 (2026-06-27): no `--sysctl` flag; VM default vm.max_map_count=65530 (<262144). Workaround confirmed: privileged `--cap-add ALL` container runs `sysctl -w vm.max_map_count=262144` (succeeded). ES entrypoint must set it before the daemon starts. (empirical) | §7, elasticsearch |
| OQ-18 | RESOLVED | Native arm64 Blackfire agent published (deb/rpm/standalone since Jan 2021). No cross-compile needed. (oq-build-arch.md, blog.blackfire.io) | §7, blackfire |
| OQ-19 | RESOLVED | `selenium/standalone-chromium` + `selenium/standalone-firefox` arm64 available (4.21.0+). Official Chrome arm64 Linux available as of Q2 2026. Use Chromium as default on this path. (oq-build-arch.md, selenium.dev) | §7, selenium |

---

## §9 — PRD Work Breakdown (Slices)

**Rollout model (decided):** all new behavior is gated behind a `WARDEN_CONTAINER_RUNTIME` env var (`docker` default | `container`). Every slice is independently mergeable to `main`; the Docker path is never broken. **Sequencing:** a thin vertical slice (one project loads in a browser) lands early, then breadth widens. **MVP = PRD-0→PRD-3** (one project runs end-to-end); **PRD-4→PRD-7** = parity/breadth/hardening.

### PRD-0 — Runtime backend selection (foundation)
- **Goal:** introduce `WARDEN_CONTAINER_RUNTIME`; branch backend detection; Docker path byte-identical when unset.
- **Scope:** branch `bin/warden:24` (`which container`), `bin/warden:29-36` (drop compose-version assert; assert `container --version`), `utils/core.sh:40` daemon check → `container system status` (RESOLVED OQ-8). No orchestration yet — container path may no-op/error past detection.
- **Exit:** `WARDEN_CONTAINER_RUNTIME=container warden` passes binary/daemon checks; Docker path unchanged.
- **Depends:** none.

### PRD-1 — Orchestrator helper binary (skeleton)
- **Goal:** external Go/Python binary (RESOLVED-BY-DECISION OQ-1) that parses the 6-path × 3-suffix compose layering (`utils/env.sh:164-193`), merges overrides, emits `container run` for the core stack; startup ordering via ordered starts + readiness polling (OQ-2).
- **Scope:** YAML parse + override merge + translate `-e/-p/-v/--name/--network`; binary build/dist. Enough flags for php-fpm/nginx/db only.
- **Exit:** `warden env up` (container path) starts php-fpm+nginx+db containers (no proxy/network polish yet).
- **Depends:** PRD-0.

### PRD-2 — Flat network + DNS + IP discovery
- **Goal:** single shared `warden` network (DECISION, RESOLVED OQ-4 = no post-hoc attach); creation-time `--network warden`; container DNS via `<name>.test` (RESOLVED OQ-5); IP via `container inspect` (PARTIAL OQ-3 / RESOLVED OQ-9).
- **Scope:** `svc up` runs `container network create warden`; replace `connectPeeredServices` (`utils/core.sh:46-71`) with create-time assignment; `svc.cmd:124` cleanup → `container network delete`; MAC pin or inspect-reread for IP stability.
- **Exit:** nginx resolves php-fpm by name; db reachable; host reaches container IPs. **Trade-off accepted:** per-project network isolation dropped.
- **Depends:** PRD-1.

### PRD-3 — Thin vertical slice: project loads in a browser ⭐ (MVP milestone)
- **Goal:** a real PHP/Magento project serves HTTPS at `https://<project>.test` through Traefik on the container path.
- **Scope:** Traefik `docker`→`file` provider; remove socket mount (§3); helper binary generates `~/.warden/traefik/conf.d/<env>.yml` on `env up`, removes on `down`; Traefik started `--network warden`; SSL cert wiring. DNS already works (VERIFIED OQ-6 — no change).
- **Exit:** `WARDEN_CONTAINER_RUNTIME=container warden env up` on a sample project → storefront loads in the browser over HTTPS.
- **Depends:** PRD-2.

### PRD-4 — Volumes, file-sync, SSH agent
- **Goal:** developer-grade mounts.
- **Scope:** strip `:cached` (NEEDS-TEST OQ-10); named volumes via `container volume create` (RESOLVED OQ-12) for `bashhistory`/`sshdirectory`; `--ssh` replaces `/run/host-services/ssh-auth.sock` (RESOLVED OQ-11); drop mutagen (DECISION) + skip `.mutagen_compose.yml`; drop `userns_mode` and verify bind-mount file ownership (PARTIAL OQ-14); measure bind-mount perf (NEEDS-TEST OQ-13).
- **Exit:** edits reflect live; composer/git over SSH agent works; perf measured.
- **Depends:** PRD-3.

### PRD-5 — Images & build verification (arm64) — *parallelizable*
- **Goal:** confirm every image runs arm64; adopt `container build` where useful.
- **Scope:** smoke-pull/run all images on arm64 (NEEDS-TEST OQ-15); `container build` ≈ buildx (RESOLVED OQ-16) → decide CI publish path; arm64 Blackfire agent (RESOLVED OQ-18); Selenium→Chromium (RESOLVED OQ-19).
- **Exit:** arm64 image matrix passes smoke test; build path documented.
- **Depends:** PRD-0 (otherwise independent — can run alongside PRD-3/4).

### PRD-6 — Core-service breadth + inspect call-site port
- **Goal:** remaining services + the `docker inspect`/`ps` call sites.
- **Scope:** port ~28 call sites (§3 table) → `container inspect/list`; label-filter sites → naming conventions (`status.cmd`, `svc.cmd:124`, `env.cmd:195` IP via OQ-9); redis, varnish, rabbitmq, phpMyAdmin DB discovery (`utils/core.sh:85-88`); Portainer dropped (RESOLVED-BY-DECISION OQ-7).
- **Exit:** `doctor`/`status`/`db`/`debug` work on container path; listed optional services boot.
- **Depends:** PRD-3.

### PRD-7 — Elasticsearch/OpenSearch + hardening
- **Goal:** search stack + edge cases → parity for the supported matrix.
- **Scope:** ES/OpenSearch entrypoint sets `vm.max_map_count=262144` via privileged `sysctl -w` (workaround VERIFIED, RESOLVED OQ-17) with `--cap-add`; Selenium arm64 wiring; prerequisite/docs notes (macOS 26+/arm64 floor); optional upstream FR for `--sysctl`.
- **Exit:** Magento catalog search works on container path; supported-matrix parity.
- **Depends:** PRD-6, PRD-4.

### Dependency graph
```
PRD-0 ─┬─ PRD-1 ── PRD-2 ── PRD-3 ⭐ ─┬─ PRD-4 ─┐
       │                             ├─ PRD-6 ──┴─ PRD-7
       └─ PRD-5 (parallel)
```
MVP cutline after PRD-3. Slices ship behind the flag in this order; PRD-5 runs in parallel anytime after PRD-0.

---

## §10 — Out of Scope

- No code changes in this outline. This is research → outline only.
- Linux path: untouched. Docker remains the only runtime on Linux.
- Intel Mac path: untouched. Docker Desktop remains.
- Warden images repo (wardenenv/images) CI pipeline changes deferred until OQ-16 resolved (now: can proceed; see §6).
- Warden docs (wardenenv/docs) update for apple/container prerequisites deferred.
- This outline does not commit to an orchestration design beyond the decisions recorded in §1 and §2.
- OQ-6 (macOS 26 `.test` DNS) was empirically retired — verified working on macOS 26.6; no further action needed beyond re-testing on future macOS builds.
- No timeline, no sprint scope — this is a gap map, not a project plan.
