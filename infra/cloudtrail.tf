# Journal d'audit du plan de contrôle AWS : chaque appel d'API (console, CLI, pipeline, VM) est enregistré.
# Équivalent GCP : Cloud Audit Logs (Admin Activity + Data Access).
#
#   - toutes les régions, y compris les services globaux comme IAM
#   - validation d'intégrité des fichiers : on peut prouver qu'un log n'a pas été modifié
#   - copie dans CloudWatch Logs pour chercher et alerter en quelques secondes
#   - "data events" sur le bucket des sauvegardes : on sait QUI a téléchargé un dump

resource "aws_s3_bucket" "cloudtrail" {
  #checkov:skip=CKV_AWS_144:Pas de réplication inter-régions pour une démo.
  #checkov:skip=CKV_AWS_145:Chiffrement AES-256 géré par AWS suffisant pour la démo.
  #checkov:skip=CKV_AWS_18:Un bucket de logs d'accès pour le bucket de logs serait sans fin ; CloudTrail trace déjà les appels.
  #checkov:skip=CKV2_AWS_62:Pas besoin de notifications d'événements.
  #checkov:skip=CKV2_AWS_61:Logs conservés pendant toute la durée du lab.
  #checkov:skip=CKV_AWS_21:La validation d'intégrité CloudTrail protège déjà les fichiers.
  bucket        = "${var.project}-cloudtrail-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Seul le service CloudTrail de ce compte peut écrire ; tout accès non HTTPS est refusé.
data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${var.project}-trail"]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${var.project}-trail"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]
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

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket     = aws_s3_bucket.cloudtrail.id
  policy     = data.aws_iam_policy_document.cloudtrail_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  #checkov:skip=CKV_AWS_158:Chiffré par défaut avec une clé gérée par AWS.
  #checkov:skip=CKV_AWS_338:30 jours suffisent pour une démo.
  name              = "/aws/cloudtrail/${var.project}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "cloudtrail_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail" {
  name               = "${var.project}-cloudtrail"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_trust.json
}

resource "aws_iam_role_policy" "cloudtrail" {
  name = "write-cloudtrail-logs"
  role = aws_iam_role.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "main" {
  #checkov:skip=CKV_AWS_35:Chiffrement SSE-S3 du bucket ; une clé KMS dédiée est hors périmètre.
  #checkov:skip=CKV_AWS_252:Pas de notification SNS par fichier de log : les alertes passent par EventBridge.
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail.arn

  # Événements de gestion (création, modification, suppression de ressources) + lectures du bucket public.
  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "Backup bucket object access"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.backups.arn}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
