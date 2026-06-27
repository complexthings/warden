#!/usr/bin/env bats

@test "utils/runtime.sh sources without error when WARDEN_DIR is set" {
    repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    run env WARDEN_DIR="${repo_root}" bash -c "source '${repo_root}/utils/runtime.sh'"
    [ "$status" -eq 0 ]
}
