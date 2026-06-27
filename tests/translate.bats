#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-1.2 — translateService: db tracer bullet, field mapping
# ---------------------------------------------------------------------------

# Helper: run translateService in a subshell with a stub container binary.
# Sets repo_root, fake_bin, call_log for each test.
# Callers do:  run _ts_run <json_string_or_fixture_path> <svc>
# But bats `run` wraps the whole test invocation, so we build the bash -c inline.

@test "orchestrateEnvUp: named volumes created before container run" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    fixture="${repo_root}/tests/fixtures/db.json"

    # stub: container echoes its args to stdout (captured by bats in $output)
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    # stub: docker compose config → db fixture
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
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvUp
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"volume create dbdata"* ]]
    [[ "$output" == *"volume create sqlhistory"* ]]
    [[ "$output" == *"run --detach"* ]]

    # volumes must appear before the run line
    vol_line="$(echo "${output}" | grep -n "volume create dbdata" | head -1 | cut -d: -f1)"
    run_line="$(echo "${output}" | grep -n "^run " | head -1 | cut -d: -f1)"
    [ "${vol_line}" -lt "${run_line}" ]
}

@test "translateService: exact container run argv for db fixture (map env form)" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        db_json=\"\$(cat '${repo_root}/tests/fixtures/db.json')\"
        translateService \"\$db_json\" db
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"--detach"* ]]
    [[ "$output" == *"--name testenv-db"* ]]
    # apple/container 1.0.0 has no --hostname flag (verified); it must be dropped, not emitted
    [[ "$output" != *"--hostname"* ]]
    [[ "$output" == *"-e MYSQL_ROOT_PASSWORD=app"* ]]
    [[ "$output" == *"-e MYSQL_DATABASE=app"* ]]
    [[ "$output" == *"-e MYSQL_USER=app"* ]]
    [[ "$output" == *"-e MYSQL_HISTFILE=/sql_history/.sql_history"* ]]
    [[ "$output" == *"-v dbdata:/var/lib/mysql"* ]]
    [[ "$output" == *"-v sqlhistory:/sql_history"* ]]
    [[ "$output" == *"docker.io/wardenenv/mariadb:10.6"* ]]
}

@test "translateService: userns_mode absent from argv; no traefik labels; no --network" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        db_json=\"\$(cat '${repo_root}/tests/fixtures/db.json')\"
        translateService \"\$db_json\" db
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" != *"userns_mode"* ]]
    [[ "$output" != *"--label"* ]]
    [[ "$output" != *"traefik"* ]]
    [[ "$output" != *"--network"* ]]
}

@test "translateService: list-form environment produces identical -e output as map form" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    # ponytail: inline fixture with LIST-form env; only field we need to vary
    list_env_json='{"services":{"db":{"image":"docker.io/wardenenv/mariadb:10.6","hostname":"testenv-mariadb","environment":["MYSQL_ROOT_PASSWORD=app","MYSQL_DATABASE=app","MYSQL_USER=app","MYSQL_HISTFILE=/sql_history/.sql_history"],"volumes":[{"type":"volume","source":"dbdata","target":"/var/lib/mysql"},{"type":"volume","source":"sqlhistory","target":"/sql_history"}]}},"volumes":{"dbdata":{},"sqlhistory":{}}}'

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        translateService '${list_env_json}' db
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"-e MYSQL_ROOT_PASSWORD=app"* ]]
    [[ "$output" == *"-e MYSQL_DATABASE=app"* ]]
    [[ "$output" == *"-e MYSQL_USER=app"* ]]
    [[ "$output" == *"-e MYSQL_HISTFILE=/sql_history/.sql_history"* ]]
}

@test "translateService: bind mount with :cached suffix stripped to -v src:dst" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    # ponytail: string-form volume with :cached — tests the sub() stripping path
    bind_json='{"services":{"app":{"image":"alpine:3","volumes":["/hostpath:/containerpath:cached"]}},"volumes":{}}'

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        translateService '${bind_json}' app
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"-v /hostpath:/containerpath"* ]]
    [[ "$output" != *":cached"* ]]
}

@test "translateService: argv logged to stderr before container is invoked" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "INVOKED: $*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        db_json=\"\$(cat '${repo_root}/tests/fixtures/db.json')\"
        translateService \"\$db_json\" db
    " 2>&1
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    # [warden] log line must appear before the INVOKED: line
    log_line="$(echo "${output}" | grep -n "\[warden\] container run" | head -1 | cut -d: -f1)"
    inv_line="$(echo "${output}" | grep -n "^INVOKED:" | head -1 | cut -d: -f1)"
    [[ -n "$log_line" ]]
    [[ -n "$inv_line" ]]
    [ "${log_line}" -lt "${inv_line}" ]
}
