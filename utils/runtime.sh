#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

## Runtime backend abstraction — stub declarations; logic added in later slices.

# ponytail: empty stubs only; runtime logic lands in PRD-0.2 and later slices

function resolveContainerRuntime {
  local runtime
  runtime="$(echo "${WARDEN_CONTAINER_RUNTIME:-docker}" | tr '[:upper:]' '[:lower:]')"
  case "${runtime}" in
    docker|container) echo "${runtime}" ;;
    *) fatal "WARDEN_CONTAINER_RUNTIME '${WARDEN_CONTAINER_RUNTIME}' is invalid; accepted values: docker, container" ;;
  esac
}

function assertRuntimeInstalled {
  local runtime="${WARDEN_CONTAINER_RUNTIME:-docker}"
  case "${runtime}" in
    docker)
      if ! which docker >/dev/null 2>&1; then
        fatal "docker could not be found; please install and try again."
      fi
      ;;
    container)
      if ! which container >/dev/null 2>&1; then
        fatal "apple/container CLI ('container') could not be found; please install and try again."
      fi
      ;;
  esac
}

function assertRuntimeVersion {
  local runtime="${WARDEN_CONTAINER_RUNTIME:-docker}"
  local dc_cmd="${DOCKER_COMPOSE_COMMAND:-"docker compose"}"
  case "${runtime}" in
    docker)
      if [[ "${dc_cmd}" == "docker compose" ]]; then
        local require="2.2.3"
        local installed
        installed="$(${dc_cmd} version | grep -oE '[0-9\.]+' | head -n1)"
        if ! test "$(version "${installed}")" -ge "$(version "${require}")"; then
          fatal "docker compose version should be ${require} or higher (${installed} installed)"
        fi
      fi
      ;;
    container)
      local require="1.0.0"
      local installed
      installed="$(container --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
      if ! test "$(version "${installed}")" -ge "$(version "${require}")"; then
        fatal "apple/container version should be ${require} or higher (${installed} installed)"
      fi
      ;;
  esac
}

function assertRuntimeRunning {
  local runtime="${WARDEN_CONTAINER_RUNTIME:-docker}"
  case "${runtime}" in
    docker)
      if ! docker system info >/dev/null 2>&1; then
        fatal "Docker does not appear to be running. Please start Docker."
      fi
      ;;
    container)
      local status_out
      # Non-zero exit means the service is not running; also guard against a
      # zero exit with no "status … running" table row (OR condition from spec).
      if ! status_out="$(container system status 2>&1)" || \
         ! echo "${status_out}" | grep -qE '^status[[:space:]]+running'; then
        fatal "apple/container service is not running. Start it with 'container system start'."
      fi
      ;;
  esac
}
