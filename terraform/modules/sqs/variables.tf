variable "name_prefix" {
  description = "Prefix for resource naming"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
