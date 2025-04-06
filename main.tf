provider "aws" {
  region = "us-east-1"
}

terraform {
  required_version = ">= 1.8.2"
  backend "s3" {
    bucket = "sctp-ce8-tfstate-unique"
    key    = "yk-s3-tf-ci.tfstate"
    region = "us-east-1"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0, < 4.0"
    }
  }
}


data "aws_caller_identity" "current" {}

locals {
  name_prefix = split("/", data.aws_caller_identity.current.arn)[1]
  account_id  = data.aws_caller_identity.current.account_id
}

resource "aws_kms_key" "default" {
  description         = "KMS Key for default encryption of S3 buckets"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-consolepolicy-3"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::255945442255:user/ykwong_ce9"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow S3 to use the key"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "kms:Encrypt"
        Resource = "*"
      }
    ]
  })

}

resource "aws_s3_bucket" "s3_tf" {
  bucket = join("-", [local.name_prefix, "s3-tf-bkt", local.account_id])
  # Enable default encryption using KMS
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3-kms" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.default.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "s3-versioning" {
  bucket = aws_s3_bucket.s3_tf.id
  versioning_configuration {
    status = "Enabled"
  }
}


resource "aws_s3_bucket_public_access_block" "s3-public-access" {
  bucket = aws_s3_bucket.s3_tf.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "topic" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = ["arn:aws:sns:*:*:s3-event-notification-topic"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.s3_tf.arn, aws_s3_bucket.destination.arn]
    }
  }
}
resource "aws_sns_topic" "topic" {
  name              = "s3-event-notification-topic"
  policy            = data.aws_iam_policy_document.topic.json
  kms_master_key_id = aws_kms_key.default.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.s3_tf.id

  topic {
    topic_arn     = aws_sns_topic.topic.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".log"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "s3-lifecycle" {
  bucket = aws_s3_bucket.s3_tf.id
  rule {
    id     = "Send to Glacier after 30 days"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    filter {
      prefix = ""
    }
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }
}


# Replication 

resource "aws_iam_role" "replication" {
  name               = "tf-iam-role-replication-s3"
  assume_role_policy = data.aws_iam_policy_document.dest-assume_role.json
}

data "aws_iam_policy_document" "replication" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]

    resources = [aws_s3_bucket.destination.arn]
  }
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]

    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]

    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }
}

resource "aws_iam_policy" "replication" {
  name   = "tf-iam-role-policy-replication-s3"
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_iam_role_policy_attachment" "replication" {
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}

resource "aws_s3_bucket" "destination" {
  bucket = "tf-test-bucket-destination-s3"
}


resource "aws_s3_bucket_acl" "source_bucket_acl" {
  provider = aws

  bucket = aws_s3_bucket.s3_tf.id
  acl    = "private"
}


resource "aws_s3_bucket_replication_configuration" "replication" {
  provider = aws
  # Must have bucket versioning enabled first
  depends_on = [aws_s3_bucket_versioning.s3-versioning]

  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    id = "replication-config"

    filter {
      prefix = ""
    }

    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.destination.arn
      storage_class = "STANDARD"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dest-kms" {
  bucket = aws_s3_bucket.destination.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.default.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "dest-versioning" {
  bucket = aws_s3_bucket.destination.id
  versioning_configuration {
    status = "Enabled"
  }
}


resource "aws_s3_bucket_public_access_block" "dest-public-access" {
  bucket = aws_s3_bucket.destination.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}



data "aws_iam_policy_document" "dest-topic" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = ["arn:aws:sns:*:*:s3-event-notification-topic"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.destination.arn]
    }
  }
}
resource "aws_sns_topic" "dest-topic" {
  name              = "s3-event-notification-topic"
  policy            = data.aws_iam_policy_document.dest-topic.json
  kms_master_key_id = aws_kms_key.default.arn
}

resource "aws_s3_bucket_notification" "dest-bucket_notification" {
  bucket = aws_s3_bucket.destination.id

  topic {
    topic_arn     = aws_sns_topic.topic.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".log"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "dest-s3-lifecycle" {
  bucket = aws_s3_bucket.destination.id
  rule {
    id     = "Send to Glacier after 30 days"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    filter {
      prefix = ""
    }
    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }
}

data "aws_iam_policy_document" "dest-assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Access logging for bucket s3_tf

resource "aws_s3_bucket_acl" "s3_tf" {
  bucket = aws_s3_bucket.s3_tf.id
  acl    = "private"
}

resource "aws_s3_bucket_acl" "log_bucket_acl" {
  bucket = aws_s3_bucket.s3_tf.id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_logging" "example" {
  bucket = aws_s3_bucket.destination.id

  target_bucket = aws_s3_bucket.s3_tf.id
  target_prefix = "log/"
}