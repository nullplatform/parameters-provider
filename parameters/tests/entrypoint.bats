#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/entrypoint — the action router.
# Action comes from $CONTEXT.action (i.e. NP_ACTION_CONTEXT.notification.action),
# NOT from a separate env var.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/entrypoint"
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"

  # Stage a fake parameters/workflows/ with the expected action workflows.
  mkdir -p "$SERVICE_PATH/workflows"
  for action in store retrieve delete notify; do
    : > "$SERVICE_PATH/workflows/$action.yaml"
  done

  # np mock — echo args so we can assert what entrypoint invoked.
  cat > "$BATS_TEST_TMPDIR/np" << 'EOF'
#!/bin/bash
echo "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/np"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
}

teardown() {
  unset NP_ACTION_CONTEXT OVERRIDES_PATH SERVICE_PATH
}

@test "entrypoint: fails when NP_ACTION_CONTEXT is empty" {
  unset NP_ACTION_CONTEXT

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ NP_ACTION_CONTEXT is not set"
}

@test "entrypoint: fails when CONTEXT.action has no action part" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter","secret":true}}'

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ CONTEXT.action is missing the action part"
}

@test "entrypoint: fails when CONTEXT.action is absent" {
  export NP_ACTION_CONTEXT='{"notification":{"secret":true}}'

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ CONTEXT.action is missing the action part"
}

@test "entrypoint: store action routes to store.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "store.yaml"
}

@test "entrypoint: retrieve action routes to retrieve.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:retrieve","secret":true,"external_id":"abc"}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "retrieve.yaml"
}

@test "entrypoint: delete action routes to delete.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:delete","secret":false,"external_id":"abc"}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "delete.yaml"
}

@test "entrypoint: notify action routes to notify.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:notify","secret":true,"external_id":"abc"}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "notify.yaml"
}

@test "entrypoint: payload's .secret value does not affect routing" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'
  run bash "$SCRIPT"
  assert_equal "$status" "0"
  output_true="$output"

  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":false}}'
  run bash "$SCRIPT"
  assert_equal "$status" "0"

  assert_equal "$output" "$output_true"
}

@test "entrypoint: fails when no matching workflow exists" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:nonexistent","secret":true}}'

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ No workflow found at"
}

@test "entrypoint: strips surrounding single quotes from NP_ACTION_CONTEXT" {
  export NP_ACTION_CONTEXT="'{\"notification\":{\"action\":\"parameter:store\",\"secret\":true}}'"

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "store.yaml"
}

@test "entrypoint: OVERRIDES_PATH appends --overrides for matching path" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'

  mkdir -p "$BATS_TEST_TMPDIR/override1/parameters/workflows"
  : > "$BATS_TEST_TMPDIR/override1/parameters/workflows/store.yaml"
  export OVERRIDES_PATH="$BATS_TEST_TMPDIR/override1"

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "--overrides $BATS_TEST_TMPDIR/override1/parameters/workflows/store.yaml"
}

@test "entrypoint: OVERRIDES_PATH skips paths without the workflow file" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'

  mkdir -p "$BATS_TEST_TMPDIR/empty_override"
  export OVERRIDES_PATH="$BATS_TEST_TMPDIR/empty_override"

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  [[ "$output" != *"--overrides $BATS_TEST_TMPDIR/empty_override"* ]]
}

# --- Retrieve fast path (utils/value_cache) -----------------------------------
# The entrypoint uses its own directory as SERVICE_PATH, so these tests run a
# staged copy of the package: the cache files then land in the test's tmpdir.

stage_package() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$PKG/utils" "$PKG/workflows" "$PKG/providers/aws-parameter-store" "$PKG/providers/no-cache"
  cp "$PARAMETERS_DIR/entrypoint" "$PKG/"
  cp "$PARAMETERS_DIR/utils/log" "$PARAMETERS_DIR/utils/value_cache" "$PKG/utils/"
  cp "$PARAMETERS_DIR/providers/aws-parameter-store/cache_key" "$PARAMETERS_DIR/providers/aws-parameter-store/naming" "$PKG/providers/aws-parameter-store/"
  : > "$PKG/workflows/retrieve.yaml"
  GROUP="/nullplatform/organization_acme-1/application_app-4"
  NAME="$GROUP/DB_PASSWORD-10"
}

seed_cache() {
  bash -c "source $PKG/utils/value_cache; SERVICE_PATH=$PKG value_cache_write '$GROUP' '{\"$NAME\":{\"value\":\"cached\",\"version\":\"3\"}}'"
}

retrieve_context() {
  local slug="${1:-aws-parameter-store}" external_id="${2:-organization=acme-1/application=app-4/DB_PASSWORD-10#3}"
  echo "{\"notification\":{\"action\":\"parameter:retrieve\",\"external_id\":\"$external_id\",\"provider\":{\"specification_slug\":\"$slug\"}}}"
}

@test "entrypoint: retrieve cache hit answers without running the workflow" {
  stage_package
  seed_cache
  export NP_ACTION_CONTEXT="$(retrieve_context)"

  run bash "$PKG/entrypoint"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.value')" "cached"
  [[ "$output" != *"service workflow exec"* ]]
}

@test "entrypoint: retrieve cache miss runs the workflow" {
  stage_package
  export NP_ACTION_CONTEXT="$(retrieve_context)"

  run bash "$PKG/entrypoint"

  assert_equal "$status" "0"
  assert_contains "$output" "service workflow exec --no-output --workflow $PKG/workflows/retrieve.yaml"
}

@test "entrypoint: retrieve with another cached version runs the workflow" {
  stage_package
  seed_cache
  export NP_ACTION_CONTEXT="$(retrieve_context aws-parameter-store 'organization=acme-1/application=app-4/DB_PASSWORD-10#2')"

  run bash "$PKG/entrypoint"

  assert_contains "$output" "service workflow exec"
}

@test "entrypoint: provider without cache_key always runs the workflow" {
  stage_package
  seed_cache
  export NP_ACTION_CONTEXT="$(retrieve_context no-cache)"

  run bash "$PKG/entrypoint"

  assert_contains "$output" "service workflow exec"
}

@test "entrypoint: a retrieve workflow override disables the cache" {
  stage_package
  seed_cache
  mkdir -p "$BATS_TEST_TMPDIR/overrides/parameters/workflows"
  : > "$BATS_TEST_TMPDIR/overrides/parameters/workflows/retrieve.yaml"
  export OVERRIDES_PATH="$BATS_TEST_TMPDIR/overrides"
  export NP_ACTION_CONTEXT="$(retrieve_context)"

  run bash "$PKG/entrypoint"

  assert_contains "$output" "--overrides $BATS_TEST_TMPDIR/overrides/parameters/workflows/retrieve.yaml"
}

@test "entrypoint: TTL 0 disables the cache" {
  stage_package
  seed_cache
  export NP_PARAMETERS_CACHE_TTL_SECS=0
  export NP_ACTION_CONTEXT="$(retrieve_context)"

  run bash "$PKG/entrypoint"

  assert_contains "$output" "service workflow exec"
  unset NP_PARAMETERS_CACHE_TTL_SECS
}

@test "entrypoint: cache_key computes the same SSM name as the provider's naming rule" {
  stage_package
  export CONTEXT='{"external_id":"organization=acme-1/application=app-4/DB_PASSWORD-10#3"}'

  run bash -c "source $PKG/providers/aws-parameter-store/cache_key; echo \"\$VALUE_CACHE_NAME|\$VALUE_CACHE_GROUP|\$VALUE_CACHE_VERSION\"
               source $PARAMETERS_DIR/providers/aws-parameter-store/naming; ps_parameter_name 'organization=acme-1/application=app-4/DB_PASSWORD-10'"

  assert_equal "${lines[0]}" "$NAME|$GROUP|3"
  assert_equal "${lines[1]}" "$NAME"
  unset CONTEXT
}

@test "entrypoint: a cached group that can't serve the value doesn't wait for the lock" {
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  stage_package
  seed_cache
  # Another retrieve holds the group lock (e.g. refilling): a version the
  # cache doesn't have must not wait for it.
  exec 8>"$(bash -c "source $PKG/utils/value_cache; SERVICE_PATH=$PKG value_cache_file '$GROUP'").lock"
  flock -x 8
  export NP_ACTION_CONTEXT="$(retrieve_context aws-parameter-store 'organization=acme-1/application=app-4/DB_PASSWORD-10#2')"
  export NP_PARAMETERS_CACHE_WAIT_SECS=10

  start=$SECONDS
  run bash "$PKG/entrypoint"

  assert_contains "$output" "service workflow exec"
  [ $(( SECONDS - start )) -lt 5 ]
  exec 8>&-
  unset NP_PARAMETERS_CACHE_WAIT_SECS
}

@test "entrypoint: a versionless retrieve runs the workflow even when the name is cached" {
  stage_package
  seed_cache
  export NP_ACTION_CONTEXT="$(retrieve_context aws-parameter-store 'organization=acme-1/application=app-4/DB_PASSWORD-10')"

  run bash "$PKG/entrypoint"

  assert_contains "$output" "service workflow exec"
}
