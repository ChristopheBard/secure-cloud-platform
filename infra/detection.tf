# Contrôles DÉTECTIFS natifs AWS : ils ne bloquent rien, ils voient et alertent.
#
#   GuardDuty    : détection de menaces (scans SSH, appels API anormaux, activité suspecte dans EKS).
#                  Équivalent GCP : Security Command Center (Event Threat Detection).
#   AWS Config   : vérifie en continu la configuration des ressources par rapport à des règles.
#                  Équivalent GCP : Security Health Analytics / Config Validator.
#   Security Hub : tableau de bord unique (GuardDuty + Config) avec un score de conformité.
#   EventBridge  : envoie les découvertes GuardDuty par email (SNS) à l'équipe sécurité.


# GuardDuty

resource "aws_guardduty_detector" "main" {
  #checkov:skip=CKV2_AWS_3:Compte unique (lab), pas d'organisation AWS.
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}

# Analyse des logs d'audit Kubernetes (ex : création d'un binding cluster-admin, accès anonyme).
resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.main[0].id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

# Analyse des accès aux données S3 (ex : téléchargement massif depuis une IP inconnue).
resource "aws_guardduty_detector_feature" "s3_data_events" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.main[0].id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

# Toute découverte GuardDuty de sévérité moyenne ou plus (>= 4) part par email.
resource "aws_cloudwatch_event_rule" "guardduty" {
  name        = "${var.project}-guardduty-findings"
  description = "Découvertes GuardDuty de sévérité moyenne ou haute"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 4] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule = aws_cloudwatch_event_rule.guardduty.name
  arn  = aws_sns_topic.alerts.arn
}


# AWS Config : enregistreur + règles managées par AWS

resource "aws_s3_bucket" "config" {
  #checkov:skip=CKV_AWS_144:Pas de réplication inter-régions pour une démo.
  #checkov:skip=CKV_AWS_145:Chiffrement AES-256 géré par AWS suffisant pour la démo.
  #checkov:skip=CKV_AWS_18:Bucket technique d'AWS Config, accès déjà tracés par CloudTrail.
  #checkov:skip=CKV2_AWS_62:Pas besoin de notifications d'événements.
  #checkov:skip=CKV2_AWS_61:Conservé pendant toute la durée du lab.
  #checkov:skip=CKV_AWS_21:Historique déjà conservé par AWS Config.
  count         = var.enable_config ? 1 : 0
  bucket        = "${var.project}-config-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_config ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ConfigAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = { StringEquals = { "AWS:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "ConfigWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "AWS:SourceAccount" = local.account_id, "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.config]
}

data "aws_iam_policy_document" "config_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  count              = var.enable_config ? 1 : 0
  name               = "${var.project}-config"
  assume_role_policy = data.aws_iam_policy_document.config_trust.json
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_bucket" {
  count = var.enable_config ? 1 : 0
  name  = "write-config-bucket"
  role  = aws_iam_role.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetBucketAcl"]
      Resource = [aws_s3_bucket.config[0].arn, "${aws_s3_bucket.config[0].arn}/*"]
    }]
  })
}

# On n'enregistre que les types de ressources utiles à la démo (le coût dépend du nombre d'enregistrements).
resource "aws_config_configuration_recorder" "main" {
  #checkov:skip=CKV2_AWS_48:Enregistrement limité aux types utiles à la démo, pour maîtriser le coût.
  count    = var.enable_config ? 1 : 0
  name     = "${var.project}-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported = false
    resource_types = [
      "AWS::EC2::Instance",
      "AWS::EC2::SecurityGroup",
      "AWS::S3::Bucket",
      "AWS::IAM::Role",
      "AWS::IAM::Policy",
      "AWS::EKS::Cluster",
      "AWS::CloudTrail::Trail",
    ]
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_config ? 1 : 0
  name           = "${var.project}-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].bucket
  depends_on     = [aws_config_configuration_recorder.main, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "main" {
  #checkov:skip=CKV2_AWS_45:Idem, enregistrement limité aux types utiles à la démo.
  count      = var.enable_config ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# Règles managées : chacune correspond à une faiblesse de l'environnement.
# En démo, les 4 premières sont "NON_COMPLIANT" : c'est la preuve que la détection fonctionne.
locals {
  config_rules = {
    "s3-bucket-public-read-prohibited" = "S3_BUCKET_PUBLIC_READ_PROHIBITED" # bucket des sauvegardes public
    "restricted-ssh"                   = "INCOMING_SSH_DISABLED"            # SSH ouvert à 0.0.0.0/0
    "ec2-instance-no-public-ip"        = "EC2_INSTANCE_NO_PUBLIC_IP"        # VM MongoDB avec IP publique
    "eks-endpoint-no-public-access"    = "EKS_ENDPOINT_NO_PUBLIC_ACCESS"    # API EKS publique
    "ec2-imdsv2-check"                 = "EC2_IMDSV2_CHECK"                 # COMPLIANT : IMDSv2 imposé
    "cloudtrail-enabled"               = "CLOUD_TRAIL_ENABLED"              # COMPLIANT : audit actif
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = var.enable_config ? local.config_rules : {}
  name     = "${var.project}-${each.key}"

  source {
    owner             = "AWS"
    source_identifier = each.value
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}


# Security Hub : agrège GuardDuty et Config, et note le compte sur un standard AWS.

resource "aws_securityhub_account" "main" {
  count                    = var.enable_securityhub ? 1 : 0
  enable_default_standards = false
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count         = var.enable_securityhub ? 1 : 0
  standards_arn = "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}
