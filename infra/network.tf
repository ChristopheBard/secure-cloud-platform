# Réseau sur 2 zones de disponibilité (AZ).
#   subnets publics : la VM MongoDB, le load balancer créé par l'Ingress, la NAT Gateway
#   subnets privés  : les noeuds et les pods du cluster EKS (aucune IP publique)
#
# Différence avec GCP : sur AWS, "public" ou "privé" n'est pas une étiquette, c'est la table de routage.
#   public = route 0.0.0.0/0 vers l'Internet Gateway : une ressource avec une IP publique est joignable depuis Internet
#   privé  = pas de route vers l'Internet Gateway : rien n'y est joignable depuis Internet, même par erreur
# Et un subnet appartient à UNE zone (sur GCP il est régional), d'où 2 + 2 subnets pour couvrir 2 AZ.

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:On ne prend que les 2 premières zones (slice) : une zone ajoutée par AWS ne change rien.
  state = "available"
}

locals {
  # Les 2 premières AZ de la région : le code fonctionne quelle que soit la région du lab.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

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

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24 et 10.0.1.0/24
  # Pas d'IP publique automatique : seule la VM MongoDB en demande une explicitement.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-public-${local.azs[count.index]}"
    # Indique à EKS où créer les load balancers publics demandés par un Ingress.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10) # 10.0.10.0/24 et 10.0.11.0/24

  tags = {
    Name                              = "${var.project}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
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

# NAT Gateway : permet aux noeuds EKS privés de SORTIR (télécharger les images, joindre les API AWS)
# sans être joignables depuis Internet. Équivalent GCP : Cloud NAT.
# Une seule NAT pour limiter le coût de la démo ; en production, une par AZ.
resource "aws_eip" "nat" {
  #checkov:skip=CKV2_AWS_19:Cette IP est attachée à la NAT Gateway, pas à une instance EC2.
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project}-nat" }

  depends_on = [aws_internet_gateway.main]
}

# Table de routage privée : la sortie passe par la NAT, il n'y a aucune entrée possible depuis Internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# VPC Flow Logs : journal de toutes les connexions réseau (acceptées ou refusées).
# Contrôle détectif : on y voit par exemple les tentatives de connexion SSH sur la VM depuis Internet.
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = { Name = "${var.project}-flow-logs" }
}
