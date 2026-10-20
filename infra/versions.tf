# Stack principale. Elle est déployée UNIQUEMENT par la pipeline GitHub Actions,
# jamais à la main depuis un poste.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Le state est stocké dans le bucket S3 créé par bootstrap/.
  # Le nom du bucket contient l'ID du compte, donc on le donne au moment de l'init :
  #   terraform init -backend-config="bucket=<TF_STATE_BUCKET>"
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true # verrou natif S3 (Terraform >= 1.10) : deux apply ne peuvent pas tourner en même temps
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Repo      = "secure-cloud-platform"
    }
  }
}
