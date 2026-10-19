variable "project_id" {
  description = "GCP project that holds the secrets. Must match the runtime provider config `setup.project_id` (and GCP_SECRET_MANAGER_PROJECT_ID)."
  type        = string
}

variable "name_prefix" {
  description = "Secret id prefix the IAM condition is scoped to. Must match the runtime provider config `setup.name_prefix` (default \"nullplatform\") — the coupling is by name, not by reference."
  type        = string
  default     = "nullplatform"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.name_prefix))
    error_message = "name_prefix may only contain letters, digits, '_' and '-' (Secret Manager secret id charset)."
  }
}

variable "kubernetes_service_account" {
  description = <<-EOT
    Grant the agent's Kubernetes service account through GKE Workload Identity
    Federation. The agent then authenticates via the metadata server with no GCP
    service account, annotation or key. Requires Workload Identity on the cluster
    and node pool (GKE_METADATA mode).
    Fields:
      enable        — set true to grant the KSA principal.
      namespace     — namespace of the agent's KSA (default "nullplatform-tools").
      name          — name of the agent's KSA (default "nullplatform-agent").
      workload_pool — workload identity pool; defaults to "<project_id>.svc.id.goog",
                      set it when the cluster lives in another project.
  EOT
  type = object({
    enable        = bool
    namespace     = optional(string, "nullplatform-tools")
    name          = optional(string, "nullplatform-agent")
    workload_pool = optional(string)
  })
  default = {
    enable = true
  }
}

variable "members" {
  description = "Extra IAM members to grant the same conditional access (e.g. \"serviceAccount:agent@project.iam.gserviceaccount.com\" for an agent that authenticates with a GCP service account)."
  type        = list(string)
  default     = []
}

variable "role" {
  description = "Role granted under the prefix condition. The default secretmanager.admin covers create / addVersion / access / delete; the condition is what keeps it least-privilege."
  type        = string
  default     = "roles/secretmanager.admin"

  # Restrict to Secret Manager roles so an accidental Owner/Editor can't be
  # granted project-wide through this module.
  validation {
    condition     = startswith(var.role, "roles/secretmanager.")
    error_message = "role must be a Secret Manager role (roles/secretmanager.*)."
  }
}

variable "enable_api" {
  description = "Enable secretmanager.googleapis.com on the project. Leave false when the API is managed elsewhere."
  type        = bool
  default     = false
}
