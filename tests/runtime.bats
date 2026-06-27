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

@test "assertRuntimeInstalled (docker): passes when docker is present" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeInstalled
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertRuntimeInstalled (docker): fatal when docker is absent" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    empty_bin="$(mktemp -d)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" PATH="${empty_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeInstalled
    "
    rm -rf "${empty_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker could not be found; please install and try again."* ]]
}

@test "assertRuntimeVersion (docker): passes when docker compose >= 2.2.3" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/docker" <<'STUB'
#!/bin/sh
case "$*" in
    "compose version") echo "Docker Compose version v2.2.3"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" DOCKER_COMPOSE_COMMAND="docker compose" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeVersion
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertRuntimeVersion (docker): fatal when docker compose < 2.2.3" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/docker" <<'STUB'
#!/bin/sh
case "$*" in
    "compose version") echo "Docker Compose version v2.1.0"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" DOCKER_COMPOSE_COMMAND="docker compose" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeVersion
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker compose version should be 2.2.3 or higher (2.1.0 installed)"* ]]
}

@test "assertRuntimeRunning (docker): passes when docker system info succeeds" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeRunning
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertRuntimeRunning (docker): fatal when docker system info fails" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/docker" <<'STUB'
#!/bin/sh
case "$*" in
    "system info") exit 1 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeRunning
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker does not appear to be running. Please start Docker."* ]]
}

@test "assertDockerRunning delegates to assertRuntimeRunning: passes when running" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertDockerRunning
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertDockerRunning delegates to assertRuntimeRunning: fatal when not running" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    printf '#!/bin/sh\nexit 1\n' > "${fake_bin}/docker"
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertDockerRunning
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker does not appear to be running. Please start Docker."* ]]
}
