#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-1.3 — topoSortServices + waitForRunning
# ---------------------------------------------------------------------------

# Minimal compose JSON with a linear dependency chain: db → php-fpm → nginx
THREE_SVC_JSON='{"services":{"db":{},"php-fpm":{"depends_on":{"db":{}}},"nginx":{"depends_on":{"php-fpm":{}}}},"volumes":{}}'
# Same chain but reversed JSON insertion order (jq always returns alphabetical; constraints win)
THREE_SVC_JSON_REV='{"services":{"nginx":{"depends_on":{"php-fpm":{}}},"php-fpm":{"depends_on":{"db":{}}},"db":{}},"volumes":{}}'

@test "topoSortServices: linear chain yields db php-fpm nginx" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        topoSortServices '${THREE_SVC_JSON}'
    "
    [ "$status" -eq 0 ]
    # Order must be exactly: db, then php-fpm, then nginx (one per line)
    db_line="$(echo "${output}" | grep -n '^db$'     | cut -d: -f1)"
    fp_line="$(echo "${output}" | grep -n '^php-fpm$' | cut -d: -f1)"
    ng_line="$(echo "${output}" | grep -n '^nginx$'   | cut -d: -f1)"
    [[ -n "$db_line" && -n "$fp_line" && -n "$ng_line" ]]
    [ "$db_line" -lt "$fp_line" ]
    [ "$fp_line" -lt "$ng_line" ]
}

@test "topoSortServices: reversed insertion order still yields db php-fpm nginx" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        topoSortServices '${THREE_SVC_JSON_REV}'
    "
    [ "$status" -eq 0 ]
    db_line="$(echo "${output}" | grep -n '^db$'     | cut -d: -f1)"
    fp_line="$(echo "${output}" | grep -n '^php-fpm$' | cut -d: -f1)"
    ng_line="$(echo "${output}" | grep -n '^nginx$'   | cut -d: -f1)"
    [[ -n "$db_line" && -n "$fp_line" && -n "$ng_line" ]]
    [ "$db_line" -lt "$fp_line" ]
    [ "$fp_line" -lt "$ng_line" ]
}

@test "topoSortServices: cycle between two services → fatal" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    cycle_json='{"services":{"a":{"depends_on":{"b":{}}},"b":{"depends_on":{"a":{}}}},"volumes":{}}'
    run env WARDEN_DIR="${repo_root}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        topoSortServices '${cycle_json}'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"cycle"* ]]
}

@test "waitForRunning: non-running twice then running → returns 0" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    count_file="${fake_bin}/count"

    # stub: first 2 calls return stopped; 3rd returns running
    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
count=\$(cat "${count_file}" 2>/dev/null || echo 0)
count=\$(( count + 1 ))
echo "\$count" > "${count_file}"
if [ "\$count" -le 2 ]; then
    printf '[{"status":{"state":"stopped"}}]'
else
    printf '[{"status":{"state":"running"}}]'
fi
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_POLL_INTERVAL_S=0 \
        WARDEN_POLL_MAX_RETRIES=5 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        waitForRunning testenv-db
    "
    rm -rf "${fake_bin}"
    [ "$status" -eq 0 ]
}

@test "waitForRunning: always non-running → fatal with container name in message" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    # stub: always returns stopped
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
printf '[{"status":{"state":"stopped"}}]'
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_POLL_INTERVAL_S=0 \
        WARDEN_POLL_MAX_RETRIES=2 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        waitForRunning testenv-mycontainer
    "
    rm -rf "${fake_bin}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"testenv-mycontainer"* ]]
}

@test "orchestrateEnvUp: db fixture (no depends_on) → one container run, no cycle error" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    fixture="${repo_root}/tests/fixtures/db.json"

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
case "$1" in
  inspect) printf '[{"status":{"state":"running"}}]' ;;
  *)       echo "$*" ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/container"

    cat > "${fake_bin}/docker" <<STUB
#!/bin/sh
for arg; do
    if [ "\$arg" = "config" ]; then
        cat "${fixture}"
        exit 0
    fi
done
exit 0
STUB
    chmod +x "${fake_bin}/docker"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_PATH="/tmp" \
        WARDEN_ENV_NAME="testenv" \
        WARDEN_POLL_INTERVAL_S=0 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvUp
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"run --detach"* ]]
    # exactly one run invocation (db is the only service)
    run_count="$(echo "${output}" | grep -c '^run --detach' || true)"
    [ "${run_count}" -eq 1 ]
}
