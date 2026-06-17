#!/usr/bin/env bats
# Behavioural tests for the muster dispatcher (no substrate required).

setup() {
  MUSTER="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/muster"
}

@test "version prints the tool version" {
  run "$MUSTER" version
  [ "$status" -eq 0 ]
  [[ "$output" == muster\ * ]]
}

@test "help exits zero and lists commands" {
  run "$MUSTER" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commands:"* ]]
}

@test "no command defaults to help" {
  run "$MUSTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown command exits 2" {
  run "$MUSTER" bogus
  [ "$status" -eq 2 ]
}

@test "unknown flag is rejected" {
  run "$MUSTER" up --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "unknown provider is rejected" {
  run "$MUSTER" up --provider potato
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown provider"* ]]
}

@test "unknown --out is rejected" {
  run "$MUSTER" up --out yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown --out"* ]]
}

@test "docker driver is an honest stub" {
  run bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/util.sh"
    . "'"$BATS_TEST_DIRNAME"'/../drivers/docker.sh"
    driver_up
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker driver is not implemented"* ]]
}

@test "up refuses external mode until Phase 3" {
  run "$MUSTER" up --provider k3d --external
  [ "$status" -ne 0 ]
  [[ "$output" == *"external mode is not implemented"* ]]
}

@test "up on the docker provider is an honest stub" {
  run "$MUSTER" up --provider docker
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker driver is not implemented"* ]]
}
