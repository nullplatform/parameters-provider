#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/dispatch — unified action dispatcher
# Replaces the previous 4 standalone scripts (store, retrieve, delete, notify)
# with a single dispatcher that takes the action via $ACTION env var.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/utils/dispatch"
  export PROVIDER_DIR="$BATS_TEST_TMPDIR/fake_provider"
  mkdir -p "$PROVIDER_DIR"

  # The log function is normally pre-loaded by the workflow's first step and is
  # available to any provider script dispatch sources. Mirror that for tests.
  export DISPATCH_PRELUDE="source $PARAMETERS_DIR/utils/log;"
}

@test "dispatch: ACTION=store sources provider's store script" {
  cat > "$PROVIDER_DIR/store" << 'EOF'
echo '{"external_id":"id-1","metadata":{}}'
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=store source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$output" '{"external_id":"id-1","metadata":{}}'
}

@test "dispatch: ACTION=retrieve sources provider's retrieve script" {
  cat > "$PROVIDER_DIR/retrieve" << 'EOF'
echo '{"value":"v"}'
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=retrieve source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$output" '{"value":"v"}'
}

@test "dispatch: ACTION=delete sources provider's delete script" {
  cat > "$PROVIDER_DIR/delete" << 'EOF'
echo '{"success":true}'
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=delete source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$output" '{"success":true}'
}

@test "dispatch: ACTION=notify with provider notify file sources it" {
  cat > "$PROVIDER_DIR/notify" << 'EOF'
echo '{"success":true,"provider":"fake"}'
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=notify source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" '"provider":"fake"'
}

@test "dispatch: ACTION=notify falls back to default ack when provider has no notify" {
  # Intentionally do NOT create $PROVIDER_DIR/notify
  run bash -c "$DISPATCH_PRELUDE ACTION=notify source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$output" '{"success":true}'
}

@test "dispatch: provider script's exit code propagates" {
  cat > "$PROVIDER_DIR/store" << 'EOF'
echo "fatal" >&2
exit 7
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=store source $SCRIPT"

  assert_equal "$status" "7"
  assert_contains "$output" "fatal"
}

@test "dispatch: provider script sees PROVIDER_DIR env var" {
  cat > "$PROVIDER_DIR/store" << 'EOF'
echo "{\"provider_dir\":\"$PROVIDER_DIR\"}"
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=store source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "$PROVIDER_DIR"
}

@test "dispatch: fails when provider's <ACTION> script doesn't exist (non-notify)" {
  # No store script exists
  run bash -c "$DISPATCH_PRELUDE ACTION=store source $SCRIPT"

  [ "$status" -ne 0 ]
}

@test "dispatch: ACTION=retrieve_batch sources provider's retrieve_batch script" {
  cat > "$PROVIDER_DIR/retrieve_batch" << 'EOF'
echo '{"values":[{"external_id":"a","value":"native"}]}'
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=retrieve_batch source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$output" '{"values":[{"external_id":"a","value":"native"}]}'
}

@test "dispatch: ACTION=retrieve_batch runs the provider's retrieve per value when it has no retrieve_batch" {
  cat > "$PROVIDER_DIR/retrieve" << 'EOF'
jq -n --arg value "v-$EXTERNAL_ID" '{value: $value}'
EOF

  run bash -c "$DISPATCH_PRELUDE ACTION=retrieve_batch CONTEXT='{\"values\":[{\"external_id\":\"a\"}]}' source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '.')" '{"values":[{"external_id":"a","value":"v-a"}]}'
}
