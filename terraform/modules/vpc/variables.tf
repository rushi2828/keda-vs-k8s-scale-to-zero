variable "name" {
  description = "Name prefix used for all VPC resources"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used in subnet tags so Karpenter can discover them"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives 65,536 IPs — plenty for a demo."
  type        = string
  default     = "10.0.0.0/16"
}

variable "region" {
  description = "AWS region — used for VPC endpoint service names"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
