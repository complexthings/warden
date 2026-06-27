#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

# ponytail: module-level constants; override via env before sourcing in tests
WARDEN_POLL_INTERVAL_S="${WARDEN_POLL_INTERVAL_S:-2}"
WARDEN_POLL_MAX_RETRIES="${WARDEN_POLL_MAX_RETRIES:-30}"

## translateService: given resolved-config JSON and a service name, build and
## execute a `container run` invocation.
##
## Field mapping (PRD-1 table):
##   image        → positional image arg (required; fatal if absent)
##   service name → --name "${WARDEN_ENV_NAME}-<name>"
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

    local argv=(--name "${WARDEN_ENV_NAME}-${svc}")

    # environment: handle both list form ["KEY=VAL"] and map form {KEY: VAL}
    # ponytail: single jq pass covers both forms via type check
    while IFS= read -r pair; do
        [[ -n "$pair" ]] && argv+=(-e "$pair")
    done < <(jq -r --arg svc "$svc" '
        .services[$svc].environment // empty |
        if type == "array" then .[]
        else to_entries[] | "\(.key)=\(.value)"
        end
    ' <<< "$compose_json" 2>/dev/null || true)

    # volumes: object form {type,source,target} or string form "src:dst[:opts]"
    # ponytail: sub() strips :cached from string form; object form naturally drops bind options
    while IFS= read -r vol; do
        [[ -n "$vol" ]] && argv+=(-v "$vol")
    done < <(jq -r --arg svc "$svc" '
        .services[$svc].volumes[]? |
        if type == "string" then
            sub(":cached$"; "")
        else
            "\(.source):\(.target)"
        end
    ' <<< "$compose_json" 2>/dev/null || true)

    # command/entrypoint appended after image if present (optional)
    local extra=()
    while IFS= read -r word; do
        [[ -n "$word" ]] && extra+=("$word")
    done < <(jq -r --arg svc "$svc" '
        .services[$svc] |
        ((.entrypoint // empty | if type == "array" then .[] else . end),
         (.command    // empty | if type == "array" then .[] else . end))
    ' <<< "$compose_json" 2>/dev/null || true)

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

## orchestrateEnvUp: render the assembled DOCKER_COMPOSE_ARGS partial list to flat
## JSON via docker compose config, pre-create named volumes, then translate+run each
## service in topological order, waiting for each to reach running state.
##
## Deps (must be in scope when called from env.cmd):
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
        waitForRunning "${WARDEN_ENV_NAME}-${svc}"
    done < <(topoSortServices "$compose_json")
}
