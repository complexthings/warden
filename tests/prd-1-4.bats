#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-1.4 — php-fpm + nginx: complete three-service stack (issue #12)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. Three-service orchestration: db → php-fpm → nginx, THREE runs in order
# ---------------------------------------------------------------------------
@test "orchestrateEnvUp: 3-service stack yields three container run calls in order db, php-fpm, nginx" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    fixture="${repo_root}/tests/fixtures/three-svc.json"

    # stub: log every call; inspect returns running immediately
    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
case "$1" in
  inspect) printf '[{"status":{"state":"running"}}]' ;;
  volume)  echo "$*" ;;
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

    # Exactly three 'run --detach' invocations
    run_count="$(echo "${output}" | grep -c '^run --detach' || true)"
    [ "${run_count}" -eq 3 ]

    # Order: db before php-fpm before nginx
    db_line="$(echo "${output}"  | grep -n 'testenv-db'    | grep '^[0-9]*:run' | head -1 | cut -d: -f1)"
    fp_line="$(echo "${output}"  | grep -n 'testenv-php-fpm' | grep '^[0-9]*:run' | head -1 | cut -d: -f1)"
    ng_line="$(echo "${output}"  | grep -n 'testenv-nginx' | grep '^[0-9]*:run' | head -1 | cut -d: -f1)"
    [[ -n "$db_line" && -n "$fp_line" && -n "$ng_line" ]]
    [ "$db_line" -lt "$fp_line" ]
    [ "$fp_line" -lt "$ng_line" ]
}

# ---------------------------------------------------------------------------
# 2. SSH socket volume → --ssh flag; no -v socket path emitted
# ---------------------------------------------------------------------------
@test "translateService: php-fpm with ssh-auth.sock volume → --ssh flag, no -v socket path" {
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
        json=\"\$(cat '${repo_root}/tests/fixtures/three-svc.json')\"
        translateService \"\$json\" php-fpm
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"--ssh"* ]]
    # The -v flag must not carry the ssh socket path (env var SSH_AUTH_SOCK value is fine)
    [[ "$output" != *"-v /run/host-services/ssh-auth.sock"* ]]
}

# ---------------------------------------------------------------------------
# 3. Unknown key cap_add → silently skipped; no fatal; not in argv
# ---------------------------------------------------------------------------
@test "translateService: unknown key cap_add silently skipped — not fatal, not in argv" {
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
        json=\"\$(cat '${repo_root}/tests/fixtures/three-svc.json')\"
        translateService \"\$json\" php-fpm
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" != *"cap_add"* ]]
    [[ "$output" != *"SYS_PTRACE"* ]]
}

# ---------------------------------------------------------------------------
# 4. nginx argv: correct image, --name, bind mount, env var
# ---------------------------------------------------------------------------
@test "translateService: nginx argv correct — name, bind mount, env, image" {
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
        json=\"\$(cat '${repo_root}/tests/fixtures/three-svc.json')\"
        translateService \"\$json\" nginx
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"--name testenv-nginx"* ]]
    [[ "$output" == *"-v /var/www/html:/var/www/html"* ]]
    [[ "$output" == *"-e XDEBUG_CONNECT_BACK_HOST="* ]]
    [[ "$output" == *"docker.io/wardenenv/nginx:1.24"* ]]
    # nginx has no ssh socket; no --ssh
    [[ "$output" != *"--ssh"* ]]
}

# ---------------------------------------------------------------------------
# 5. Readiness: inspect(db) before run(php-fpm); inspect(php-fpm) before run(nginx)
# ---------------------------------------------------------------------------
@test "orchestrateEnvUp: readiness checked for db before php-fpm, php-fpm before nginx" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"
    fixture="${repo_root}/tests/fixtures/three-svc.json"

    # stub: log every call tagged by subcommand; inspect always returns running
    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
case "\$1" in
  inspect) printf '[{"status":{"state":"running"}}]' ;;
  volume)  echo "\$*" ;;
  *)       echo "\$*" ;;
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
    log="$(cat "${call_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ]

    # inspect testenv-db must appear in the log before run ...testenv-php-fpm
    db_inspect_line="$(echo "${log}" | grep -n 'inspect testenv-db' | head -1 | cut -d: -f1)"
    fp_run_line="$(echo "${log}"     | grep -n 'run.*testenv-php-fpm' | head -1 | cut -d: -f1)"
    fp_inspect_line="$(echo "${log}" | grep -n 'inspect testenv-php-fpm' | head -1 | cut -d: -f1)"
    ng_run_line="$(echo "${log}"     | grep -n 'run.*testenv-nginx' | head -1 | cut -d: -f1)"

    [[ -n "$db_inspect_line" && -n "$fp_run_line" ]]
    [[ -n "$fp_inspect_line" && -n "$ng_run_line" ]]
    [ "$db_inspect_line" -lt "$fp_run_line" ]
    [ "$fp_inspect_line" -lt "$ng_run_line" ]
}
