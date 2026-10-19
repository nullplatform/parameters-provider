#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/gcp-secret-manager/store
#
# Verifies:
#   - secret id = canonical path flattened under "<prefix>__"
#   - external_id keeps the canonical slash form + "#<version>"
#   - First store creates the secret; 409 on create falls through to addVersion
#   - The value travels base64-encoded in the body, never on argv
#   - Replication: automatic by default, user-managed with replica locations
#   - Real errors propagate with troubleshooting
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_ROOT="$PARAMETERS_DIR"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/gcp-secret-manager/store"

  # Mock `curl`: logs argv and the stdin body, and picks the response per call —
  # secret creation (?secretId=) vs addVersion (:addVersion).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export BODY_LOG="$BATS_TEST_TMPDIR/body.log"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'MOCK'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
out=""; prev=""; call="other"
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in
    *"?secretId="*) call="create" ;;
    *":addVersion"*) call="add" ;;
  esac
  prev="$a"
done
if [[ " $* " == *" --data-binary @- "* ]]; then
  { echo "[$call]"; cat; echo; } >> "$BODY_LOG"
fi
case "$call" in
  create) code="${MOCK_CREATE_CODE:-200}"; body="${MOCK_CREATE_BODY:-}" ;;
  add)    code="${MOCK_ADD_CODE:-200}";    body="${MOCK_ADD_BODY:-}" ;;
  *)      code="500";                      body="" ;;
esac
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '%s' "$code"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export GSM_PROJECT_ID="my-project"
  export GSM_API_URL="https://secretmanager.googleapis.com/v1"
  export GSM_NAME_PREFIX="nullplatform"
  export GSM_REPLICA_LOCATIONS=""
  export GCP_ACCESS_TOKEN="tok-abc"
  export PARAMETER_ID="42"
  export PARAMETER_VALUE="my-secret"
  export MOCK_CREATE_CODE=200
  export MOCK_CREATE_BODY='{"name":"projects/123/secrets/x"}'
  export MOCK_ADD_CODE=200
  export MOCK_ADD_BODY='{"name":"projects/123/secrets/x/versions/3","state":"ENABLED"}'

  export CONTEXT='{
    "parameter_id": 42,
    "parameter_name": "DB_PASSWORD",
    "value": "my-secret",
    "entities": {
      "organization": "284820983", "organization_slug": "sulamerica",
      "account": "1146568170", "account_slug": "playground",
      "namespace": "111", "namespace_slug": "billing",
      "application": "222", "application_slug": "api"
    },
    "dimensions": {}
  }'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "gcp-secret-manager store: external_id is the canonical path + version suffix" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  assert_equal "$external_id" "organization=sulamerica-284820983/account=playground-1146568170/namespace=billing-111/application=api-222/DB_PASSWORD-42#3"
}

@test "gcp-secret-manager store: secret id is the flattened path under the prefix" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_id=$(echo "$output" | jq -r '.metadata.secret_id')
  assert_equal "$secret_id" "nullplatform__organization-sulamerica-284820983__account-playground-1146568170__namespace-billing-111__application-api-222__DB_PASSWORD-42"
  [[ "$secret_id" =~ ^[A-Za-z0-9_-]+$ ]]
}

@test "gcp-secret-manager store: metadata carries the version resource name and project" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$(echo "$output" | jq -r '.metadata.version_name')" "projects/123/secrets/x/versions/3"
  assert_equal "$(echo "$output" | jq -r '.metadata.project_id')" "my-project"
}

@test "gcp-secret-manager store: creates the secret then adds a version" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "https://secretmanager.googleapis.com/v1/projects/my-project/secrets?secretId=nullplatform__organization-sulamerica-284820983"
  assert_contains "$captured" "/secrets/nullplatform__organization-sulamerica-284820983__account-playground-1146568170__namespace-billing-111__application-api-222__DB_PASSWORD-42:addVersion"
  assert_contains "$captured" "Authorization: Bearer tok-abc"
  [ "$(grep -c '' "$CURL_LOG")" -eq 2 ]
}

@test "gcp-secret-manager store: value travels base64-encoded on stdin, not on argv" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  [[ "$captured" != *"my-secret"* ]]
  bodies=$(cat "$BODY_LOG")
  assert_contains "$bodies" "$(printf 'my-secret' | base64)"
}

@test "gcp-secret-manager store: automatic replication and nullplatform labels by default" {
  run bash -c "$DEPS; source $SCRIPT"

  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -c '.replication')" '{"automatic":{}}'
  assert_equal "$(echo "$create_body" | jq -r '.labels.managed_by')" "nullplatform"
  assert_equal "$(echo "$create_body" | jq -r '.labels.parameter_id')" "42"
}

@test "gcp-secret-manager store: replica locations switch to user-managed replication" {
  export GSM_REPLICA_LOCATIONS="southamerica-east1,us-east1"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -c '.replication')" '{"userManaged":{"replicas":[{"location":"southamerica-east1"},{"location":"us-east1"}]}}'
}

@test "gcp-secret-manager store: existing secret (409) still adds a new version" {
  export MOCK_CREATE_CODE=409
  export MOCK_CREATE_BODY='{"error":{"code":409,"message":"Secret already exists"}}'
  export MOCK_ADD_BODY='{"name":"projects/123/secrets/x/versions/4"}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.external_id' | sed 's/.*#//')" "4"
}

@test "gcp-secret-manager store: dimensions sorted alphabetically, scope included" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.value_entities = (.entities + {scope: "333", scope_slug: "prod"}) | .dimensions = {environment: "production", country: "br"}')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_id=$(echo "$output" | jq -r '.metadata.secret_id')
  assert_contains "$secret_id" "__application-api-222__scope-prod-333__country-br__environment-production__DB_PASSWORD-42"
}

@test "gcp-secret-manager store: characters outside the charset are mapped to dashes" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.parameter_name = "db.password"')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_id=$(echo "$output" | jq -r '.metadata.secret_id')
  assert_contains "$secret_id" "__db-password-42"
}

@test "gcp-secret-manager store: secret id over 255 chars fails with a clear error" {
  long_name=$(printf 'x%.0s' $(seq 1 200))
  export CONTEXT=$(echo "$CONTEXT" | jq --arg n "$long_name" '.parameter_name = $n')

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "exceeds GCP Secret Manager's 255-character limit"
  assert_contains "$output" "🔧 How to fix:"
  [ ! -f "$CURL_LOG" ]
}

@test "gcp-secret-manager store: create failure propagates with the API error" {
  export MOCK_CREATE_CODE=403
  export MOCK_CREATE_BODY='{"error":{"code":403,"message":"Permission secretmanager.secrets.create denied"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to create secret"
  assert_contains "$output" "(HTTP 403)"
  assert_contains "$output" "Underlying error: Permission secretmanager.secrets.create denied"
}

@test "gcp-secret-manager store: addVersion failure propagates with the API error" {
  export MOCK_ADD_CODE=403
  export MOCK_ADD_BODY='{"error":{"code":403,"message":"Permission secretmanager.versions.add denied"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to add a version to secret"
  assert_contains "$output" "Underlying error: Permission secretmanager.versions.add denied"
}

@test "gcp-secret-manager store: network failure reports no HTTP response" {
  export MOCK_CREATE_CODE=000
  export MOCK_CREATE_BODY=''

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "(HTTP 000)"
  assert_contains "$output" "could not connect to secretmanager.googleapis.com"
}
