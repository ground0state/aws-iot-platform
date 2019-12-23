variable "prefix" {
  default = "prefix"
}

variable "deploy_type" {
  default = "production"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

