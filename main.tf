provider "aws" {
  region = "us-east-1"
}

terraform {
  required_version = ">= 0.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0, < 4.0"  # Version constraint for AWS provider
    }
  }
  
  backend "s3" {
    bucket = "sctp-ce8-tfstate-unique"
    key    = "yk-s3-tf-ci.tfstate"
    region = "us-east-1"
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = split("/", data.aws_caller_identity.current.arn)[1]
  account_id  = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket" "s3_tf" {
  bucket = local.name_prefix-s3-tf-bkt-local.account_id
}