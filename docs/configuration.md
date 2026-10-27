# Configuration

How the parameters package decides which provider to use and where each provider gets its config — all from the notification payload.

---

## Where everything comes from

Each notification from nullplatform includes the full information needed to handle the parameter:

| Field in `$CONTEXT` | Purpose |
|---|---|
| `parameter_id` | nullplatform parameter ID |
| `value` | the value to persist (only on store) |
| `external_id` | provider's handle for the parameter (on retrieve/delete/notify) |
| `secret` | bool — discriminates secret vs plain parameter |
| `parameter_name` | human-readable name |
| `encoding` | encoding of the value (`plain`, `base64`, etc.) |
| `entities` | NRN parsed into entity IDs (organization, account, namespace, application) |
| `dimensions` | optional object — parameter scoping (env, country, etc.) |
| **`provider.specification_id`** | **UUID identifying which provider handles this parameter** |
| **`provider.attributes`** | **Provider-specific configuration (region, vault address, etc.)** |
| `provider.nrn` | Provider-instance NRN (informational) |
| `provider.dimensions` | Provider-instance dimensions. **Do NOT use this field** — it is internal to the platform's provider system and unrelated to the parameter's `.dimensions`. Parameter dimensions come from top-level `.dimensions` only. |
| `provider.id` | Provider-instance ID (informational) |

The two fields that drive the dispatch are `provider.specification_id` (which provider) and `provider.attributes` (its config).

---

## Provider resolution

`build_context` calls:

```bash
np provider specification read --id <provider.specification_id> --format json
```

The response includes a `slug` field. That slug must match the name of a directory under `parameters/providers/`. For example:

| Slug returned | Provider directory used |
|---|---|
| `hashicorp-vault` | `parameters/providers/hashicorp-vault/` |
| `aws-secrets-manager` | `parameters/providers/aws-secrets-manager/` |
| `aws-parameter-store` | `parameters/providers/aws-parameter-store/` |
| `azure-key-vault` | `parameters/providers/azure-key-vault/` |
| `gcp-secret-manager` | `parameters/providers/gcp-secret-manager/` |

If the slug doesn't match any installed provider, `build_context` fails with a list of available providers and instructions to either rename the spec slug or add the missing provider.

---

## Provider config

`build_context` exports `PROVIDER_CONFIG` as a JSON string containing whatever is in `$CONTEXT.provider.attributes`. The shape is provider-specific.

Each provider's `setup` script reads from `PROVIDER_CONFIG` via `get_config_value`:

```bash
REGION=$(get_config_value --env AWS_REGION --provider '.region')
```

Priority order (highest to lowest):

1. Provider config (`get_config_value --provider '.field'`)
2. Environment variable (`get_config_value --env NAME`)
3. Default (`get_config_value --default 'value'`)

Env vars take precedence ONLY when the provider attribute is missing. This lets you override config in a local dev environment by setting env vars while keeping the platform-controlled config as the production source of truth.

---

## Per-provider config shapes

The shape of `$CONTEXT.provider.attributes` for each provider:

### `hashicorp-vault`

```json
{
  "address":     "https://vault.example.com",
  "token":       "hvs.xxx",
  "path_prefix": "secret/data/parameters"
}
```

### `aws-secrets-manager` (currently named `aws-secrets-manager`)

```json
{
  "region":      "us-east-1",
  "name_prefix": "parameters/",
  "kms_key_id":  "alias/aws/secretsmanager"
}
```

`kms_key_id` is optional (defaults to AWS-managed key).

### `aws-parameter-store`

```json
{
  "region":      "us-east-1",
  "name_prefix": "/nullplatform/parameters/",
  "kms_key_id":  "alias/parameters-secure",
  "tier":        "Standard"
}
```

`kms_key_id` only matters for `kind=secret` (SecureString). `tier` ∈ {`Standard`, `Advanced`, `Intelligent-Tiering`}.

**Value cache.** The platform sends one `parameter:retrieve` per value, all at once, when a deploy resolves its parameters. The first retrieve of an application (or scope) reads every value under its SSM path with one `get-parameters-by-path` and keeps them on disk for a short TTL; the entrypoint answers the rest from there, before the workflow starts, and concurrent misses wait for that first read instead of each running the full workflow. Only version-pinned retrieves (`external_id` ending in `#<version>`, which is what `store` returns) are served from the cache, and only when the cached version matches: SSM versions are immutable, so a hit is the same value SSM would return. Versionless retrieves, retrieves that pin a version the cache doesn't hold (they run alongside the others instead of waiting), and consumers that override the `retrieve` workflow take the full workflow as before. A `store` or `delete` drops the cached values of its path, so the next retrieve reads it again. Without `ssm:GetParametersByPath` the cache fill fails and retrieve falls back to `get-parameter`. Agent environment:

| Variable | Default | |
|---|---|---|
| `NP_PARAMETERS_CACHE_TTL_SECS` | `60` | Lifetime of cached values, enough to cover the retrieves of one deploy. `0` turns the cache off. |
| `NP_PARAMETERS_CACHE_WAIT_SECS` | `20` | How long a retrieve waits for the one filling the cache before running the full workflow itself. Keep it under the platform's 30s retrieve timeout. |

Cached values are secrets in clear text under `$SERVICE_PATH/value-cache/` (files 600, directory 700, expired files removed on each write and entrypoint run), next to the STS credentials cache.

### `azure-key-vault`

```json
{
  "vault_name":    "my-keyvault",
  "secret_prefix": "parameters-"
}
```

Authentication is a service-principal client-credentials OAuth2 flow against Azure AD, done with `curl` against the REST API (no Azure CLI): `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` and `AZURE_TENANT_ID` come from the agent environment, never from provider config.

### `gcp-secret-manager`

```json
{
  "setup": {
    "project_id":        "acme-prod-secrets",
    "name_prefix":       "nullplatform",
    "replica_locations": ["europe-west1"]
  }
}
```

Only `project_id` is required. Authentication comes from the metadata server (the agent pod's GKE Workload Identity); `GCP_ACCESS_TOKEN` in the agent environment overrides it. See [the provider architecture](../parameters/providers/gcp-secret-manager/docs/architecture.md).

---

## Local development

For local testing without involving the platform, set the relevant env vars and use a stubbed `np` CLI that returns a known slug:

```bash
# Stub np in PATH
cat > /tmp/np << 'EOF'
#!/bin/bash
echo '{"slug": "hashicorp-vault"}'
EOF
chmod +x /tmp/np
export PATH=/tmp:$PATH

# Set the provider's env vars
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root-token

# Now invoke the entrypoint
NP_ACTION_CONTEXT='...' NOTIFICATION_ACTION='parameter:store' ./parameters/entrypoint
```

All providers fall through to env vars when `PROVIDER_CONFIG` is missing fields, making local-only iteration possible.
