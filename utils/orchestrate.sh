#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

## orchestrateEnvUp: render the assembled DOCKER_COMPOSE_ARGS partial list to flat
## JSON via docker compose config, then validate. Container run translation: PRD-1.2+.
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
    # ponytail: translation logic (container run per service) lands in PRD-1.2+
}
