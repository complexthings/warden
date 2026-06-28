#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-2.4 — env down on container path + TRAEFIK_ADDRESS bypass lock (issue #19)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. orchestrateEnvDown: stops project containers; no network create/delete
# ---------------------------------------------------------------------------
@test "orchestrateEnvDown: stops project containers; no network create/delete" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"
    fixture="${repo_root}/tests/fixtures/three-svc.json"

    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
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
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_ENV_PATH="/tmp" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvDown
    "
    log="$(cat "${call_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}"

    # &&-chained: vendored bats enforces only the last command's status.
    # Three project containers stopped; no network create or delete called.
    [ "$status" -eq 0 ] \
      && [[ "$log" == *"stop testenv-db"* ]] \
      && [[ "$log" == *"stop testenv-nginx"* ]] \
      && [[ "$log" == *"stop testenv-php-fpm"* ]] \
      && [[ "$log" != *"network delete"* ]] \
      && [[ "$log" != *"network create"* ]]
}

# ---------------------------------------------------------------------------
# 2. orchestrateEnvDown: removes dnsmasq hosts file and sends dnsmasq SIGHUP
# ---------------------------------------------------------------------------
@test "orchestrateEnvDown: removes dnsmasq hosts file and sends SIGHUP to dnsmasq" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"
    fixture="${repo_root}/tests/fixtures/three-svc.json"

    # pre-seed the hosts file that env up would have written
    mkdir -p "${home_dir}/dnsmasq.d"
    echo "192.168.64.10	db.testenv.test" > "${home_dir}/dnsmasq.d/testenv.hosts"

    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
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
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_ENV_PATH="/tmp" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvDown
    "
    log="$(cat "${call_log}" 2>/dev/null || true)"
    # capture hosts-gone status before cleanup
    hosts_gone=0
    [[ ! -f "${home_dir}/dnsmasq.d/testenv.hosts" ]] && hosts_gone=1
    rm -rf "${fake_bin}" "${home_dir}"

    # hosts file must be gone; dnsmasq must have received SIGHUP via exec
    [ "$status" -eq 0 ] \
      && [ "$hosts_gone" -eq 1 ] \
      && [[ "$log" == *"exec dnsmasq"* ]]
}

# ---------------------------------------------------------------------------
# 3. TRAEFIK_ADDRESS bypass regression: env.cmd (container path, env down)
#    must not invoke docker container inspect traefik, docker network disconnect,
#    or docker compose down. The early `return 0` in the container block is the
#    guard; this test goes RED if that return is removed.
#
#    Same harness as prd-2-2.bats test 6 but WARDEN_PARAMS=(down).
# ---------------------------------------------------------------------------
@test "env.cmd (container path, down): no docker inspect traefik, no network disconnect, no compose down" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    env_dir="$(mktemp -d)"
    container_log="${fake_bin}/container.log"
    docker_log="${fake_bin}/docker.log"
    fixture="${repo_root}/tests/fixtures/three-svc.json"

    # seed .env so locateEnvPath succeeds; WARDEN_ENV_TYPE=local keeps partial
    # assembly minimal and avoids unexpected appendEnvPartialIfExists paths.
    cat > "${env_dir}/.env" <<'ENV'
WARDEN_ENV_NAME=testenv
WARDEN_ENV_TYPE=local
ENV

    # pre-seed hosts file so orchestrateEnvDown has something to clean up
    mkdir -p "${home_dir}/dnsmasq.d"
    echo "192.168.64.10	db.testenv.test" > "${home_dir}/dnsmasq.d/testenv.hosts"

    # container stub: log calls; satisfy assertRuntimeRunning (system status)
    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${container_log}"
case "\$1 \$2" in
  "system status") echo "status running" ;;
  *) : ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/container"

    # docker stub: log ALL calls; 'compose ... config' → three-svc fixture.
    # If the bypass fails, docker network disconnect and docker container inspect
    # traefik would appear here, making the negative assertions below fail (RED).
    cat > "${fake_bin}/docker" <<STUB
#!/bin/sh
echo "\$*" >> "${docker_log}"
for arg; do
    if [ "\$arg" = "config" ]; then
        cat "${fixture}"
        exit 0
    fi
done
exit 0
STUB
    chmod +x "${fake_bin}/docker"

    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/sudo";   chmod +x "${fake_bin}/sudo"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/warden"; chmod +x "${fake_bin}/warden"

    # pre-seed install marker + ssl cert so preamble skips warden install/sign-certificate
    touch "${home_dir}/.installed"
    mkdir -p "${home_dir}/ssl/certs"
    touch "${home_dir}/ssl/certs/warden.test.crt.pem"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_SSL_DIR="${home_dir}/ssl" \
        WARDEN_BIN="${fake_bin}/warden" \
        WARDEN_CONTAINER_RUNTIME="container" \
        DOCKER_COMPOSE_COMMAND="docker compose" \
        WARDEN_POLL_INTERVAL_S=0 \
        PATH="${fake_bin}:${PATH}" bash -c "
        cd '${env_dir}'
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        source '${repo_root}/utils/env.sh'
        WARDEN_PARAMS=(down)
        source '${repo_root}/commands/env.cmd'
    "
    dlog="$(cat "${docker_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}" "${env_dir}"

    # &&-chained: all negative checks + status must hold.
    # Removing env.cmd's `return 0` from the container block makes this RED:
    # docker network disconnect (disconnectPeeredServices), docker container
    # inspect traefik (TRAEFIK_ADDRESS block), and docker compose down would fire.
    [ "$status" -eq 0 ] \
      && [[ "$dlog" != *"network disconnect"* ]] \
      && [[ "$dlog" != *"inspect traefik"* ]] \
      && [[ "$dlog" != *" down"* ]]
}
