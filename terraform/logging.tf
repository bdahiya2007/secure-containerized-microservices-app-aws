# One central, private S3 bucket for log files, with a prefix per source:
#   alb/          ALB access logs (always on)
#   cloudtrail/   CloudTrail (enable_cloudtrail, default off)
# S3 server access logs for the central bucket (who read or changed the log files) go to a separate small
# bucket (enable_s3_access_logging, default off), so the central bucket never logs into itself.
# RDS logs cannot be delivered to S3 directly; with enable_rds_logs they go to CloudWatch Logs instead
# (see rds.tf). Writing them on to this bucket (CloudWatch Logs -> Firehose -> S3) is planned, not built.
#
# The only cost is S3 storage (cents) and each source expires on its own schedule. Every writer gets its own
# narrowly scoped statement in the bucket policy.
data "aws_elb_service_account" "main" {}

locals {
  log_bucket_name        = "${var.project_name}-logs-${data.aws_caller_identity.current.account_id}"
  access_log_bucket_name = "${var.project_name}-s3-access-logs-${data.aws_caller_identity.current.account_id}"
  trail_name             = "${var.project_name}-trail"
  # Built from its parts, not taken from the trail resource, so the bucket policy and the trail don't depend on each other
  trail_arn = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"
}

resource "aws_s3_bucket" "logs" {
  bucket = local.log_bucket_name

  # A demo bucket: terraform destroy removes it together with the logs. Turn this off for production.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB access logs support SSE-S3 only (not a customer-managed KMS key), so the bucket uses SSE-S3.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-alb-logs"
    status = "Enabled"

    filter {
      prefix = "alb/"
    }

    expiration {
      days = var.log_retention_days
    }
  }

  # CloudTrail is kept longer, because it is the audit record of who changed what
  rule {
    id     = "expire-cloudtrail-logs"
    status = "Enabled"

    filter {
      prefix = "cloudtrail/"
    }

    expiration {
      days = var.cloudtrail_log_retention_days
    }
  }

  # Applies to the whole bucket: clean up uploads that never finished
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ---- Bucket policy: one statement per writer, merged from the pieces below ----
data "aws_iam_policy_document" "logs_base" {
  # Only the regional Elastic Load Balancing account may write, and only under this account's alb/ prefix.
  statement {
    sid       = "AllowAlbToWriteLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# CloudTrail may write only for this trail, under cloudtrail/, and must hand ownership to the bucket owner.
data "aws_iam_policy_document" "logs_cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  statement {
    sid       = "AllowCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AllowCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

data "aws_iam_policy_document" "logs" {
  source_policy_documents = concat(
    [data.aws_iam_policy_document.logs_base.json],
    data.aws_iam_policy_document.logs_cloudtrail[*].json,
  )
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---- Optional sources (all off by default) ----

# CloudTrail records every API call in the account: who created, changed or deleted what. It is account-wide,
# not project-specific. The first trail's management events are free; the account had no other trail when this
# was written, so check `aws cloudtrail describe-trails` first (a second copy costs about $2 per 100,000 events).
resource "aws_cloudtrail" "main" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.logs.id
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.logs]
}

# ---- S3 server access logs for the central bucket, kept in a separate small bucket ----
# Writing them into the central bucket itself is allowed by AWS but can produce log records of the logs, so
# they go to their own bucket. S3 access logging does not check its permissions when it is created, so a wrong
# policy here fails silently: check that files appear.
resource "aws_s3_bucket" "s3_access_logs" {
  count  = var.enable_s3_access_logging ? 1 : 0
  bucket = local.access_log_bucket_name

  # A demo bucket: terraform destroy removes it together with the logs. Turn this off for production.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "s3_access_logs" {
  count                   = var.enable_s3_access_logging ? 1 : 0
  bucket                  = aws_s3_bucket.s3_access_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 server access logs can't be written to a bucket that uses a KMS key, so this bucket uses SSE-S3.
resource "aws_s3_bucket_server_side_encryption_configuration" "s3_access_logs" {
  count  = var.enable_s3_access_logging ? 1 : 0
  bucket = aws_s3_bucket.s3_access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "s3_access_logs" {
  count  = var.enable_s3_access_logging ? 1 : 0
  bucket = aws_s3_bucket.s3_access_logs[0].id

  rule {
    id     = "expire-s3-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# S3 server access logging may write only for the central bucket and this account, and only over TLS.
data "aws_iam_policy_document" "s3_access_logs" {
  count = var.enable_s3_access_logging ? 1 : 0

  statement {
    sid       = "AllowS3ServerAccessLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.s3_access_logs[0].arn}/central-logs/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.logs.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.s3_access_logs[0].arn, "${aws_s3_bucket.s3_access_logs[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "s3_access_logs" {
  count  = var.enable_s3_access_logging ? 1 : 0
  bucket = aws_s3_bucket.s3_access_logs[0].id
  policy = data.aws_iam_policy_document.s3_access_logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.s3_access_logs]
}

resource "aws_s3_bucket_logging" "logs" {
  count = var.enable_s3_access_logging ? 1 : 0

  bucket        = aws_s3_bucket.logs.id
  target_bucket = aws_s3_bucket.s3_access_logs[0].id
  target_prefix = "central-logs/"

  depends_on = [aws_s3_bucket_policy.s3_access_logs]
}
