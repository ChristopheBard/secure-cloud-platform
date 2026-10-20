# Application Load Balancer (ALB) : point d'entrée unique de l'application.
# Équivalent GCP : External Application Load Balancer.
#
# Il est placé dans les 2 subnets publics (un "noeud" par AZ) : si une AZ tombe, il continue de répondre.
#
# HTTPS dépend de la variable domain_name :
#   - vide       : l'ALB écoute en HTTP et transmet aux conteneurs (démo sans nom de domaine)
#   - renseignée : certificat ACM + écoute HTTPS, et le HTTP redirige vers HTTPS

locals {
  enable_https = var.domain_name != ""
}

resource "aws_lb" "main" {
  #checkov:skip=CKV_AWS_91:Les logs d'accès demandent un bucket S3 en plus ; les logs WAF et les métriques suffisent pour la démo.
  #checkov:skip=CKV_AWS_150:Protection contre la suppression désactivée pour pouvoir faire terraform destroy après la démo.
  #checkov:skip=CKV2_AWS_76:Log4j est couvert par KnownBadInputs (waf.tf). La liste AnonymousIp n'est pas activée : elle bloquerait les utilisateurs légitimes derrière un VPN.
  name                       = "${var.project}-alb"
  load_balancer_type         = "application"
  internal                   = false # accessible depuis Internet
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true # rejette les en-têtes HTTP malformés (protection contre le "request smuggling")
  enable_deletion_protection = false
}

# Target group = la liste des conteneurs vers lesquels l'ALB envoie le trafic.
# ECS y inscrit et désinscrit les conteneurs automatiquement.
resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:Le TLS s'arrête à l'ALB ; le trafic ALB -> conteneur reste dans les subnets privés.
  name        = "${var.project}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip" # obligatoire avec Fargate : chaque conteneur a sa propre IP
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 30 # laisse 30 s aux requêtes en cours avant de retirer un conteneur

  # L'ALB appelle /health toutes les 15 s. Un conteneur qui ne répond pas 200 ne reçoit plus de trafic.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:HTTP gardé seulement pour la démo sans domaine ; il redirige vers HTTPS dès qu'un domaine est défini.
  #checkov:skip=CKV_AWS_103:Idem (la politique TLS s'applique au listener HTTPS).
  #checkov:skip=CKV2_AWS_20:La redirection vers HTTPS dépend de var.domain_name.
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Avec un domaine : redirection vers HTTPS. Sans domaine : on transmet aux conteneurs.
  default_action {
    type             = local.enable_https ? "redirect" : "forward"
    target_group_arn = local.enable_https ? null : aws_lb_target_group.app.arn

    dynamic "redirect" {
      for_each = local.enable_https ? [1] : [] # bloc présent seulement si HTTPS est activé
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}


# Partie HTTPS : créée seulement si domain_name est renseigné (count = 1, sinon 0).

data "aws_route53_zone" "main" {
  count = local.enable_https ? 1 : 0
  name  = var.hosted_zone_name
}

# Certificat TLS gratuit, renouvelé automatiquement par AWS.
# Équivalent GCP : Certificate Manager.
resource "aws_acm_certificate" "main" {
  count             = local.enable_https ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS" # AWS vérifie qu'on possède le domaine via un enregistrement DNS

  lifecycle {
    create_before_destroy = true
  }
}

# Enregistrement DNS qui prouve à AWS qu'on possède le domaine.
resource "aws_route53_record" "cert_validation" {
  for_each = local.enable_https ? {
    for o in aws_acm_certificate.main[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

# Attend que le certificat soit validé avant de l'utiliser.
resource "aws_acm_certificate_validation" "main" {
  count                   = local.enable_https ? 1 : 0
  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_lb_listener" "https" {
  count             = local.enable_https ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # TLS 1.2 minimum, TLS 1.3 de préférence
  certificate_arn   = aws_acm_certificate_validation.main[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Fait pointer le nom de domaine vers l'ALB.
resource "aws_route53_record" "app" {
  count   = local.enable_https ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
