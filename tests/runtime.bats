#!/usr/bin/env bats

@test "utils/runtime.sh sources without error when WARDEN_DIR is set" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "source '${repo_root}/utils/runtime.sh'"
    [ "$status" -eq 0 ]
}

@test "resolveContainerRuntime: unset WARDEN_CONTAINER_RUNTIME defaults to docker" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "docker" ]
}

@test "resolveContainerRuntime: WARDEN_CONTAINER_RUNTIME=docker resolves to docker" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "docker" ]
}

@test "resolveContainerRuntime: WARDEN_CONTAINER_RUNTIME=container resolves to container" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "container" ]
}

@test "resolveContainerRuntime: value is normalized case-insensitively (Container -> container)" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="Container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "container" ]
}

@test "resolveContainerRuntime: unsupported value calls fatal with accepted values listed" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="podman" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker"* ]]
    [[ "$output" == *"container"* ]]
}

@test "resolveContainerRuntime: explicitly set value overrides unset default" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "container" ]
}
