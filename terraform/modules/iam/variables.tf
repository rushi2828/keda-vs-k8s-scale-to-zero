variable "cluster_name" {
  description = "EKS cluster name — used as prefix for IAM resource names"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS cluster — required for IRSA"
  type        = string
}

variable "sqs_queue_arns" {
  description = "List of SQS queue ARNs that KEDA and workers need access to"
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to all IAM resources"
  type        = map(string)
  default     = {}
}
