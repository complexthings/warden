#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-1.1 — orchestrate.sh: routing + compose config rendering
# ---------------------------------------------------------------------------

@test "utils/orchestrate.sh sources without error when WARDEN_DIR is set" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "source '${repo_root}/utils/orchestrate.sh'"
    [ "$status" -eq 0 ]
}

@test "orchestrateEnvUp: succeeds when docker compose config returns valid JSON" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/docker" <<'STUB'
#!/bin/sh
# stub: docker compose ... config ... → valid JSON
for arg; do
    if [ "$arg" = "config" ]; then
        printf '{"services":{}}'
        exit 0
    fi
done
exit 0
STUB
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_PATH="/tmp" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvUp
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "orchestrateEnvUp: fatals with 'compose config' message when docker compose config exits non-zero" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    cat > "${fake_bin}/docker" <<'STUB'
#!/bin/sh
# stub: docker compose config → failure
for arg; do
    if [ "$arg" = "config" ]; then
        echo "ERROR: service 'broken' is misconfigured" >&2
        exit 1
    fi
done
exit 0
STUB
    chmod +x "${fake_bin}/docker"
    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_PATH="/tmp" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:/usr/bin:/bin" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvUp
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"compose config"* ]]
}

# ---------------------------------------------------------------------------
# Issue #9 AC: docker runtime passthrough — orchestrate routing condition
# ---------------------------------------------------------------------------
# env.cmd's routing guard is: [[ "${WARDEN_CONTAINER_RUNTIME}" == "container" && ... ]]
# On docker runtime (or unset) the condition is false → docker compose passthrough.
# We test the guard condition directly via resolveContainerRuntime, which normalises
# the value. Full env.cmd bootstrap would require a project .env on disk; this seam
# is sufficient to prove the container path is not taken.
# ponytail: limitation — does not exercise env.cmd's exec path, only the resolver that
# feeds the guard. A full integration test would need a real project tree.

@test "docker runtime: resolveContainerRuntime returns 'docker' when WARDEN_CONTAINER_RUNTIME=docker" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" \
        WARDEN_CONTAINER_RUNTIME="docker" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "docker" ]
}

@test "docker runtime: resolveContainerRuntime returns 'docker' when WARDEN_CONTAINER_RUNTIME is unset" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "
        unset WARDEN_CONTAINER_RUNTIME
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        resolveContainerRuntime
    "
    [ "$status" -eq 0 ]
    [ "$output" = "docker" ]
}

@test "docker runtime: orchestrate routing condition is false when WARDEN_CONTAINER_RUNTIME=docker" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # Directly evaluate the env.cmd routing guard; exit 0 = guard is false (docker path taken)
    run env WARDEN_DIR="${repo_root}" \
        WARDEN_CONTAINER_RUNTIME="docker" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        rt=\"\$(resolveContainerRuntime)\"
        # Guard condition from env.cmd: container runtime AND 'up' subcommand
        [[ \"\${rt}\" == 'container' ]] && exit 1 || exit 0
    "
    [ "$status" -eq 0 ]
}
