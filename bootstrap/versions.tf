# Stack "bootstrap" : à lancer UNE SEULE FOIS, en local, avec un accès admin.
#
# Pourquoi une stack séparée ? C'est le problème de l'oeuf et de la poule :
# la pipeline a besoin d'un rôle IAM et d'un bucket de state pour tourner,
# mais il faut bien que quelqu'un les crée avant elle.
#
# Ce qu'elle crée :
#   - le bucket S3 qui stocke le state Terraform de la stack infra/
#   - le fournisseur d'identité OIDC de GitHub
#   - les 3 rôles IAM utilisés par GitHub Actions (plan, apply, déploiement app sur EKS)
#
# Son propre state reste en local (fichier ignoré par git) : il est petit et ne bouge quasiment jamais.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # toute version 6.x, mais pas la 7 (évite les changements cassants)
    }
  }
}

provider "aws" {
  region = var.region

  # Tags ajoutés automatiquement sur toutes les ressources : on retrouve vite ce qui appartient au projet.
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform-bootstrap"
    }
  }
}
