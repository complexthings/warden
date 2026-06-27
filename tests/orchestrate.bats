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
        PATH="${fake_bin}:/usr/bin:/bin" bash -c "
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
