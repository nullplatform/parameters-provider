#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-parameter-store/retrieve
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-parameter-store/retrieve"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$AWS_LOG"
if [ "$2" = "get-parameters-by-path" ]; then
  case "${MOCK_BY_PATH_MODE:-success}" in
    success)
      echo '[{"n":"/nullplatform/app-1/DB_PASSWORD-10","v":"from-path","ver":3},{"n":"/nullplatform/app-1/API_URL-11","v":"https://api","ver":1}]'
      ;;
    denied)
      echo "An error occurred (AccessDeniedException) when calling the GetParametersByPath operation." >&2
      exit 254
      ;;
  esac
  exit 0
fi
case "${MOCK_AWS_MODE:-success}" in
  success)
    echo "the-real-value"
    ;;
  not_found)
    echo "An error occurred (ParameterNotFound) when calling the GetParameter operation." >&2
    exit 254
    ;;
  auth_error)
    echo "An error occurred (AccessDeniedException) when calling the GetParameter operation." >&2
    exit 254
    ;;
  *)
    echo "An error occurred (InternalServerError)." >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/aws"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AWS_REGION="us-east-1"
  export PS_NAME_PREFIX="/nullplatform/"
  export EXTERNAL_ID="abc-123"

  export EXTERNAL_ID_PATH="$EXTERNAL_ID"
  export EXTERNAL_ID_VERSION=""
  export CONTEXT='{}'
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "aws-parameter-store retrieve: success → returns value" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  value=$(echo "$output" | jq -r '.value')
  assert_equal "$value" "the-real-value"
}

@test "aws-parameter-store retrieve: ParameterNotFound fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=not_found source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "not found in AWS Parameter Store"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "🔧 How to fix:"
}

@test "aws-parameter-store retrieve: AccessDenied fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=auth_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve parameter"
  assert_contains "$output" "lacks ssm:GetParameter"
}

@test "aws-parameter-store retrieve: unknown errors fail loud" {
  run bash -c "$DEPS; MOCK_AWS_MODE=other source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve parameter"
}

@test "aws-parameter-store retrieve: calls aws with --with-decryption" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "ssm get-parameter"
  assert_contains "$captured" "--region us-east-1"
  assert_contains "$captured" "--name /nullplatform/abc-123"
  assert_contains "$captured" "--with-decryption"
}

# --- Value cache fill (utils/value_cache) -------------------------------------

stage_value_cache() {
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"
  mkdir -p "$SERVICE_PATH/utils"
  cp "$PARAMETERS_DIR/utils/value_cache" "$SERVICE_PATH/utils/"
  export EXTERNAL_ID_PATH="app-1/DB_PASSWORD-10"
}

@test "aws-parameter-store retrieve: fills the value cache from the path and answers from it" {
  stage_value_cache
  export EXTERNAL_ID_VERSION="3"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.value')" "from-path"
  assert_contains "$(cat "$AWS_LOG")" "get-parameters-by-path --region us-east-1 --path /nullplatform/app-1"
  [ "$(grep -c 'get-parameter ' "$AWS_LOG" || true)" = "0" ]
  cached=$(bash -c "source $SERVICE_PATH/utils/value_cache; value_cache_lookup /nullplatform/app-1 /nullplatform/app-1/API_URL-11 1")
  assert_equal "$cached" "https://api"
}

@test "aws-parameter-store retrieve: version-pinned retrieve answers from the path when versions match" {
  stage_value_cache
  export EXTERNAL_ID_VERSION="3"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.value')" "from-path"
}

@test "aws-parameter-store retrieve: version mismatch falls back to get-parameter with :version" {
  stage_value_cache
  export EXTERNAL_ID_VERSION="2"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.value')" "the-real-value"
  assert_contains "$(cat "$AWS_LOG")" "--name /nullplatform/app-1/DB_PASSWORD-10:2"
}

@test "aws-parameter-store retrieve: by-path denied warns and falls back to get-parameter" {
  stage_value_cache
  export EXTERNAL_ID_VERSION="3"

  run bash -c "$DEPS; MOCK_BY_PATH_MODE=denied source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "value cache fill failed"
  assert_contains "$output" "the-real-value"
}

@test "aws-parameter-store retrieve: TTL 0 skips the cache fill" {
  stage_value_cache

  run bash -c "$DEPS; NP_PARAMETERS_CACHE_TTL_SECS=0 source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "the-real-value"
  [ "$(grep -c 'get-parameters-by-path' "$AWS_LOG" || true)" = "0" ]
}

@test "aws-parameter-store retrieve: a group already cached is not read again" {
  stage_value_cache
  export EXTERNAL_ID_VERSION="2"
  bash -c "source $SERVICE_PATH/utils/value_cache; value_cache_write /nullplatform/app-1 '{\"/nullplatform/app-1/DB_PASSWORD-10\":{\"value\":\"cached\",\"version\":\"3\"}}'"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "the-real-value"
  [ "$(grep -c 'get-parameters-by-path' "$AWS_LOG" || true)" = "0" ]
}

@test "aws-parameter-store retrieve: a versionless retrieve doesn't fill the cache" {
  stage_value_cache

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "the-real-value"
  [ "$(grep -c 'get-parameters-by-path' "$AWS_LOG" || true)" = "0" ]
}
