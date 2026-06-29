#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

# ponytail: module-level constants; override via env before sourcing in tests
WARDEN_POLL_INTERVAL_S="${WARDEN_POLL_INTERVAL_S:-2}"
WARDEN_POLL_MAX_RETRIES="${WARDEN_POLL_MAX_RETRIES:-30}"

## resolveContainerName: the name a service's container runs under —
## its `container_name` if set, else `<WARDEN_ENV_NAME>-<svc>`. Single source of
## truth shared by run (translateService), readiness (orchestrateEnvUp) and stop
## (orchestrateSvcDown) so the three paths cannot drift.
function resolveContainerName {
  local compose_json="$1" svc="$2" cn
  cn="$(jq -r --arg svc "$svc" '.services[$svc].container_name // empty' <<< "$compose_json")"
  echo "${cn:-${WARDEN_ENV_NAME}-${svc}}"
}

## translateService: given resolved-config JSON and a service name, build and
## execute a `container run` invocation.
##
## Field mapping (PRD-1 table):
##   image        → positional image arg (required; fatal if absent)
##   name         → --name from resolveContainerName: the service's container_name
##                  if set, else "${WARDEN_ENV_NAME}-<name>"
##   environment  → repeated -e KEY=VAL (handles both list and map forms)
##   volumes      → -v src:dst (object form: source:target; string form: strip :cached)
##   command/entrypoint → appended after image if present
##   hostname, userns_mode, labels, networks, extra_hosts → silently dropped
##     (apple/container 1.0.0 has no --hostname; container DNS/hostname is PRD-2)
##
## Deps: WARDEN_ENV_NAME in scope; `container` and `jq` on PATH.
function translateService {
  local compose_json="$1"
  local svc="$2"

  # image is required
  local image
  if ! image="$(jq -re --arg svc "$svc" '.services[$svc].image // empty' <<< "$compose_json")"; then
    fatal "service '${svc}': missing required 'image' field"
  fi

  local argv=(--name "$(resolveContainerName "$compose_json" "$svc")")

  # environment: handle both list form ["KEY=VAL"] and map form {KEY: VAL}
  # ponytail: single jq pass covers both forms via type check
  # Collect into env_pairs first; SSH_AUTH_SOCK is dropped below if --ssh is emitted
  local -a env_pairs=()
  while IFS= read -r pair; do
    [[ -n "$pair" ]] && env_pairs+=("$pair")
  done < <(jq -r --arg svc "$svc" '
    .services[$svc].environment // empty |
    if type == "array" then .[]
    else to_entries[] | "\(.key)=\(.value)"
    end
  ' <<< "$compose_json" 2>/dev/null || true)

  # volumes: object form {type,source,target} or string form "src:dst[:opts]"
  # ponytail: sub() strips :cached from string form; object form naturally drops bind options.
  # SSH agent socket (story 10): /run/host-services/ssh-auth.sock is Docker-Desktop's socket;
  # apple/container uses --ssh (verified: `container run --help` line: "--ssh  Forward SSH agent
  # socket to container"). Detect it by source path, skip the -v entry, emit --ssh instead.
  local ssh_flag=0
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    if [[ "$vol" == /run/host-services/ssh-auth.sock:* ]]; then
      ssh_flag=1
    else
      argv+=(-v "$vol")
    fi
  done < <(jq -r --arg svc "$svc" '
    .services[$svc].volumes[]? |
    if type == "string" then
      sub(":cached$"; "")
    else
      "\(.source):\(.target)"
    end
  ' <<< "$compose_json" 2>/dev/null || true)

  # Add env pairs to argv; when --ssh is being emitted, drop SSH_AUTH_SOCK so the
  # runtime's auto-set value (/var/host-services/ssh-auth.sock) takes effect.
  local pair
  for pair in "${env_pairs[@]+"${env_pairs[@]}"}"; do
    if [[ "${ssh_flag}" -eq 1 && "$pair" == SSH_AUTH_SOCK=* ]]; then
      continue  # ponytail: runtime sets the correct value; stale compose value would override it
    fi
    argv+=(-e "$pair")
  done

  [[ "${ssh_flag}" -eq 1 ]] && argv+=(--ssh)

  # command/entrypoint appended after image if present (optional)
  local extra=()
  while IFS= read -r word; do
    [[ -n "$word" ]] && extra+=("$word")
  done < <(jq -r --arg svc "$svc" '
    .services[$svc] |
    ((.entrypoint // empty | if type == "array" then .[] else . end),
     (.command    // empty | if type == "array" then .[] else . end))
  ' <<< "$compose_json" 2>/dev/null || true)

  # Container runtime: inject custom DNS for php-fpm/php-debug so bare backend hostnames
  # (db, redis, …) resolve via dnsmasq per-project addn-hosts records.
  # ponytail: hardcoded service names; generalise to dns:/dns_search: compose keys if more services need it.
  if [[ "${WARDEN_CONTAINER_RUNTIME:-}" == "container" ]] \
     && [[ "$svc" == "php-fpm" || "$svc" == "php-debug" ]] \
     && [[ -n "${WARDEN_DNSMASQ_IP:-}" ]]; then
    argv+=(--dns "${WARDEN_DNSMASQ_IP}" --dns-search "${WARDEN_ENV_NAME}.test")
  fi

  # Log full argv to stderr before execution (story 20)
  >&2 echo "[warden] container run --detach ${argv[*]} ${image}${extra[*]:+ ${extra[*]}}"

  container run --detach "${argv[@]}" "$image" "${extra[@]+"${extra[@]}"}"
}

## topoSortServices: emit service names in topological start order from depends_on.
## Input: resolved-config JSON (from docker compose config --format json).
## Output: one service name per line; db before php-fpm before nginx for the core stack.
## A dependency cycle → fatal.
##
## ponytail: Kahn's algorithm; O(n²) index scan is fine — service count < 20.
##   Bash 3.2 compatible (no associative arrays).
function topoSortServices {
  local compose_json="$1"

  # Extract service names (jq returns alphabetical order; constraints determine real order)
  local -a svcs=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && svcs+=("$s")
  done < <(jq -r '.services | keys[]' <<< "$compose_json")

  local n="${#svcs[@]}"

  # indegree[i] = number of unresolved dependencies for svcs[i]
  # adj[i]      = space-separated indices of services that depend on svcs[i]
  local -a indegree=() adj=()
  local i j
  for (( i=0; i<n; i++ )); do
    indegree[i]=0
    adj[i]=""
  done

  for (( i=0; i<n; i++ )); do
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      # linear scan to find dep's index (n is small)
      for (( j=0; j<n; j++ )); do
        if [[ "${svcs[j]}" == "$dep" ]]; then
          indegree[i]=$(( indegree[i] + 1 ))
          adj[j]="${adj[j]} ${i}"
          break
        fi
      done
    done < <(jq -r --arg s "${svcs[i]}" \
      '.services[$s].depends_on // {} | keys[]' <<< "$compose_json")
  done

  # Kahn's algorithm: queue of zero-indegree node indices
  local -a queue=() result=()
  for (( i=0; i<n; i++ )); do
    [[ "${indegree[i]}" -eq 0 ]] && queue+=("$i")
  done

  while [[ "${#queue[@]}" -gt 0 ]]; do
    local idx="${queue[0]}"
    queue=("${queue[@]:1}")
    result+=("${svcs[idx]}")
    # shellcheck disable=SC2206
    local -a nxs=( ${adj[idx]:-} )
    local nx
    for nx in "${nxs[@]+"${nxs[@]}"}"; do
      [[ -z "$nx" ]] && continue
      indegree[nx]=$(( indegree[nx] - 1 ))
      [[ "${indegree[nx]}" -eq 0 ]] && queue+=("$nx")
    done
  done

  if [[ "${#result[@]}" -ne "${n}" ]]; then
    fatal "dependency cycle detected in service graph"
  fi

  printf '%s\n' "${result[@]}"
}

## waitForRunning: poll `container inspect <name>` until .[0].status.state == "running".
## Constants WARDEN_POLL_INTERVAL_S and WARDEN_POLL_MAX_RETRIES may be overridden
## (set them before sourcing this file in tests).
## On timeout → fatal with container name and retry count.
##
## Real shape verified on apple/container 1.0.0:
##   container inspect <name> → JSON array; running state at .[0].status.state
function waitForRunning {
  local name="$1"
  local attempt=0
  local state

  while [[ "${attempt}" -lt "${WARDEN_POLL_MAX_RETRIES}" ]]; do
    state="$(container inspect "${name}" 2>/dev/null | jq -r '.[0].status.state // empty')"
    if [[ "${state}" == "running" ]]; then
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${WARDEN_POLL_INTERVAL_S}"
  done

  fatal "container '${name}' did not reach running state after ${WARDEN_POLL_MAX_RETRIES} retries"
}

## reloadDnsmasq: send SIGHUP to the running dnsmasq container so it re-reads
## all addn-hosts files. Shared by writeEnvDnsRecords (env up) and
## orchestrateEnvDown (env down) so the signal path cannot drift.
function reloadDnsmasq {
  >&2 echo "[warden] dnsmasq: reloading (${WARDEN_ENV_NAME})"
  # shellcheck disable=SC2016  # single quotes intentional: $(pidof dnsmasq) expands inside container sh
  container exec dnsmasq sh -c 'kill -HUP $(pidof dnsmasq)' 2>/dev/null || \
    warning "dnsmasq SIGHUP failed — DNS records may not be active"
}

## writeEnvDnsRecords: write per-project addn-hosts file to ~/.warden/dnsmasq.d/<env>.hosts
## and signal dnsmasq to reload (SIGHUP re-reads all addn-hosts on the running instance).
##
## Format: standard /etc/hosts — "<ip>\t<svc>.<env>.test" — one line per compose service.
## Truncates on each env up; a stale file between runs is harmless (records are overwritten).
## Reuses resolveContainerName so run/readiness/dns paths cannot drift.
function writeEnvDnsRecords {
  local compose_json="$1"
  local hosts_file="${WARDEN_HOME_DIR}/dnsmasq.d/${WARDEN_ENV_NAME}.hosts"
  local svc name ip

  mkdir -p "${WARDEN_HOME_DIR}/dnsmasq.d"
  : > "${hosts_file}"  # truncate

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    name="$(resolveContainerName "$compose_json" "$svc")"
    # ponytail: inspect schema unverified — try both candidate shapes; cut strips /CIDR.
    ip="$(container inspect "${name}" 2>/dev/null \
        | jq -r '(.[0].status.networks[0].ipv4Address // .[0].networks[0].address // empty)' 2>/dev/null | cut -d/ -f1 || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\t%s.%s.test\n' "$ip" "$svc" "${WARDEN_ENV_NAME}" >> "${hosts_file}"
    else
      warning "dnsmasq: no IP for '${name}' — DNS record for ${svc}.${WARDEN_ENV_NAME}.test will be missing"
    fi
  done < <(jq -r '.services | keys[]' <<< "$compose_json")

  reloadDnsmasq
}

## orchestrateEnvUp: render the assembled DOCKER_COMPOSE_ARGS partial list to flat
## JSON via docker compose config, pre-create named volumes, then translate+run each
## service in topological order, waiting for each to reach running state.
##
## Deps (must be in scope when called from env.cmd or svc.cmd):
##   DOCKER_COMPOSE_ARGS  — assembled -f <file> array
##   WARDEN_ENV_PATH      — project root
##   WARDEN_ENV_NAME      — compose project name
function orchestrateEnvUp {
  local compose_json
  # ponytail: docker compose config --format json resolves YAML anchors, merge keys,
  # and shell-var interpolation; bash+jq receives flat concrete JSON — no YAML parser needed.
  if ! compose_json="$(docker compose \
      --project-directory "${WARDEN_ENV_PATH}" -p "${WARDEN_ENV_NAME}" \
      "${DOCKER_COMPOSE_ARGS[@]}" config --format json)"; then
    fatal "compose config failed — verify compose partials and environment variables"
  fi
  if [[ -z "${compose_json}" ]]; then
    fatal "compose config returned empty output"
  fi

  # Pre-create all top-level named volumes (idempotent; suppress already-exists error)
  while IFS= read -r volname; do
    [[ -n "$volname" ]] && container volume create "${volname}" 2>/dev/null || true
  done < <(jq -r '.volumes // {} | keys[]' <<< "$compose_json" 2>/dev/null || true)

  # Start services in topological order; wait for each before proceeding to the next
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    translateService "$compose_json" "$svc"
    waitForRunning "$(resolveContainerName "$compose_json" "$svc")"
  done < <(topoSortServices "$compose_json")

  # Container runtime: write per-project dnsmasq A-records now that all containers have IPs
  if [[ "${WARDEN_CONTAINER_RUNTIME:-}" == "container" ]]; then
    writeEnvDnsRecords "$compose_json"
  fi
}

## orchestrateSvcDown: stop exactly the services `svc up` started. Enumerates from
## the SAME rendered compose config orchestrateEnvUp uses, so dnsmasq (always present)
## and any optional services (portainer, phpmyadmin) are covered automatically and the
## up/down paths cannot drift. No network deletion — the default network cannot be
## deleted (D-2.1 option a; command-reference.md preserves default/system networks).
##
## Deps (set by svc.cmd or env.cmd): DOCKER_COMPOSE_ARGS, WARDEN_ENV_PATH, WARDEN_ENV_NAME.
function orchestrateSvcDown {
  local compose_json
  if ! compose_json="$(docker compose \
      --project-directory "${WARDEN_ENV_PATH}" -p "${WARDEN_ENV_NAME}" \
      "${DOCKER_COMPOSE_ARGS[@]}" config --format json)"; then
    fatal "compose config failed — verify compose partials and environment variables"
  fi
  if [[ -z "${compose_json}" ]]; then
    fatal "compose config returned empty output"
  fi

  local svc name
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    name="$(resolveContainerName "$compose_json" "$svc")"
    >&2 echo "[warden] container stop ${name}"
    container stop "${name}" 2>/dev/null || true
  done < <(jq -r '.services | keys[]' <<< "$compose_json")
}

## orchestrateEnvDown: stop the project's containers and clean up per-project
## dnsmasq A-records. The default network is never deleted (D-2.1 option a —
## command-reference.md preserves default/system networks).
##
## Reuses orchestrateSvcDown for the stop loop — DOCKER_COMPOSE_ARGS /
## WARDEN_ENV_PATH / WARDEN_ENV_NAME are already scoped to the project when
## called from env.cmd, so the right containers are stopped without duplicating
## the render→stop logic.
## ponytail: calls orchestrateSvcDown in project scope; factor stopComposeServices
##   only if svc/env stop paths diverge in future behaviour.
##
## Deps (set by env.cmd): DOCKER_COMPOSE_ARGS, WARDEN_ENV_PATH, WARDEN_ENV_NAME,
##   WARDEN_HOME_DIR.
function orchestrateEnvDown {
  orchestrateSvcDown

  local hosts_file="${WARDEN_HOME_DIR}/dnsmasq.d/${WARDEN_ENV_NAME}.hosts"
  rm -f "${hosts_file}"
  reloadDnsmasq
}
