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

@test "resolveContainerRuntime: project .env beats global .env (honest two-level precedence)" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    global_home="$(mktemp -d)"
    project_dir="$(mktemp -d)"
    echo "WARDEN_CONTAINER_RUNTIME=docker" > "${global_home}/.env"
    echo "WARDEN_CONTAINER_RUNTIME=container" > "${project_dir}/.env"
    run env WARDEN_DIR="${repo_root}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/env.sh'
        source '${repo_root}/utils/runtime.sh'
        unset WARDEN_CONTAINER_RUNTIME
        resolveRuntimeFromFiles '${global_home}' '${project_dir}'
        resolveContainerRuntime
    "
    rm -rf "${global_home}" "${project_dir}"
    [ "$status" -eq 0 ]
    [ "$output" = "container" ]
}

@test "resolveContainerRuntime: global .env used when no project .env" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    global_home="$(mktemp -d)"
    echo "WARDEN_CONTAINER_RUNTIME=container" > "${global_home}/.env"
    run env WARDEN_DIR="${repo_root}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/env.sh'
        source '${repo_root}/utils/runtime.sh'
        unset WARDEN_CONTAINER_RUNTIME
        resolveRuntimeFromFiles '${global_home}' ''
        resolveContainerRuntime
    "
    rm -rf "${global_home}"
    [ "$status" -eq 0 ]
    [ "$output" = "container" ]
}

@test "resolveContainerRuntime: shell export beats both .env files" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    global_home="$(mktemp -d)"
    project_dir="$(mktemp -d)"
    echo "WARDEN_CONTAINER_RUNTIME=docker" > "${global_home}/.env"
    echo "WARDEN_CONTAINER_RUNTIME=docker" > "${project_dir}/.env"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/env.sh'
        source '${repo_root}/utils/runtime.sh'
        _warden_runtime_shell=\"\${WARDEN_CONTAINER_RUNTIME:-}\"
        if [[ -z \"\${_warden_runtime_shell}\" ]]; then
            unset WARDEN_CONTAINER_RUNTIME
            resolveRuntimeFromFiles '${global_home}' '${project_dir}'
        fi
        resolveContainerRuntime
    "
    rm -rf "${global_home}" "${project_dir}"
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

# ---------------------------------------------------------------------------
# PRD-0.4 — container runtime (apple/container) preflight checks
# ---------------------------------------------------------------------------

@test "assertRuntimeInstalled (container): passes when container binary is present" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/container"
    chmod +x "${fake_bin}/container"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeInstalled
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertRuntimeInstalled (container): fatal when container binary is absent" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    empty_bin="$(mktemp -d)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" PATH="${empty_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeInstalled
    "
    rm -rf "${empty_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"container"* ]]
    [[ "$output" == *"could not be found"* ]]
}

@test "assertRuntimeVersion (container): passes when version >= 1.0.0 (at floor)" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
case "$1" in
    --version) echo "container CLI version 1.0.0 (build: release, commit: ee848e3)"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${fake_bin}/container"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeVersion
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertRuntimeVersion (container): fatal when version < 1.0.0" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
case "$1" in
    --version) echo "container CLI version 0.9.0 (build: release, commit: abc1234)"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${fake_bin}/container"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeVersion
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1.0.0"* ]]
    [[ "$output" == *"0.9.0"* ]]
}

@test "assertRuntimeRunning (container): passes when container system status shows running" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
if [ "$1" = "system" ] && [ "$2" = "status" ]; then
    printf "status             running\n"
    exit 0
fi
exit 0
STUB
    chmod +x "${fake_bin}/container"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeRunning
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "assertRuntimeRunning (container): fatal when container system status reports not running" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
if [ "$1" = "system" ] && [ "$2" = "status" ]; then
    echo "apiserver is not running and not registered with launchd"
    exit 1
fi
exit 0
STUB
    chmod +x "${fake_bin}/container"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertRuntimeRunning
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"container"* ]]
    [[ "$output" == *"not running"* ]]
}

# ---------------------------------------------------------------------------
# PRD-0.5 — unported-command guard + active runtime surfacing
# ---------------------------------------------------------------------------

@test "assertCommandSupportedForRuntime (container): unported command fatals naming the command" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertCommandSupportedForRuntime shell
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell"* ]]
}

@test "assertCommandSupportedForRuntime (docker): any command passes silently" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertCommandSupportedForRuntime env
    "
    [ "$status" -eq 0 ]
}

@test "assertCommandSupportedForRuntime (container): allowlisted command (version) passes" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertCommandSupportedForRuntime version
    "
    [ "$status" -eq 0 ]
}

@test "printActiveRuntime: echoes docker label when runtime is docker" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="docker" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        printActiveRuntime
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker"* ]]
}

@test "printActiveRuntime: echoes container label when runtime is container" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        printActiveRuntime
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"container"* ]]
    [[ "$output" == *"apple/container"* ]]
}

# ---------------------------------------------------------------------------
# PRD-2.1 — svc de-guard + DNS host step
# ---------------------------------------------------------------------------

@test "assertCommandSupportedForRuntime (container): svc passes the guard after porting" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" WARDEN_CONTAINER_RUNTIME="container" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        assertCommandSupportedForRuntime svc
    "
    [ "$status" -eq 0 ]
}

@test "installContainerDns (container): calls container system dns create test when resolver absent" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/dns.log"

    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
if [ "\$1" = "system" ] && [ "\$2" = "dns" ] && [ "\$3" = "ls" ]; then
    echo "No DNS resolvers configured"
    exit 0
fi
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_CONTAINER_RUNTIME="container" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/install.sh'
        function sudo { \"\$@\"; }
        installContainerDns
    "
    dns_calls="$(grep -c 'system dns create test' "${call_log}" 2>/dev/null; true)"; dns_calls="${dns_calls:-0}"
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [ "${dns_calls}" -eq 1 ]
}

@test "installContainerDns (container): skips dns create when resolver already configured" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/dns.log"

    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
if [ "\$1" = "system" ] && [ "\$2" = "dns" ] && [ "\$3" = "ls" ]; then
    echo "test    127.0.0.1"
    exit 0
fi
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_CONTAINER_RUNTIME="container" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/install.sh'
        function sudo { \"\$@\"; }
        installContainerDns
    "
    dns_calls="$(grep -c 'system dns create test' "${call_log}" 2>/dev/null; true)"; dns_calls="${dns_calls:-0}"
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [ "${dns_calls}" -eq 0 ]
}

@test "installContainerDns (docker): does not call container system dns create" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/dns.log"

    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_CONTAINER_RUNTIME="docker" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/install.sh'
        installContainerDns
    "
    dns_calls="$(grep -c 'system dns create test' "${call_log}" 2>/dev/null; true)"; dns_calls="${dns_calls:-0}"
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [ "${dns_calls}" -eq 0 ]
}
