# Valeurs affichées à la fin du "terraform apply" (visibles dans les logs de la pipeline).

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "kubeconfig_command" {
  description = "Commande pour configurer kubectl sur son poste."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

output "ecr_repository_url" {
  description = "Repo d'images où la pipeline app pousse."
  value       = aws_ecr_repository.app.repository_url
}

output "mongodb_public_ip" {
  description = "IP publique de la VM MongoDB (SSH ouvert, faiblesse volontaire)."
  value       = aws_instance.mongodb.public_ip
}

output "mongodb_private_ip" {
  value = aws_instance.mongodb.private_ip
}

output "mongodb_instance_id" {
  description = "Pour se connecter sans SSH : aws ssm start-session --target <id>"
  value       = aws_instance.mongodb.id
}

output "backups_public_url" {
  description = "URL publique du bucket des sauvegardes : ouverte dans un navigateur, elle liste les fichiers."
  value       = "https://${aws_s3_bucket.backups.bucket}.s3.${var.region}.amazonaws.com/"
}

output "sns_alerts_topic" {
  value = aws_sns_topic.alerts.arn
}
