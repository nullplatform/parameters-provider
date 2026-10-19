locals {
  # Workload Identity Federation principal of the agent's KSA. Granting it
  # directly means the agent needs no GCP service account annotation.
  workload_identity_member = var.kubernetes_service_account.enable ? (
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${coalesce(var.kubernetes_service_account.workload_pool, "${var.project_id}.svc.id.goog")}/subject/ns/${var.kubernetes_service_account.namespace}/sa/${var.kubernetes_service_account.name}"
  ) : ""

  role = var.custom_role.enable ? google_project_iam_custom_role.provider[0].id : var.role

  members = toset(compact(concat([local.workload_identity_member], var.members)))

  # Every secret the provider owns is named "<prefix>__..." (see naming).
  secret_name_prefix = "projects/${data.google_project.this.number}/secrets/${var.name_prefix}__"
}
