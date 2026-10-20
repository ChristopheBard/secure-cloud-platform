# Logs, alarmes et notifications.
# Équivalent GCP : Cloud Logging + Cloud Monitoring (alerting policies + notification channels).
#
#   CloudWatch Logs   : logs de l'application, du WAF et du réseau (flow logs)
#   CloudWatch Alarms : seulement ce qui impacte les utilisateurs (erreurs, conteneurs KO, saturation)
#   SNS -> email      : l'équipe Ops est prévenue
#
# On évite volontairement d'alerter sur tout : trop d'alertes = fatigue d'alerte = on rate la vraie.


# Groupes de logs

resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_158:Chiffré par défaut avec une clé gérée par AWS ; une clé KMS dédiée est hors périmètre.
  #checkov:skip=CKV_AWS_338:30 jours suffisent pour une démo (1 an serait exigé en production).
  name              = "/ecs/${var.project}-app"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_158:Chiffré par défaut avec une clé gérée par AWS.
  #checkov:skip=CKV_AWS_338:30 jours suffisent pour une démo.
  name              = "aws-waf-logs-${var.project}" # le préfixe "aws-waf-logs-" est imposé par AWS
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_158:Chiffré par défaut avec une clé gérée par AWS.
  #checkov:skip=CKV_AWS_338:30 jours suffisent pour une démo.
  name              = "/vpc/${var.project}-flow-logs"
  retention_in_days = var.log_retention_days
}


# Notifications : un "topic" SNS, et un abonnement email dessus.

resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:CloudWatch ne peut pas publier sur un topic chiffré avec la clé SNS gérée par AWS ; une clé KMS dédiée est hors périmètre.
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email" # AWS envoie un mail de confirmation : il faut cliquer sur le lien une fois
  endpoint  = var.alert_email
}


# Alarmes. Chacune envoie un message sur le topic quand elle se déclenche, et quand elle revient à la normale.

# L'application renvoie des erreurs serveur (plus de 5 erreurs 5xx par minute, 3 minutes de suite).
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-target-5xx"
  alarm_description   = "L'application renvoie des erreurs serveur (5xx)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" # pas de trafic = pas d'alerte
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Au moins un conteneur échoue à son health check.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name        = "${var.project}-unhealthy-targets"
  alarm_description = "Au moins un conteneur échoue à son health check."
  namespace         = "AWS/ApplicationELB"
  metric_name       = "UnHealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# CPU du service au-dessus de 80 % pendant 5 minutes.
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.project}-ecs-cpu-high"
  alarm_description   = "CPU du service au-dessus de 80 % pendant 5 minutes."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.app.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Mémoire du service au-dessus de 80 % pendant 5 minutes.
resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "${var.project}-ecs-memory-high"
  alarm_description   = "Mémoire du service au-dessus de 80 % pendant 5 minutes."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.app.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
