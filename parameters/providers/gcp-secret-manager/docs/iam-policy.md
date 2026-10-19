# GCP Secret Manager — IAM Policy

Least-privilege access for the agent identity. The `specs/requirements/` module applies exactly this; the manual equivalent is below.

## Permissions the provider uses

| Operation | Permission | Evaluated on |
|-----------|------------|--------------|
| `store` (create, first time) | `secretmanager.secrets.create` | the project |
| `store` (every time) | `secretmanager.versions.add` | the secret |
| `retrieve` | `secretmanager.versions.access` | the secret |
| `delete` | `secretmanager.secrets.delete` | the secret |

## Binding

Grant `roles/secretmanager.admin` with an IAM condition that admits the project itself (where `secrets.create` is checked) plus only the secrets under the provider's prefix. Existing secrets of other teams in a shared project stay out of reach: the agent can neither read, version nor delete them.

```
resource.type == "cloudresourcemanager.googleapis.com/Project" ||
resource.name.startsWith("projects/<PROJECT_NUMBER>/secrets/<NAME_PREFIX>__")
```

- `<PROJECT_NUMBER>` is the numeric project number (secret resource names use the number, not the id).
- `<NAME_PREFIX>` must equal the runtime `setup.name_prefix` (default `nullplatform`). The double underscore is part of the naming scheme, so a prefix `nullplatform` does not also match `nullplatform-other__…`.

## Member: the agent's KSA through Workload Identity Federation (recommended)

On GKE with Workload Identity, grant the agent's Kubernetes service account directly. The agent needs no GCP service account, annotation or key:

```
principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/<NAMESPACE>/sa/<KSA_NAME>
```

With the nullplatform agent chart defaults: namespace `nullplatform-tools`, KSA `nullplatform-agent`.

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/nullplatform-tools/sa/nullplatform-agent" \
  --role="roles/secretmanager.admin" \
  --condition='title=nullplatform-secrets,expression=resource.type == "cloudresourcemanager.googleapis.com/Project" || resource.name.startsWith("projects/<PROJECT_NUMBER>/secrets/nullplatform__")'
```

An agent that authenticates with a GCP service account instead (outside GKE, through `GCP_ACCESS_TOKEN`) gets the same binding with `--member="serviceAccount:<SA_EMAIL>"`.

## Notes

- `roles/secretmanager.admin` also carries `secrets.list` and `setIamPolicy` on secrets; the condition limits the latter to the provider's own secrets. Narrow it further with a custom role holding only the four permissions above if your policy requires it.
- Granting `roles/secretmanager.secretAccessor` alone is **not** enough: `store` and `delete` need create, addVersion and delete.
