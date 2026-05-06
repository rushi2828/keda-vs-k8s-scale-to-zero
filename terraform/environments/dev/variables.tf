variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_version" {
  description = "Kubernetes version. 1.36 enables HPAScaleToZero by default"
  type        = string
  default     = "1.36"
}
