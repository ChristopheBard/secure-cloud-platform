# Valeurs affichées à la fin du "terraform apply" (visibles dans les logs de la pipeline).

output "app_url" {
  description = "URL de l'application."
  value       = local.enable_https ? "https://${var.domain_name}" : "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "Repo d'images où la pipeline app pousse."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service" {
  value = aws_ecs_service.app.name
}

output "sns_alerts_topic" {
  value = aws_sns_topic.alerts.arn
}
