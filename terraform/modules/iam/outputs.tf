output "keda_operator_role_arn" {
  description = "ARN of the KEDA operator IAM role — annotate the keda-operator ServiceAccount with this"
  value       = aws_iam_role.keda_operator.arn
}

output "worker_role_arn" {
  description = "ARN of the SQS worker IAM role — annotate the keda-worker ServiceAccount with this"
  value       = aws_iam_role.worker.arn
}

output "karpenter_node_role_arn" {
  description = "ARN of the Karpenter node IAM role — referenced in EC2NodeClass"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_node_role_name" {
  description = "Name of the Karpenter node IAM role"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_instance_profile_name" {
  description = "Instance profile name for Karpenter EC2NodeClass"
  value       = aws_iam_instance_profile.karpenter_node.name
}
