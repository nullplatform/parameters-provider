resource "google_project_service" "secretmanager" {
  count = var.enable_api ? 1 : 0

  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# One conditional binding per member. Secret Manager evaluates create (and list)
# against the project, and everything else (addVersion, access, delete) against
# the secret, so the condition admits the project itself plus only the secrets
# under the provider's prefix — existing secrets of other teams in a shared
# project stay out of reach.
resource "google_project_iam_member" "secret_manager" {
  for_each = local.members

  project = var.project_id
  role    = var.role
  member  = each.value

  condition {
    title       = "nullplatform-${var.name_prefix}-secrets"
    description = "Secret Manager access limited to secrets named ${var.name_prefix}__*"
    expression  = "resource.type == \"cloudresourcemanager.googleapis.com/Project\" || resource.name.startsWith(\"${local.secret_name_prefix}\")"
  }

  depends_on = [google_project_service.secretmanager]
}
