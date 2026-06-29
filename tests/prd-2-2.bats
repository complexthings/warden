#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-2.2 — svc up/down on the container runtime default network (issue #17)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. translateService: container_name overrides the default <env>-<svc> name
# ---------------------------------------------------------------------------
@test "translateService: container_name field used as --name when present" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="warden" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json='{\"services\":{\"mailpit\":{\"container_name\":\"mailhog\",\"image\":\"axllent/mailpit:latest\"}}}'
        translateService \"\$json\" mailpit
    "
    rm -rf "${fake_bin}"

    # &&-chained: this bats enforces only the LAST command's status, so all
    # discriminators must be one chain (see test 6 note). container_name wins,
    # no <env>-<svc> fallback.
    [ "$status" -eq 0 ] \
      && [[ "$output" == *"--name mailhog"* ]] \
      && [[ "$output" != *"--name warden-mailpit"* ]]
}

# ---------------------------------------------------------------------------
# 2. translateService: no container_name → falls back to <env>-<svc> (regression)
# ---------------------------------------------------------------------------
@test "translateService: falls back to <env>-<svc> when container_name is absent" {
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
        json='{\"services\":{\"nginx\":{\"image\":\"nginx:latest\"}}}'
        translateService \"\$json\" nginx
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ] \
      && [[ "$output" == *"--name testenv-nginx"* ]]
}

# ---------------------------------------------------------------------------
# 3. orchestrateEnvUp with svc fixture: starts containers by container_name;
#    no container network create/delete called
# ---------------------------------------------------------------------------
@test "orchestrateEnvUp (svc fixture): starts traefik tunnel mailhog by container_name; no network create" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"
    fixture="${repo_root}/tests/fixtures/svc.json"

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
        WARDEN_ENV_NAME="warden" \
        WARDEN_POLL_INTERVAL_S=0 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvUp
    "
    log="$(cat "${call_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}"

    # &&-chained (see test 6 note): all three global services started using
    # their container_name values; default network never created/deleted.
    [ "$status" -eq 0 ] \
      && [[ "$log" == *"run --detach --name traefik"* ]] \
      && [[ "$log" == *"run --detach --name tunnel"* ]] \
      && [[ "$log" == *"run --detach --name mailhog"* ]] \
      && [[ "$log" != *"network create"* ]] \
      && [[ "$log" != *"network delete"* ]]
}

# ---------------------------------------------------------------------------
# 4. orchestrateEnvUp (svc): waitForRunning uses container_name, not <env>-<svc>
# ---------------------------------------------------------------------------
@test "orchestrateEnvUp (svc fixture): inspect uses container_name (mailhog not warden-mailpit)" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"
    fixture="${repo_root}/tests/fixtures/svc.json"

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
        WARDEN_ENV_NAME="warden" \
        WARDEN_POLL_INTERVAL_S=0 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateEnvUp
    "
    log="$(cat "${call_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}"

    # &&-chained (see test 6 note): waitForRunning must poll the real
    # container_name, not <env>-<svc>.
    [ "$status" -eq 0 ] \
      && [[ "$log" == *"inspect mailhog"* ]] \
      && [[ "$log" == *"inspect traefik"* ]] \
      && [[ "$log" == *"inspect tunnel"* ]] \
      && [[ "$log" != *"inspect warden-mailpit"* ]] \
      && [[ "$log" != *"inspect warden-traefik"* ]] \
      && [[ "$log" != *"inspect warden-tunnel"* ]]
}

# ---------------------------------------------------------------------------
# 5. orchestrateSvcDown: stops the FULL rendered svc set (incl. dnsmasq +
#    optional phpmyadmin), not just the 3 peered names; no network delete
# ---------------------------------------------------------------------------
@test "orchestrateSvcDown: stops full rendered set incl dnsmasq + phpmyadmin; no container network delete" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"
    fixture="${repo_root}/tests/fixtures/svc.json"

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
        WARDEN_ENV_PATH="/tmp" \
        WARDEN_ENV_NAME="warden" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        DOCKER_COMPOSE_ARGS=()
        orchestrateSvcDown
    "
    log="$(cat "${call_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}"

    # &&-chained (see test 6 note): the dnsmasq/phpmyadmin checks are the whole
    # point of this test, so they must be enforced, not just the last line.
    [ "$status" -eq 0 ] \
      && [[ "$log" == *"stop traefik"* ]] \
      && [[ "$log" == *"stop tunnel"* ]] \
      && [[ "$log" == *"stop mailhog"* ]] \
      && [[ "$log" == *"stop warden-dnsmasq"* ]] \
      && [[ "$log" == *"stop warden-phpmyadmin"* ]] \
      && [[ "$log" != *"network delete"* ]] \
      && [[ "$log" != *"network create"* ]]
}

# ---------------------------------------------------------------------------
# 6. Integration: 'svc up' driven through commands/svc.cmd on the container path
#    exercises the `return 0` bypass — no docker-compose passthrough, no peering
#    loop — while still starting global services via `container run`.
#
# This is the only test that drives the real svc.cmd seam. Removing the
# `return 0` at svc.cmd:132 (the bypass) makes this test fail: the docker-compose
# `up -d` passthrough and the `docker network ls` peering loop would then run.
#
# Limitation: we source svc.cmd (it uses `return`, so it cannot be exec'd) with the
# real preamble stubbed minimally — sudo is a no-op, container/docker/$WARDEN_BIN are
# fakes, and WARDEN_HOME_DIR/.installed is pre-seeded so `warden install` is skipped.
# ---------------------------------------------------------------------------
@test "svc.cmd (container path): 'up' bypasses compose passthrough + peering loop; runs containers" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    container_log="${fake_bin}/container.log"
    docker_log="${fake_bin}/docker.log"
    fixture="${repo_root}/tests/fixtures/svc.json"

    # container stub: log calls; satisfy readiness, runtime status, dns ls
    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${container_log}"
case "\$1 \$2" in
  "inspect "*)        printf '[{"status":{"state":"running"}}]' ;;
  "system status")    echo "status running" ;;
  "system dns")       echo "test" ;;   # dns ls → already configured
  *) : ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/container"

    # docker stub: log calls; 'compose ... config' → svc fixture;
    # 'network ls' → a fake network name so a broken bypass would actually drive
    # the peering loop into connectPeeredServices (printing "Connecting").
    cat > "${fake_bin}/docker" <<STUB
#!/bin/sh
echo "\$*" >> "${docker_log}"
case "\$1 \$2" in
  "network ls") echo "someproject_default"; exit 0 ;;
esac
for arg; do
    if [ "\$arg" = "config" ]; then
        cat "${fixture}"
        exit 0
    fi
done
exit 0
STUB
    chmod +x "${fake_bin}/docker"

    # sudo + $WARDEN_BIN stubs: swallow privileged/sub-warden calls in the preamble
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/sudo";   chmod +x "${fake_bin}/sudo"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/warden"; chmod +x "${fake_bin}/warden"

    # pre-seed install marker (newer than bin/warden) + ssl cert so the preamble
    # skips `warden install` and `sign-certificate`
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
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        WARDEN_PARAMS=(up)
        source '${repo_root}/commands/svc.cmd'
    "
    clog="$(cat "${container_log}" 2>/dev/null || true)"
    dlog="$(cat "${docker_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}"

    [ "$status" -eq 0 ]

    # NOTE: this vendored bats fails a test only on its LAST command's status
    # (mid-body `[[ ]]` failures don't abort — matching the repo's existing style).
    # So every discriminating check is &&-chained into the single final command;
    # any one failing makes the whole test RED. Removing svc.cmd's `return 0`
    # bypass flips (b)/(a) and this goes RED, as verified.
    [[ "$clog" == *"run --detach"* ]] \
      && [[ "$clog" == *"--name traefik"* ]] \
      && [[ "$dlog" == *"config"* ]] \
      && [[ "$dlog" != *"up -d"* ]] \
      && [[ "$dlog" != *"network ls"* ]] \
      && [[ "$output" != *"Connecting"* ]]
}
