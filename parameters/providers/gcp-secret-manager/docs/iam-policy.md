# GCP Secret Manager — IAM Policy

Least-privilege access for the agent identity. The `specs/requirements/` module applies exactly this; the manual equivalent is below.

## Permissions the provider uses

| Operation | Permission | Evaluated on |
|-----------|------------|--------------|
| `store` (every time) | `secretmanager.versions.add` | the secret |
| `store` (first time only, when `addVersion` answers 404) | `secretmanager.secrets.create` | the project |
| `retrieve` | `secretmanager.versions.access` | the secret |
| `delete` | `secretmanager.secrets.delete` | the secret |

## Role

The default (`specs/requirements`, `custom_role.enable = true`) is a **custom role with exactly the four permissions above**. Prefer it over `roles/secretmanager.admin`: the admin role also carries `secretmanager.secrets.list`, which is checked against the project and therefore admitted by the project clause of the condition below, so the agent could enumerate every secret name in a shared project.

```bash
gcloud iam roles create nullplatformParametersSecretManager --project <PROJECT_ID> \
  --title "nullplatform parameters (GCP Secret Manager)" \
  --permissions secretmanager.secrets.create,secretmanager.secrets.delete,secretmanager.versions.access,secretmanager.versions.add
```

## Binding

Grant the role with an IAM condition that admits the project itself (where `secrets.create` is checked) plus only the secrets under the provider's prefix. Existing secrets of other teams in a shared project stay out of reach: the agent can neither read, version nor delete them.

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
  --role="projects/<PROJECT_ID>/roles/nullplatformParametersSecretManager" \
  --condition='title=nullplatform-secrets,expression=resource.type == "cloudresourcemanager.googleapis.com/Project" || resource.name.startsWith("projects/<PROJECT_NUMBER>/secrets/nullplatform__")'
```

An agent that authenticates with a GCP service account instead (outside GKE, through `GCP_ACCESS_TOKEN`) gets the same binding with `--member="serviceAccount:<SA_EMAIL>"`.

## Notes

- `<NAME_PREFIX>` cannot contain `__` (setup rejects it), so one prefix never covers another prefix's secrets.
- Granting `roles/secretmanager.secretAccessor` alone is **not** enough: `store` and `delete` need create, addVersion and delete.
- How Secret Manager evaluates `resource.type` / `resource.name` for `secrets.create` is the assumption the project clause rests on; validate it once per environment with a real store (see the provider's architecture doc).
