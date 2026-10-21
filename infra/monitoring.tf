# Logs et notifications.
# Équivalent GCP : Cloud Logging + Cloud Monitoring (notification channels).

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_158:Chiffré par défaut avec une clé gérée par AWS ; une clé KMS dédiée est hors périmètre.
  #checkov:skip=CKV_AWS_338:30 jours suffisent pour une démo (1 an serait exigé en production).
  name              = "/vpc/${var.project}-flow-logs"
  retention_in_days = var.log_retention_days
}

# Topic SNS des alertes de sécurité, et un abonnement email dessus.
resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:EventBridge ne peut pas publier sur un topic chiffré avec la clé SNS gérée par AWS ; une clé KMS dédiée est hors périmètre.
  name = "${var.project}-security-alerts"
}

# Autorise EventBridge (règle GuardDuty) à publier sur le topic.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridge"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.guardduty.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email" # AWS envoie un mail de confirmation : il faut cliquer sur le lien une fois
  endpoint  = var.alert_email
}
