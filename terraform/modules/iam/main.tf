################################################################################
# IAM Module
# Creates all IAM roles needed for the project:
#   1. KEDA operator role  — lets KEDA read SQS queue metrics
#   2. Worker pod role     — lets worker pods consume SQS messages
#   3. Karpenter node role — lets Karpenter launch EC2 instances
#
# WHY IRSA (IAM Roles for Service Accounts)?
# Instead of putting AWS credentials (Access Keys) in your pods — which is a
# security risk — IRSA lets a Kubernetes ServiceAccount assume an IAM role
# automatically using OIDC federation. No secrets stored in the cluster.
################################################################################

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

################################################################################
# 1. KEDA Operator IAM Role
# KEDA needs to call SQS:GetQueueAttributes to read the queue depth.
# This role is assumed by the keda-operator pod via IRSA.
################################################################################

data "aws_iam_policy_document" "keda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_arn, "/^.*oidc-provider\\//", "")}:sub"
      values   = ["system:serviceaccount:keda:keda-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_arn, "/^.*oidc-provider\\//", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda_operator" {
  name               = "${var.cluster_name}-keda-operator"
  assume_role_policy = data.aws_iam_policy_document.keda_assume_role.json

  tags = var.tags
}

resource "aws_iam_policy" "keda_sqs_read" {
  name        = "${var.cluster_name}-keda-sqs-read"
  description = "Allows KEDA to read SQS metrics for scaling decisions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSQueueMetrics"
        Effect = "Allow"
        Action = [
          # Read queue depth for scaling decisions
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          # List queues — KEDA uses this for discovery
          "sqs:ListQueues",
        ]
        Resource = var.sqs_queue_arns
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          # CloudWatch is used by the native HPA approach via k8s-cloudwatch-adapter
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "keda_sqs" {
  role       = aws_iam_role.keda_operator.name
  policy_arn = aws_iam_policy.keda_sqs_read.arn
}

################################################################################
# 2. Worker Pod IAM Role
# The SQS worker pods need to receive and delete messages.
# This role is assumed by the sqs-worker pod via IRSA.
################################################################################

data "aws_iam_policy_document" "worker_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_arn, "/^.*oidc-provider\\//", "")}:sub"
      values   = ["system:serviceaccount:keda-demo:keda-worker"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_arn, "/^.*oidc-provider\\//", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name               = "${var.cluster_name}-sqs-worker"
  assume_role_policy = data.aws_iam_policy_document.worker_assume_role.json

  tags = var.tags
}

resource "aws_iam_policy" "worker_sqs" {
  name        = "${var.cluster_name}-worker-sqs"
  description = "Allows SQS worker pods to consume and delete messages"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeMessages"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:DeleteMessageBatch",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = var.sqs_queue_arns
      },
      {
        # For the load-generator.sh script — sends test messages
        Sid    = "SendMessages"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:SendMessageBatch",
        ]
        Resource = var.sqs_queue_arns
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_sqs" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.worker_sqs.arn
}

################################################################################
# 3. Karpenter Node IAM Role
# EC2 instances launched by Karpenter need permissions to:
#   - Join the EKS cluster
#   - Pull container images from ECR
#   - Use SSM for node management
################################################################################

data "aws_iam_policy_document" "karpenter_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume.json

  tags = var.tags
}

# Attach AWS managed policies required for EKS worker nodes
resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",  # For kubectl exec + node debugging
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

# Instance profile wraps the role so EC2 instances can use it
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name

  tags = var.tags
}
