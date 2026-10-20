# AWS WAF devant l'ALB : les attaques connues sont bloquées avant d'atteindre l'application.
# Équivalent GCP : Cloud Armor.
#
# On utilise des groupes de règles "managés" : écrits et mis à jour par AWS.
# Pas besoin de maintenir nous-mêmes des signatures d'attaques.

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project}-web-acl"
  scope = "REGIONAL" # REGIONAL pour un ALB (CLOUDFRONT serait pour un CDN global)

  # Par défaut on laisse passer ; les règles ci-dessous bloquent ce qui est suspect.
  default_action {
    allow {}
  }

  # Règle 1 : protections génériques (injections, XSS, requêtes anormales...).
  rule {
    name     = "aws-common-rules"
    priority = 10

    override_action {
      none {} # on applique les règles d'AWS telles quelles
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Règle 2 : motifs d'exploits connus, par exemple Log4Shell.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Règle 3 : adresses IP signalées comme malveillantes par AWS.
  rule {
    name     = "aws-ip-reputation"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # Règle 4 : anti-abus, une même IP est bloquée au-delà de 1000 requêtes en 5 minutes.
  rule {
    name     = "rate-limit-per-ip"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-web-acl"
    sampled_requests_enabled   = true
  }
}

# Attache le WAF à l'ALB.
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# Logs du WAF : chaque requête bloquée est visible dans CloudWatch (pratique pendant la démo).
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
}
