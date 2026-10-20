# Registre privé des images Docker.
# Équivalent GCP : Artifact Registry (+ Artifact Analysis pour le scan).

resource "aws_ecr_repository" "app" {
  #checkov:skip=CKV_AWS_136:Chiffrement AES-256 activé ; une clé KMS dédiée coûte sans apporter de valeur pour la démo.
  name = "${var.project}-app"

  # Tags immuables : un tag (= le SHA du commit) désigne toujours la même image,
  # personne ne peut la remplacer en douce.
  image_tag_mutability = "IMMUTABLE"

  force_delete = true # permet le terraform destroy même s'il reste des images

  # Scan de vulnérabilités à chaque push. C'est la "détection" côté cloud,
  # en complément de Trivy qui fait la "prévention" dans la pipeline.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# On ne garde que les 10 dernières images (coût, et moins de vieilles images vulnérables qui traînent).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Garder les 10 dernieres images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
