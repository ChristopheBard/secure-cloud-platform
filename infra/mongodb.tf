# VM MongoDB, avec les faiblesses VOLONTAIRES demandées par l'exercice :
#   - Linux obsolète de plus d'un an (Ubuntu 20.04, fin du support standard en mai 2025)
#   - MongoDB obsolète de plus d'un an (4.4, fin de vie en février 2024)
#   - SSH ouvert à Internet (security_groups.tf)
#   - rôle IAM trop permissif : la VM peut créer des VM (iam.tf)
#   - sauvegardes quotidiennes dans un bucket public (backups.tf)
#
# Ce qui reste correct, comme demandé : MongoDB n'est joignable que depuis le réseau Kubernetes,
# et l'authentification est obligatoire.

# Dernière image Ubuntu 20.04 publiée par Canonical (compte AWS 099720109477).
data "aws_ami" "ubuntu_focal" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

# Mots de passe générés par Terraform, stockés dans SSM Parameter Store (chiffrés), jamais dans git.
# Équivalent GCP : Secret Manager.
resource "random_password" "mongodb_admin" {
  length  = 32
  special = false # évite les caractères à échapper dans l'URI MongoDB
}

resource "random_password" "mongodb_app" {
  length  = 32
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "mongodb_admin_password" {
  #checkov:skip=CKV_AWS_337:Chiffré avec la clé SSM gérée par AWS ; une clé KMS dédiée est hors périmètre.
  name  = "/${var.project}/mongodb/admin-password"
  type  = "SecureString"
  value = random_password.mongodb_admin.result
}

resource "aws_ssm_parameter" "mongodb_app_password" {
  #checkov:skip=CKV_AWS_337:Chiffré avec la clé SSM gérée par AWS.
  name  = "/${var.project}/mongodb/app-password"
  type  = "SecureString"
  value = random_password.mongodb_app.result
}

# URI complète lue par la pipeline app pour créer le Secret Kubernetes,
# lui-même exposé à l'application en variable d'environnement MONGODB_URI.
resource "aws_ssm_parameter" "mongodb_uri" {
  #checkov:skip=CKV_AWS_337:Chiffré avec la clé SSM gérée par AWS.
  name  = "/${var.project}/app/mongodb-uri"
  type  = "SecureString"
  value = "mongodb://tasky:${random_password.mongodb_app.result}@${aws_instance.mongodb.private_ip}:27017/go-mongodb?authSource=admin"
}

resource "aws_ssm_parameter" "jwt_secret" {
  #checkov:skip=CKV_AWS_337:Chiffré avec la clé SSM gérée par AWS.
  name  = "/${var.project}/app/jwt-secret"
  type  = "SecureString"
  value = random_password.jwt_secret.result
}

resource "aws_key_pair" "mongodb" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "${var.project}-mongodb"
  public_key = var.ssh_public_key
}

resource "aws_instance" "mongodb" {
  #checkov:skip=CKV_AWS_88:INTENTIONNEL (exercice) - VM dans un subnet public avec une IP publique.
  #checkov:skip=CKV_AWS_126:Monitoring détaillé (1 min) payant, inutile pour la démo.
  #checkov:skip=CKV_AWS_135:t3 est optimisé EBS par défaut.
  #checkov:skip=CKV2_AWS_41:Faux positif - un rôle IAM est bien attaché via l'instance profile.
  ami                         = data.aws_ami.ubuntu_focal.id
  instance_type               = var.mongodb_instance_type
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true # INTENTIONNEL : VM exposée à Internet
  vpc_security_group_ids      = [aws_security_group.mongodb.id]
  iam_instance_profile        = aws_iam_instance_profile.mongodb.name
  key_name                    = var.ssh_public_key != "" ? aws_key_pair.mongodb[0].key_name : null

  # Contrôle PRÉVENTIF : IMDSv2 obligatoire. Une faille SSRF ne peut plus lire les identifiants
  # du rôle IAM via l'adresse de métadonnées (le vecteur de la fuite Capital One en 2019).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # Script exécuté au premier démarrage : installe MongoDB 4.4, crée les utilisateurs,
  # active l'authentification et programme la sauvegarde quotidienne.
  user_data = templatefile("${path.module}/templates/mongodb_userdata.sh.tftpl", {
    region               = var.region
    admin_password_param = aws_ssm_parameter.mongodb_admin_password.name
    app_password_param   = aws_ssm_parameter.mongodb_app_password.name
    backup_bucket        = aws_s3_bucket.backups.bucket
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.project}-mongodb" }

  # On ne veut pas que Terraform recrée la VM (et perde les données) à chaque nouvelle image Ubuntu 20.04.
  lifecycle {
    ignore_changes = [ami]
  }
}
