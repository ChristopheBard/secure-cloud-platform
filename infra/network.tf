# Réseau sur 2 zones de disponibilité (AZ).
#   subnets publics : seulement l'ALB (route vers l'Internet Gateway)
#   subnets privés  : les conteneurs + les VPC endpoints, AUCUNE route vers Internet
#
# Différence avec GCP : sur AWS un subnet appartient à UNE zone (sur GCP il est régional).
# D'où 2 subnets publics + 2 subnets privés pour couvrir 2 AZ.

# Les 2 AZ sont fixées dans variables.tf (et non lues dynamiquement) :
# l'infra reste identique même si AWS ajoute une zone dans la région (alerte Checkov CKV_AWS_394).
locals {
  azs = var.availability_zones
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # obligatoire pour que les VPC endpoints aient des noms DNS privés

  tags = { Name = "${var.project}-vpc" }
}

# Le security group "par défaut" du VPC autorise tout entre ses membres.
# On le reprend en main pour le vider : aucune règle entrante ni sortante.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-default-locked" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# count = 2 : Terraform crée 2 subnets, count.index vaut 0 puis 1.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24 et 10.0.1.0/24
  map_public_ip_on_launch = false                                    # l'ALB a ses propres IP publiques, rien d'autre n'en a besoin

  tags = { Name = "${var.project}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10) # 10.0.10.0/24 et 10.0.11.0/24

  tags = { Name = "${var.project}-private-${local.azs[count.index]}" }
}

# Table de routage publique : tout ce qui sort va vers l'Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Table de routage privée : volontairement SANS route 0.0.0.0/0.
# Elle ne contient que la route "local" (interne au VPC) et la route vers S3 (ajoutée par endpoints.tf).
# Pas de NAT : un conteneur compromis ne peut pas envoyer de données vers Internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# VPC Flow Logs : journal de toutes les connexions réseau (acceptées ou refusées).
# Utile en investigation : "qui a parlé à qui, et quand".
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = { Name = "${var.project}-flow-logs" }
}
