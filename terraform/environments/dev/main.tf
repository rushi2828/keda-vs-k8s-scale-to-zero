################################################################################
# Dev Environment — Root Module
# Wires together: VPC → EKS → IAM → SQS → Karpenter → Helm releases
################################################################################

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

locals {
  name   = "keda-vs-hpa-demo"
  region = var.aws_region

  tags = {
    Project     = "keda-vs-native-hpa"
    Environment = "dev"
    ManagedBy   = "terraform"
    Article     = "medium-demo"
  }
}

################################################################################
# 1. VPC
################################################################################

module "vpc" {
  source       = "../../modules/vpc"
  name         = local.name
  cluster_name = local.name
  vpc_cidr     = "10.0.0.0/16"
  region       = var.aws_region
  tags         = local.tags
}

################################################################################
# 2. EKS Cluster
################################################################################

module "eks" {
  source             = "../../modules/eks"
  cluster_name       = local.name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  tags               = local.tags
}

################################################################################
# 3. SQS Queues
################################################################################

module "sqs" {
  source      = "../../modules/sqs"
  name_prefix = local.name
  tags        = local.tags
}

################################################################################
# 4. IAM Roles (KEDA operator, SQS workers, Karpenter nodes)
################################################################################

module "iam" {
  source            = "../../modules/iam"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  sqs_queue_arns    = [module.sqs.queue_arn, module.sqs.dlq_arn]
  tags              = local.tags
}

################################################################################
# 5. Karpenter Helm Release
################################################################################

resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.3.3"
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [<<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      interruptionQueue: ${module.eks.cluster_name}
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${module.iam.keda_operator_role_arn}
    EOT
  ]

  depends_on = [module.eks]
}

resource "kubernetes_manifest" "karpenter_node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      role             = module.iam.karpenter_node_role_name
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "kubernetes.io/cluster/${module.eks.cluster_name}" = "owned" } }
      ]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs        = { volumeSize = "20Gi", volumeType = "gp3", encrypted = true }
      }]
    }
  }
  depends_on = [helm_release.karpenter]
}

resource "kubernetes_manifest" "karpenter_node_pool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "default" }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = ["m5.large", "m5.xlarge", "m5a.large"] },
          ]
        }
      }
      limits      = { cpu = "100", memory = "400Gi" }
      disruption  = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "30s" }
    }
  }
  depends_on = [kubernetes_manifest.karpenter_node_class]
}
