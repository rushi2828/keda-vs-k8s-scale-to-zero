################################################################################
# Outputs — printed after terraform apply
# Run: terraform output        (see all)
# Run: terraform output -raw sqs_queue_url   (get one value)
################################################################################

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "configure_kubectl" {
  description = "Run this command to connect kubectl to your cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "sqs_queue_url" {
  description = "SQS queue URL — used in KEDA manifests and load-generator script"
  value       = module.sqs.queue_url
}

output "sqs_queue_name" {
  description = "SQS queue name — used in CloudWatch metric dimensions"
  value       = module.sqs.queue_name
}

output "sqs_dlq_url" {
  description = "Dead-letter queue URL — check here if messages fail processing"
  value       = module.sqs.dlq_url
}

output "keda_operator_role_arn" {
  description = "Annotate keda-operator ServiceAccount with this ARN for IRSA"
  value       = module.iam.keda_operator_role_arn
}

output "worker_role_arn" {
  description = "Annotate keda-worker ServiceAccount with this ARN for IRSA"
  value       = module.iam.worker_role_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs where EKS nodes run"
  value       = module.vpc.private_subnet_ids
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}
