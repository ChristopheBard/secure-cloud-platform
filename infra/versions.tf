# Stack principale. Elle est déployée UNIQUEMENT par la pipeline GitHub Actions,
# jamais à la main depuis un poste.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Génère les mots de passe MongoDB et la clé JWT de l'application (stockés dans SSM, jamais dans git).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Le state est stocké dans le bucket S3 créé par bootstrap/.
  # Le nom du bucket et la région dépendent du compte, donc on les donne au moment de l'init :
  #   terraform init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="region=<AWS_REGION>"
  backend "s3" {
    key          = "infra/terraform.tfstate"
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

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
