<h2 align="center">
    <a href="https://nullplatform.com" target="blank_">
        <img height="100" alt="nullplatform" src="https://nullplatform.com/favicon/android-chrome-192x192.png" />
    </a>
    <br>
    <br>
    Parameters — pluggable parameter & secret storage for nullplatform scopes
    <br>
</h2>

A pluggable parameter and secret storage layer for nullplatform scopes. The
platform selects which backend handles each parameter (via the notification
payload), and the provider's configuration travels in that same payload — so a
single agent can serve parameters routed to multiple backends simultaneously,
with no per-agent configuration.

The **dispatch layer is the package**; the **backends are pluggable modules**
under `parameters/providers/`.

## Providers

| Provider | Backend |
|---|---|
| `aws-secrets-manager` | AWS Secrets Manager |
| `aws-parameter-store` | AWS SSM Parameter Store |
| `azure-key-vault` | Azure Key Vault |
| `gcp-secret-manager` | Google Cloud Secret Manager |
| `hashicorp-vault` | HashiCorp Vault (KV v2) |

## Repository layout

```
.
├── Makefile                 # test targets (see Testing)
├── testing/                 # scope-testing framework (git submodule)
├── docs/                    # architecture, configuration, adding a provider
└── parameters/
    ├── entrypoint           # action router (parameter:<action> → workflow)
    ├── workflows/           # store / retrieve / retrieve_batch / delete / notify
    ├── utils/               # build_context, dispatch, assume_role*, prefetch_np, ...
    ├── providers/           # one directory per backend (+ Tofu install specs & docs)
    └── tests/               # BATS unit tests (mirror the source tree)
```

## Documentation

Start here for how the package works end to end:

- [Architecture](docs/architecture.md) — layered design, request flow, and the dispatch model
- [Configuration](docs/configuration.md) — config resolution (payload → env → default) and per-provider variables
- [Adding a provider](docs/adding_a_provider.md) — how to plug in a new backend
- [Provider contract](parameters/providers/README.md) — the `setup`/`store`/`retrieve`/`delete` interface every provider implements

### Per-provider docs

| Provider | Architecture | IAM policy |
|---|---|---|
| AWS Secrets Manager | [architecture](parameters/providers/aws-secrets-manager/docs/architecture.md) | [iam-policy](parameters/providers/aws-secrets-manager/docs/iam-policy.md) |
| AWS Parameter Store | [architecture](parameters/providers/aws-parameter-store/docs/architecture.md) | [iam-policy](parameters/providers/aws-parameter-store/docs/iam-policy.md) |
| Azure Key Vault | [architecture](parameters/providers/azure-key-vault/docs/architecture.md) | — |
| GCP Secret Manager | [architecture](parameters/providers/gcp-secret-manager/docs/architecture.md) | [iam-policy](parameters/providers/gcp-secret-manager/docs/iam-policy.md) |
| HashiCorp Vault | [architecture](parameters/providers/hashicorp-vault/docs/architecture.md) | — |

## Testing

This module uses the testing framework defined in the
[scope-testing](https://github.com/nullplatform/scope-testing) repository, which
is included as a Git submodule. After cloning, initialize it with:

```bash
git submodule update --init --recursive
```

To add it from scratch (already wired in this repo):

```bash
git submodule add https://github.com/nullplatform/scope-testing.git testing
git submodule init && git submodule update
```

We use **three types of tests** to ensure quality at different levels:

| Test Type | What it Tests | Location | Command |
|-----------|---------------|----------|---------|
| **Unit Tests (BATS)** | `entrypoint`, `utils/`, and each provider's `setup`/`store`/`retrieve`/`delete` bash scripts | `parameters/tests/{utils,providers}/` | `make test-unit` |
| **Tofu Tests** | Provider install specs (Terraform/OpenTofu modules) | `parameters/providers/<provider>/specs/**/*.tftest.hcl` | `make test-tofu` |
| **Integration Tests** | Full workflow execution against mocked backends | `parameters/tests/integration/` | `make test-integration` |

> Unit tests are the active suite (187 tests). The Tofu and integration runners
> are wired through the submodule and ready to use as those suites are added.

### 1. Unit Tests (BATS)

Test bash scripts in isolation using mocked commands (`jq`, `aws`, `az`, `curl`,
`np`, ...). Tests mirror the source tree and source the shared assertions from
the `testing/` submodule.

**Location:** `parameters/tests/{utils,providers/<provider>}/<script>.bats`

**Run:** `make test-unit` (runs `bats -r parameters/tests`)

**Example files:**
- Util: [`parameters/tests/utils/build_context.bats`](parameters/tests/utils/build_context.bats)
- Util: [`parameters/tests/utils/prefetch_np.bats`](parameters/tests/utils/prefetch_np.bats)
- Provider: [`parameters/tests/providers/aws-secrets-manager/store.bats`](parameters/tests/providers/aws-secrets-manager/store.bats)

**Structure:**
```bash
#!/usr/bin/env bats

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$PROJECT_ROOT/testing/assertions.sh"
  # Mock external commands, set required env vars
}

@test "store: writes the secret and returns external_id" {
  run bash -c "source $PARAMETERS_DIR/providers/aws-secrets-manager/store"
  assert_equal "$status" "0"
  assert_contains "$output" '"external_id"'
}
```

### 2. Tofu Tests (OpenTofu/Terraform)

Test the provider install specs (the Terraform/OpenTofu modules operators run to
provision each backend) using `tofu test` with mock providers.

**Location:** `parameters/providers/<provider>/specs/**/*.tftest.hcl`

**Run:** `make test-tofu` or `make test-tofu MODULE=parameters`

### 3. Integration Tests (BATS)

Test complete workflows (store → retrieve → delete) end-to-end with mocked
external dependencies (LocalStack, Azure Mock, Smocker).

**Location:** `parameters/tests/integration/`

**Run:** `make test-integration` or `make test-integration VERBOSE=1`

### Running Tests

```bash
# Run all tests
make test-all

# Run specific test types
make test-unit              # BATS unit tests for bash scripts
make test-tofu              # OpenTofu module tests
make test-integration       # Full workflow integration tests

# Run with verbose output (integration only)
make test-integration VERBOSE=1
```
