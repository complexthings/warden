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
  :
}

function assertRuntimeVersion {
  :
}

function assertRuntimeRunning {
  :
}
