output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint — used by kubectl and Helm providers"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate — used by kubectl"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — passed to IAM module for IRSA role bindings"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (without https://)"
  value       = module.eks.cluster_oidc_issuer_url
}

output "karpenter_node_iam_role_name" {
  description = "Karpenter node IAM role name — used in EC2NodeClass"
  value       = module.karpenter.node_iam_role_name
}
