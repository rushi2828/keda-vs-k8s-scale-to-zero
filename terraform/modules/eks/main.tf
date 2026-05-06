################################################################################
# EKS Cluster Module
# Creates EKS cluster with managed node groups + Karpenter for scale-to-zero
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version # "1.36" to get HPAScaleToZero default-on

  cluster_endpoint_public_access = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    metrics-server = {
      most_recent = true
    }
  }

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  # Managed node group for system pods (Karpenter, KEDA, monitoring)
  eks_managed_node_groups = {
    system = {
      name           = "system-nodes"
      instance_types = ["m5.large"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2

      labels = {
        role = "system"
      }

      taints = {
        system = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Enable IRSA for KEDA and other add-ons
  enable_irsa = true

  # Feature gates for K8s 1.36 HPAScaleToZero
  cluster_upgrade_policy = {
    support_type = "STANDARD"
  }

  tags = var.tags
}

################################################################################
# Karpenter - for node-level scale-to-zero
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  # Use EKS Pod Identity (preferred over IRSA in 1.36+)
  enable_pod_identity             = true
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# IAM roles for KEDA and workers are managed in the IAM module (../../modules/iam)
# The eks module only owns cluster infrastructure — not IAM roles.

# Outputs are in outputs.tf
