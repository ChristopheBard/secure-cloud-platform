# Valeurs affichées à la fin du "terraform apply".
# Les deux premières sont à recopier dans les variables du repo GitHub
# (Settings > Secrets and variables > Actions > Variables).

output "aws_account_id" {
  description = "À enregistrer dans la variable GitHub AWS_ACCOUNT_ID."
  value       = local.account_id
}

output "tf_state_bucket" {
  description = "À enregistrer dans la variable GitHub TF_STATE_BUCKET."
  value       = aws_s3_bucket.tfstate.bucket
}

output "role_arns" {
  description = "Rôles IAM utilisés par les workflows GitHub Actions."
  value = {
    infra_plan  = aws_iam_role.infra_plan.arn
    infra_apply = aws_iam_role.infra_apply.arn
    app_deploy  = aws_iam_role.app_deploy.arn
  }
}
