################################################################################
# SQS Module
# Creates SQS queues used as KEDA scaling triggers
################################################################################

resource "aws_sqs_queue" "keda_demo" {
  name                       = "${var.name_prefix}-keda-demo"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 3600
  receive_wait_time_seconds  = 20 # Long polling
  visibility_timeout_seconds = 60

  tags = var.tags
}

resource "aws_sqs_queue" "keda_demo_dlq" {
  name = "${var.name_prefix}-keda-demo-dlq"
  tags = var.tags
}

resource "aws_sqs_queue_redrive_policy" "keda_demo" {
  queue_url = aws_sqs_queue.keda_demo.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.keda_demo_dlq.arn
    maxReceiveCount     = 3
  })
}

# IAM policy for worker pods to consume from SQS
resource "aws_iam_policy" "worker_sqs" {
  name        = "${var.name_prefix}-worker-sqs-policy"
  description = "Allows worker pods to send/receive SQS messages"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = [
          aws_sqs_queue.keda_demo.arn,
        ]
      },
      {
        # For load generator script
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:SendMessageBatch",
        ]
        Resource = [
          aws_sqs_queue.keda_demo.arn,
        ]
      }
    ]
  })
}

# Outputs are in outputs.tf
