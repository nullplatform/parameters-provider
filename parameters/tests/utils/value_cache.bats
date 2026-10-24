#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/value_cache — on-disk cache of retrieved
# values shared by concurrent retrieves.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"
  source "$PARAMETERS_DIR/utils/value_cache"

  # Fresh cache per test: it lives under $SERVICE_PATH/value-cache/.
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"
  mkdir -p "$SERVICE_PATH"
  GROUP="/nullplatform/organization_acme-1/application_app-4"
  VALUES='{"/nullplatform/organization_acme-1/application_app-4/DB_PASSWORD-10":{"value":"s3cr3t","version":"3"},"/nullplatform/organization_acme-1/application_app-4/API_URL-11":{"value":"https://api","version":"1"}}'
}

teardown() {
  unset SERVICE_PATH NP_PARAMETERS_CACHE_TTL_SECS
}

@test "value_cache: enabled by default with a 60s TTL" {
  run value_cache_enabled
  assert_equal "$status" "0"
  assert_equal "$(value_cache_ttl)" "60"
}

@test "value_cache: TTL 0 disables it" {
  NP_PARAMETERS_CACHE_TTL_SECS=0 run value_cache_enabled
  [ "$status" -ne 0 ]
}

@test "value_cache: a non-numeric TTL disables it" {
  NP_PARAMETERS_CACHE_TTL_SECS=abc run value_cache_enabled
  [ "$status" -ne 0 ]
}

@test "value_cache: lookup hits a written value" {
  value_cache_write "$GROUP" "$VALUES"

  run value_cache_lookup "$GROUP" "$GROUP/DB_PASSWORD-10"

  assert_equal "$status" "0"
  assert_equal "$output" "s3cr3t"
}

@test "value_cache: lookup misses a name the group does not hold" {
  value_cache_write "$GROUP" "$VALUES"

  run value_cache_lookup "$GROUP" "$GROUP/OTHER-12"

  [ "$status" -ne 0 ]
}

@test "value_cache: lookup misses when nothing was written for the group" {
  run value_cache_lookup "$GROUP" "$GROUP/DB_PASSWORD-10"

  [ "$status" -ne 0 ]
}

@test "value_cache: version-pinned lookup hits only the cached version" {
  value_cache_write "$GROUP" "$VALUES"

  run value_cache_lookup "$GROUP" "$GROUP/DB_PASSWORD-10" "3"
  assert_equal "$status" "0"
  assert_equal "$output" "s3cr3t"

  run value_cache_lookup "$GROUP" "$GROUP/DB_PASSWORD-10" "2"
  [ "$status" -ne 0 ]
}

@test "value_cache: an expired file misses and is removed" {
  value_cache_write "$GROUP" "$VALUES"
  file=$(value_cache_file "$GROUP")
  jq '._cache_exp_epoch = 1577836800' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  run value_cache_lookup "$GROUP" "$GROUP/DB_PASSWORD-10"

  [ "$status" -ne 0 ]
  [ ! -e "$file" ]
}

@test "value_cache: multiline and quoted values round-trip unchanged" {
  value=$'line one\n"quoted" line two\n'
  values=$(jq -n --arg v "$value" --arg n "$GROUP/CERT-13" '{($n): {value: $v, version: "1"}}')
  value_cache_write "$GROUP" "$values"

  got=$(value_cache_lookup "$GROUP" "$GROUP/CERT-13"; echo x)

  assert_equal "${got%x}" "$value"
}

@test "value_cache: file is 600 inside a 700 dir" {
  value_cache_write "$GROUP" "$VALUES"
  file=$(value_cache_file "$GROUP")

  file_mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
  dir_mode=$(stat -c '%a' "$(value_cache_dir)" 2>/dev/null || stat -f '%Lp' "$(value_cache_dir)")

  assert_equal "$file_mode" "600"
  assert_equal "$dir_mode" "700"
}

@test "value_cache: different groups use different files" {
  [ "$(value_cache_file "$GROUP")" != "$(value_cache_file "$GROUP/scope_dev-5")" ]
}

@test "value_cache: lock times out while another process holds it" {
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  value_cache_lock "$GROUP" 8 1

  run bash -c "source $PARAMETERS_DIR/utils/value_cache; SERVICE_PATH=$SERVICE_PATH value_cache_lock '$GROUP' 9 1"

  [ "$status" -ne 0 ]
}
