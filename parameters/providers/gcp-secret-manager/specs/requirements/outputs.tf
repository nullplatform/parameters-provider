output "members" {
  description = "IAM members granted conditional Secret Manager access."
  value       = local.members
}

output "secret_name_prefix" {
  description = "Resource-name prefix the IAM condition admits (projects/<number>/secrets/<prefix>__)."
  value       = local.secret_name_prefix
}
