#!/usr/bin/env bats
# Divergence and precedence tests for config + flag resolution.
# Uses the `show` command, which prints resolved settings without a substrate.

setup() {
  MUSTER="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/muster"
  # Run from an isolated dir so a stray ./config.sh never leaks in.
  cd "$BATS_TEST_TMPDIR"
}

field() {
  # field <key> <show-output>
  printf '%s\n' "$2" | grep "^$1=" | cut -d= -f2-
}

@test "defaults when no config and no flags" {
  run "$MUSTER" show
  [ "$status" -eq 0 ]
  [ "$(field provider "$output")" = "k3d" ]
  [ "$(field instance "$output")" = "e2e" ]
  [ "$(field external "$output")" = "false" ]
  [ "$(field version "$output")" = "head" ]
  [ "$(field out "$output")" = "env" ]
  [ "$(field config "$output")" = "<none>" ]
}

@test "flags override every default" {
  run "$MUSTER" show --provider existing --instance lab \
    --external --version 2.10.1 --out json
  [ "$status" -eq 0 ]
  [ "$(field provider "$output")" = "existing" ]
  [ "$(field instance "$output")" = "lab" ]
  [ "$(field external "$output")" = "true" ]
  [ "$(field version "$output")" = "2.10.1" ]
  [ "$(field out "$output")" = "json" ]
}

@test "explicit --config seeds values" {
  cat > cfg.sh <<'EOF'
PROVIDER="existing"
INSTANCE="seeded"
RANCHER_LINE="prime"
OUT="cypress"
EXTERNAL="true"
EOF
  run "$MUSTER" show --config cfg.sh
  [ "$status" -eq 0 ]
  [ "$(field provider "$output")" = "existing" ]
  [ "$(field instance "$output")" = "seeded" ]
  [ "$(field version "$output")" = "prime" ]
  [ "$(field out "$output")" = "cypress" ]
  [ "$(field external "$output")" = "true" ]
}

@test "flags win over config file" {
  cat > cfg.sh <<'EOF'
PROVIDER="existing"
INSTANCE="seeded"
RANCHER_LINE="prime"
OUT="cypress"
EOF
  run "$MUSTER" show --config cfg.sh --provider k3d --version head --out env
  [ "$status" -eq 0 ]
  [ "$(field provider "$output")" = "k3d" ]
  [ "$(field instance "$output")" = "seeded" ]
  [ "$(field version "$output")" = "head" ]
  [ "$(field out "$output")" = "env" ]
}

@test "implicit ./config.sh is discovered" {
  cat > config.sh <<'EOF'
INSTANCE="autoload"
RANCHER_LINE="latest"
EOF
  run "$MUSTER" show
  [ "$status" -eq 0 ]
  [ "$(field instance "$output")" = "autoload" ]
  [ "$(field version "$output")" = "latest" ]
  [ "$(field config "$output")" = "./config.sh" ]
}

@test "explicit --config overrides implicit ./config.sh" {
  cat > config.sh <<'EOF'
INSTANCE="implicit"
EOF
  cat > other.sh <<'EOF'
INSTANCE="explicit"
EOF
  run "$MUSTER" show --config other.sh
  [ "$status" -eq 0 ]
  [ "$(field instance "$output")" = "explicit" ]
}

@test "flag order is irrelevant" {
  run "$MUSTER" show --out json --provider existing --instance x
  [ "$(field provider "$output")" = "existing" ]
  [ "$(field out "$output")" = "json" ]
  [ "$(field instance "$output")" = "x" ]
}

@test "missing --config path is a hard error" {
  run "$MUSTER" show --config /no/such/file.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"config file not readable"* ]]
}

@test "a flag missing its value is rejected" {
  run "$MUSTER" show --provider
  [ "$status" -ne 0 ]
}

@test "--external is idempotent" {
  run "$MUSTER" show --external --external
  [ "$status" -eq 0 ]
  [ "$(field external "$output")" = "true" ]
}

@test "unexpected positional argument is rejected" {
  run "$MUSTER" show stray
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument"* ]]
}
