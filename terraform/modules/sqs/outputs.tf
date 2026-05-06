output "queue_url" {
  description = "SQS queue URL — used in KEDA ScaledObject and worker deployment config"
  value       = aws_sqs_queue.keda_demo.url
}

output "queue_arn" {
  description = "SQS queue ARN — used in IAM policies"
  value       = aws_sqs_queue.keda_demo.arn
}

output "queue_name" {
  description = "SQS queue name — used in CloudWatch metric dimensions for native HPA"
  value       = aws_sqs_queue.keda_demo.name
}

output "dlq_url" {
  description = "Dead-letter queue URL — messages land here after 3 failed processing attempts"
  value       = aws_sqs_queue.keda_demo_dlq.url
}

output "dlq_arn" {
  description = "Dead-letter queue ARN"
  value       = aws_sqs_queue.keda_demo_dlq.arn
}

output "worker_policy_arn" {
  description = "IAM policy ARN for worker pods — attach to the worker IAM role"
  value       = aws_iam_policy.worker_sqs.arn
}
