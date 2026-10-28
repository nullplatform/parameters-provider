#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-parameter-store/retrieve_batch
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-parameter-store/retrieve_batch"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$AWS_LOG"
if [ "${MOCK_AWS_MODE:-success}" = "denied" ]; then
  echo "An error occurred (AccessDeniedException) when calling the GetParameters operation." >&2
  exit 254
fi
names=()
collecting=false
for arg in "$@"; do
  if [ "$arg" = "--names" ]; then collecting=true; continue; fi
  [[ "$arg" == --* ]] && collecting=false
  if $collecting; then names+=("$arg"); fi
done
printf '%s\n' "${names[@]}" | jq -R . | jq -s '{
  Parameters: [.[] | select(contains("MISSING") | not) | capture("^(?<n>[^:]+)(?<s>:.*)?$")
    | {Name: .n, Value: ("value-of-" + .n + (.s // ""))} + (if .s then {Selector: .s} else {} end)],
  InvalidParameters: [.[] | select(contains("MISSING"))]
}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/aws"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AWS_REGION="us-east-1"
  export PS_NAME_PREFIX="/nullplatform/"
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

context_with() {
  jq -n --args '{values: [$ARGS.positional[] | {external_id: ., parameter_name: "P", secret: true}]}' "$@"
}

@test "aws-parameter-store retrieve_batch: returns the value of every external id" {
  export CONTEXT="$(context_with "organization=acme-1/app=api-4/DB_HOST-10" "organization=acme-1/app=api-4/DB_PASSWORD-11#3")"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '.values')" '[{"external_id":"organization=acme-1/app=api-4/DB_HOST-10","value":"value-of-/nullplatform/organization_acme-1/app_api-4/DB_HOST-10"},{"external_id":"organization=acme-1/app=api-4/DB_PASSWORD-11#3","value":"value-of-/nullplatform/organization_acme-1/app_api-4/DB_PASSWORD-11:3"}]'
}

@test "aws-parameter-store retrieve_batch: asks for versions with the name:version selector" {
  export CONTEXT="$(context_with "app-1/DB_PASSWORD-11#3" "app-1/DB_HOST-10")"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$(cat "$AWS_LOG")" "--names /nullplatform/app-1/DB_PASSWORD-11:3 /nullplatform/app-1/DB_HOST-10 --with-decryption"
}

@test "aws-parameter-store retrieve_batch: reads up to 10 names per call" {
  ids=()
  for i in $(seq 1 25); do ids+=("app-1/P-$i#1"); done
  export CONTEXT="$(context_with "${ids[@]}")"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(grep -c "get-parameters" "$AWS_LOG")" "3"
  assert_equal "$(echo "$output" | jq '.values | length')" "25"
}

@test "aws-parameter-store retrieve_batch: leaves out values Parameter Store does not have" {
  export CONTEXT="$(context_with "app-1/DB_HOST-10" "app-1/MISSING-12#2")"

  run bash -c "$DEPS; source $SCRIPT 2>/dev/null"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '[.values[].external_id]')" '["app-1/DB_HOST-10"]'
}

@test "aws-parameter-store retrieve_batch: a failed call returns no values and warns" {
  export CONTEXT="$(context_with "app-1/DB_HOST-10" "app-1/DB_PASSWORD-11")"

  run bash -c "$DEPS; MOCK_AWS_MODE=denied source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "get-parameters failed for 2 values"
  assert_contains "$output" '"values": []'
}

@test "aws-parameter-store retrieve_batch: no values makes no call" {
  export CONTEXT='{"values":[]}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '.')" '{"values":[]}'
  [ ! -f "$AWS_LOG" ]
}
