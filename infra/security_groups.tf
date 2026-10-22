# Security groups (pare-feu attachés à chaque ressource réseau).
# Équivalent GCP : règles de firewall ciblant des tags ou des service accounts.
# Un security group est "stateful" : la réponse à une connexion autorisée repasse automatiquement.
#
# Les noeuds EKS et le load balancer utilisent les security groups créés par EKS Auto Mode.
# Ici, seulement celui de la VM MongoDB.

resource "aws_security_group" "mongodb" {
  name        = "${var.project}-mongodb"
  description = "VM MongoDB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-mongodb" }
}

# INTENTIONNEL (exercice) : SSH ouvert au monde entier.
resource "aws_vpc_security_group_ingress_rule" "mongodb_ssh_from_internet" {
  #checkov:skip=CKV_AWS_24:INTENTIONNEL (exercice) - SSH exposé à Internet.
  #checkov:skip=CKV_AWS_260:INTENTIONNEL (exercice).
  security_group_id = aws_security_group.mongodb.id
  description       = "SSH depuis Internet (faiblesse volontaire)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# MongoDB : uniquement depuis le réseau Kubernetes (les 2 subnets privés où tournent les pods).
resource "aws_vpc_security_group_ingress_rule" "mongodb_from_kubernetes" {
  count             = 2
  security_group_id = aws_security_group.mongodb.id
  description       = "MongoDB depuis les pods EKS uniquement"
  cidr_ipv4         = aws_subnet.private[count.index].cidr_block
  ip_protocol       = "tcp"
  from_port         = 27017
  to_port           = 27017
}

# Sortie : la VM doit télécharger MongoDB et joindre S3 / SSM (HTTPS + HTTP pour les dépôts apt).
resource "aws_vpc_security_group_egress_rule" "mongodb_https" {
  security_group_id = aws_security_group.mongodb.id
  description       = "HTTPS sortant (S3, SSM, depots)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "mongodb_http" {
  security_group_id = aws_security_group.mongodb.id
  description       = "HTTP sortant (depots apt Ubuntu)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
