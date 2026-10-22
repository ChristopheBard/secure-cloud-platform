# Bucket des sauvegardes MongoDB.
# INTENTIONNEL (exercice) : lecture ET listage publics. N'importe qui sur Internet peut lister
# et télécharger les dumps de la base, donc les données des utilisateurs (et les hash de leurs mots de passe).

resource "aws_s3_bucket" "backups" {
  #checkov:skip=CKV_AWS_20:INTENTIONNEL (exercice) - lecture publique des sauvegardes.
  #checkov:skip=CKV_AWS_70:INTENTIONNEL (exercice) - politique de bucket ouverte à tous.
  #checkov:skip=CKV2_AWS_6:INTENTIONNEL (exercice) - Block Public Access désactivé sur ce bucket.
  #checkov:skip=CKV_AWS_144:Pas de réplication inter-régions pour une démo.
  #checkov:skip=CKV_AWS_145:Chiffrement AES-256 géré par AWS ; une clé KMS rendrait la lecture publique impossible.
  #checkov:skip=CKV_AWS_18:Les lectures sont tracées par les data events CloudTrail (cloudtrail.tf).
  #checkov:skip=CKV2_AWS_62:Pas besoin de notifications d'événements.
  #checkov:skip=CKV_AWS_21:Versioning inutile pour des sauvegardes horodatées.
  #checkov:skip=CKV2_AWS_61:Cycle de vie inutile pour la durée du lab.
  bucket        = "${var.project}-mongodb-backups-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# INTENTIONNEL : on désactive le "Block Public Access" sur ce bucket, sinon la politique publique serait refusée.
resource "aws_s3_bucket_public_access_block" "backups" {
  #checkov:skip=CKV_AWS_53:INTENTIONNEL (exercice).
  #checkov:skip=CKV_AWS_54:INTENTIONNEL (exercice).
  #checkov:skip=CKV_AWS_55:INTENTIONNEL (exercice).
  #checkov:skip=CKV_AWS_56:INTENTIONNEL (exercice).
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true # les ACL restent bloquées : l'ouverture passe uniquement par la politique ci-dessous
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

# INTENTIONNEL : Principal "*" = tout Internet peut lister le bucket et lire les fichiers.
resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicList"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.backups.arn
      },
      {
        Sid       = "PublicRead"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.backups.arn}/*"
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.backups]
}
