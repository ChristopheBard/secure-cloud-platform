# Security groups (pare-feu attachés à chaque ressource réseau).
# Équivalent GCP : règles de firewall ciblant des tags ou des service accounts.
#
# Ils sont "chaînés" : les règles référencent d'autres security groups, pas des adresses IP.
#   Internet --80/443--> ALB --8080--> conteneurs --443--> endpoints (+ S3)
# Avantage : si on passe de 2 à 200 conteneurs, les règles restent justes sans rien changer.
#
# Un security group est "stateful" : la réponse à une connexion autorisée repasse automatiquement.

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Load balancer public"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-alb" }
}

resource "aws_security_group" "app" {
  name        = "${var.project}-app"
  description = "Conteneurs Fargate - joignables uniquement depuis l'ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-app" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.project}-endpoints"
  description = "VPC endpoints - joignables uniquement depuis les conteneurs"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-endpoints" }
}


# ALB : ouvert à Internet en 80 et 443, ne peut parler qu'aux conteneurs.

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:Point d'entrée web public. Le port 80 redirige vers HTTPS dès qu'un domaine est configuré.
  security_group_id = aws_security_group.alb.id
  description       = "HTTP depuis Internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS depuis Internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Vers les conteneurs uniquement"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}


# Conteneurs : n'acceptent que l'ALB, ne peuvent joindre que les endpoints et S3.

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Depuis l'ALB uniquement"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_vpc_security_group_egress_rule" "app_to_endpoints" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTPS vers les VPC endpoints"
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# Une "prefix list" est la liste des plages IP de S3 dans la région, maintenue par AWS.
resource "aws_vpc_security_group_egress_rule" "app_to_s3" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS vers S3 via le gateway endpoint (couches des images ECR)"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}


# Endpoints : n'acceptent que les conteneurs.

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_app" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS depuis les conteneurs uniquement"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
