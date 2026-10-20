# Les VPC endpoints remplacent les NAT Gateways.
# Équivalent GCP : Private Google Access / Private Service Connect.
#
# Sans accès Internet, les conteneurs ont quand même besoin de 3 services AWS :
#   ecr.api + ecr.dkr : télécharger l'image Docker
#   s3                : ECR stocke les couches de l'image dans S3
#   logs              : envoyer les logs vers CloudWatch
# Les endpoints leur donnent accès à ces services via des IP privées, sans passer par Internet.

# Endpoints de type "Interface" : une carte réseau dans chaque subnet privé (payant, ~7 $/mois par AZ).
# for_each crée un endpoint pour chaque élément de la liste.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["ecr.api", "ecr.dkr", "logs"])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true # les noms AWS habituels (ex : logs.eu-west-3.amazonaws.com) pointent vers ces IP privées

  tags = { Name = "${var.project}-vpce-${each.key}" }
}

# Endpoint de type "Gateway" pour S3 : juste une route dans la table privée. Gratuit.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-vpce-s3" }
}
