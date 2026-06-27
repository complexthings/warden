#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

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

## orchestrateEnvUp: render the assembled DOCKER_COMPOSE_ARGS partial list to flat
## JSON via docker compose config, pre-create named volumes, then translate+run each
## service via translateService.
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

    # Translate and run each service (ordering: PRD-1.3+; any order for this slice)
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && translateService "$compose_json" "$svc"
    done < <(jq -r '.services | keys[]' <<< "$compose_json" 2>/dev/null || true)
}
