#!/usr/bin/env bats

# ---------------------------------------------------------------------------
# PRD-2.3 — project containers resolve each other on apple/container network
#            (issue #18): custom DNS via dnsmasq, tracer-bullet slice
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. translateService: php-fpm gets --dns + --dns-search on container runtime
# ---------------------------------------------------------------------------
@test "translateService: php-fpm gets --dns and --dns-search when container runtime + WARDEN_DNSMASQ_IP set" {
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
        WARDEN_CONTAINER_RUNTIME="container" \
        WARDEN_DNSMASQ_IP="192.168.64.5" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json=\"\$(cat '${repo_root}/tests/fixtures/three-svc.json')\"
        translateService \"\$json\" php-fpm
    "
    rm -rf "${fake_bin}"

    # &&-chained: vendored bats enforces only the last command's status, so all
    # discriminators must form a single chain (see existing tests for note).
    [ "$status" -eq 0 ] \
      && [[ "$output" == *"--dns 192.168.64.5"* ]] \
      && [[ "$output" == *"--dns-search testenv.test"* ]]
}

# ---------------------------------------------------------------------------
# 1b. translateService: php-debug also gets --dns + --dns-search on container runtime
# ---------------------------------------------------------------------------
@test "translateService: php-debug gets --dns and --dns-search when container runtime + WARDEN_DNSMASQ_IP set" {
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
        WARDEN_CONTAINER_RUNTIME="container" \
        WARDEN_DNSMASQ_IP="192.168.64.5" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json='{\"services\":{\"php-debug\":{\"image\":\"wardenenv/php-fpm:8.1\"}}}'
        translateService \"\$json\" php-debug
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ] \
      && [[ "$output" == *"--dns 192.168.64.5"* ]] \
      && [[ "$output" == *"--dns-search testenv.test"* ]]
}

# ---------------------------------------------------------------------------
# 2. translateService: nginx does NOT get --dns on container runtime
# ---------------------------------------------------------------------------
@test "translateService: nginx does not get --dns on container runtime" {
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
        WARDEN_CONTAINER_RUNTIME="container" \
        WARDEN_DNSMASQ_IP="192.168.64.5" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json=\"\$(cat '${repo_root}/tests/fixtures/three-svc.json')\"
        translateService \"\$json\" nginx
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ] \
      && [[ "$output" != *"--dns"* ]]
}

# ---------------------------------------------------------------------------
# 3. translateService: php-fpm does NOT get --dns on the docker path
# ---------------------------------------------------------------------------
@test "translateService: php-fpm does not get --dns when WARDEN_CONTAINER_RUNTIME is not container" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"

    cat > "${fake_bin}/container" <<'STUB'
#!/bin/sh
echo "$*"
exit 0
STUB
    chmod +x "${fake_bin}/container"

    # No WARDEN_CONTAINER_RUNTIME=container; WARDEN_DNSMASQ_IP is set to confirm
    # it's the runtime check that guards injection, not the IP presence alone.
    run env WARDEN_DIR="${repo_root}" \
        WARDEN_ENV_NAME="testenv" \
        WARDEN_DNSMASQ_IP="192.168.64.5" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json=\"\$(cat '${repo_root}/tests/fixtures/three-svc.json')\"
        translateService \"\$json\" php-fpm
    "
    rm -rf "${fake_bin}"

    [ "$status" -eq 0 ] \
      && [[ "$output" != *"--dns"* ]]
}

# ---------------------------------------------------------------------------
# 4. writeEnvDnsRecords: writes hosts file entries and signals dnsmasq SIGHUP
# ---------------------------------------------------------------------------
@test "writeEnvDnsRecords: writes <ip>\\t<svc>.<env>.test entries and execs SIGHUP on dnsmasq" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    call_log="${fake_bin}/calls.log"

    # container stub: return CIDR IPs for known names; log all calls for exec check
    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
echo "\$*" >> "${call_log}"
case "\$1 \$2" in
  "inspect testenv-db")      printf '[{"status":{"networks":[{"ipv4Address":"192.168.64.10/24"}]}}]' ;;
  "inspect testenv-php-fpm") printf '[{"status":{"networks":[{"ipv4Address":"192.168.64.11/24"}]}}]' ;;
  *) : ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json='{\"services\":{\"db\":{\"image\":\"mariadb:10.6\"},\"php-fpm\":{\"image\":\"wardenenv/php-fpm:8.1\"}}}'
        writeEnvDnsRecords \"\$json\"
    "
    hosts="$(cat "${home_dir}/dnsmasq.d/testenv.hosts" 2>/dev/null || true)"
    log="$(cat "${call_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}"

    # hosts file must have one entry per service; exec dnsmasq SIGHUP must be called
    [ "$status" -eq 0 ] \
      && [[ "$hosts" == *"192.168.64.10"*"db.testenv.test"* ]] \
      && [[ "$hosts" == *"192.168.64.11"*"php-fpm.testenv.test"* ]] \
      && [[ "$log" == *"exec dnsmasq"* ]]
}

# ---------------------------------------------------------------------------
# 4b. writeEnvDnsRecords: IP extraction works for BOTH candidate inspect schemas.
#     The real apple/container 1.0.0 schema is unverified — the jq fallback must
#     handle .status.networks[].ipv4Address AND top-level .networks[].address.
#     Reducing the fallback to a single path makes this RED.
# ---------------------------------------------------------------------------
@test "writeEnvDnsRecords: extracts bare IP from both inspect schemas (status.networks.ipv4Address and top-level networks.address)" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"

    # db uses the .status.networks[].ipv4Address shape; php-fpm uses the
    # top-level .networks[].address shape. Both must yield bare 192.168.64.x.
    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
case "\$1 \$2" in
  "inspect testenv-db")      printf '[{"status":{"networks":[{"ipv4Address":"192.168.64.20/24"}]}}]' ;;
  "inspect testenv-php-fpm") printf '[{"networks":[{"address":"192.168.64.21/24"}]}]' ;;
  *) : ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/container"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_ENV_NAME="testenv" \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/orchestrate.sh'
        json='{\"services\":{\"db\":{\"image\":\"mariadb:10.6\"},\"php-fpm\":{\"image\":\"wardenenv/php-fpm:8.1\"}}}'
        writeEnvDnsRecords \"\$json\"
    "
    hosts="$(cat "${home_dir}/dnsmasq.d/testenv.hosts" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}"

    # both schemas yield bare IPs; /24 suffix stripped
    [ "$status" -eq 0 ] \
      && [[ "$hosts" == *"192.168.64.20	db.testenv.test"* ]] \
      && [[ "$hosts" == *"192.168.64.21	php-fpm.testenv.test"* ]]
}

# ---------------------------------------------------------------------------
# 5. svc.cmd (container path): dnsmasq.container.yml in compose args
# ---------------------------------------------------------------------------
@test "svc.cmd (container path): dnsmasq.container.yml added to docker compose args" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    docker_log="${fake_bin}/docker.log"
    fixture="${repo_root}/tests/fixtures/svc.json"

    cat > "${fake_bin}/container" <<STUB
#!/bin/sh
case "\$1 \$2" in
  "inspect "*)     printf '[{"status":{"state":"running","networks":[{"ipv4Address":"192.168.64.2/24"}]}}]' ;;
  "system status") echo "status running" ;;
  "system dns")    echo "test" ;;
  "volume "*)      echo "\$*" ;;
  "exec "*)        exit 0 ;;
  *) : ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/container"

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

    touch "${home_dir}/.installed"
    mkdir -p "${home_dir}/ssl/certs"
    touch "${home_dir}/ssl/certs/warden.test.crt.pem"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_SSL_DIR="${home_dir}/ssl" \
        WARDEN_BIN="${fake_bin}/warden" \
        WARDEN_CONTAINER_RUNTIME="container" \
        WARDEN_DNSMASQ_ENABLE="1" \
        DOCKER_COMPOSE_COMMAND="docker compose" \
        WARDEN_POLL_INTERVAL_S=0 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        WARDEN_PARAMS=(up)
        source '${repo_root}/commands/svc.cmd'
    "
    dlog="$(cat "${docker_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}"

    [ "$status" -eq 0 ] \
      && [[ "$dlog" == *"docker-compose.dnsmasq.container.yml"* ]]
}

# ---------------------------------------------------------------------------
# 6. svc.cmd (docker path): dnsmasq.container.yml absent from compose args
# ---------------------------------------------------------------------------
@test "svc.cmd (docker path): dnsmasq.container.yml absent from docker compose args" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    fake_bin="$(mktemp -d)"
    home_dir="$(mktemp -d)"
    docker_log="${fake_bin}/docker.log"

    cat > "${fake_bin}/docker" <<STUB
#!/bin/sh
echo "\$*" >> "${docker_log}"
case "\$1 \$2" in
  "system info") exit 0 ;;
  "network ls")  exit 0 ;;
  *) : ;;
esac
exit 0
STUB
    chmod +x "${fake_bin}/docker"

    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/sudo";   chmod +x "${fake_bin}/sudo"
    printf '#!/bin/sh\nexit 0\n' > "${fake_bin}/warden"; chmod +x "${fake_bin}/warden"

    touch "${home_dir}/.installed"
    mkdir -p "${home_dir}/ssl/certs"
    touch "${home_dir}/ssl/certs/warden.test.crt.pem"

    run env WARDEN_DIR="${repo_root}" \
        WARDEN_HOME_DIR="${home_dir}" \
        WARDEN_SSL_DIR="${home_dir}/ssl" \
        WARDEN_BIN="${fake_bin}/warden" \
        WARDEN_DNSMASQ_ENABLE="1" \
        WARDEN_PHPMYADMIN_ENABLE="0" \
        DOCKER_COMPOSE_COMMAND="docker compose" \
        WARDEN_POLL_INTERVAL_S=0 \
        PATH="${fake_bin}:${PATH}" bash -c "
        source '${repo_root}/utils/core.sh'
        source '${repo_root}/utils/runtime.sh'
        WARDEN_PARAMS=(up)
        source '${repo_root}/commands/svc.cmd'
    "
    dlog="$(cat "${docker_log}" 2>/dev/null || true)"
    rm -rf "${fake_bin}" "${home_dir}"

    # dnsmasq base IS in args; container overlay is NOT
    [ "$status" -eq 0 ] \
      && [[ "$dlog" == *"docker-compose.dnsmasq.yml"* ]] \
      && [[ "$dlog" != *"docker-compose.dnsmasq.container.yml"* ]]
}
