#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/retrieve_each
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/utils/retrieve_each"
  export PROVIDER_DIR="$BATS_TEST_TMPDIR/fake_provider"
  mkdir -p "$PROVIDER_DIR"
  cat > "$PROVIDER_DIR/retrieve" << 'EOF'
set -euo pipefail
if [[ "$EXTERNAL_ID_PATH" == *bad* ]]; then
  log error "❌ cannot read $EXTERNAL_ID_PATH"
  exit 1
fi
jq -n --arg value "$EXTERNAL_ID_PATH|$EXTERNAL_ID_VERSION|$PARAMETER_NAME|$PARAMETER_ENCODING" '{value: $value}'
EOF
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "retrieve_each: retrieves every value with its own external id, version and metadata" {
  export CONTEXT='{"values":[{"external_id":"app-1/A-1#3","parameter_name":"A","encoding":"base64"},{"external_id":"app-1/B-2","parameter_name":"B"}]}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '.values')" '[{"external_id":"app-1/A-1#3","value":"app-1/A-1|3|A|base64"},{"external_id":"app-1/B-2","value":"app-1/B-2||B|"}]'
}

@test "retrieve_each: leaves out a value the provider cannot read and keeps going" {
  export CONTEXT='{"values":[{"external_id":"app-1/bad-1"},{"external_id":"app-1/B-2"}]}'

  run bash -c "$DEPS; source $SCRIPT 2>/dev/null"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '[.values[].external_id]')" '["app-1/B-2"]'
}

@test "retrieve_each: warns about the values it leaves out" {
  export CONTEXT='{"values":[{"external_id":"app-1/bad-1"}]}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_contains "$output" "Could not retrieve 'app-1/bad-1' in the batch"
}

@test "retrieve_each: no values returns an empty list" {
  export CONTEXT='{"values":[]}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '.')" '{"values":[]}'
}
