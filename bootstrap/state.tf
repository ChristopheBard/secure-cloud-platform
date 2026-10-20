# Bucket S3 qui stocke le state de la stack infra/.
# Équivalent GCP : un bucket GCS utilisé comme backend Terraform.
#
# Le state décrit toute l'infra et peut contenir des valeurs sensibles,
# donc : privé, chiffré, versionné, et accessible uniquement en HTTPS.

# Récupère l'ID du compte AWS courant (utilisé pour avoir un nom de bucket unique).
data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  # Les lignes "checkov:skip" désactivent un contrôle Checkov précis, avec la justification.
  # Chaque exception est donc documentée dans le code et visible en revue de code.
  #checkov:skip=CKV_AWS_144:Pas de réplication inter-régions pour une démo.
  #checkov:skip=CKV_AWS_18:Les logs d'accès demanderaient un 2e bucket ; CloudTrail trace déjà les appels API.
  #checkov:skip=CKV2_AWS_62:Pas besoin de notifications d'événements sur ce bucket.
  #checkov:skip=CKV_AWS_145:Chiffrement AES-256 géré par AWS suffisant ; une clé KMS dédiée coûte sans apporter de valeur ici.
  bucket = local.state_bucket

  # Permet de supprimer le bucket même s'il contient des fichiers (terraform destroy après le panel).
  force_destroy = true
}

# Versioning : chaque version du state est conservée, on peut revenir en arrière après un mauvais apply.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Chiffrement au repos.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Interdit toute exposition publique, même par erreur.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Désactive les ACL S3 (ancien système de droits) : seuls les droits IAM comptent.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Ménage automatique : les anciennes versions du state sont supprimées après 90 jours.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse toute requête qui n'est pas en HTTPS.
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
