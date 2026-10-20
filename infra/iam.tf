# Identités des workloads.
# Équivalent GCP : les service accounts attachés à un service Cloud Run.
#
# Tous les noms commencent par "scp-" : ce sont les seuls rôles que la pipeline d'apply a le droit de gérer
# (voir bootstrap/github_oidc.tf).

# Trust policy commune : seul le service ECS peut prendre ces rôles.
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Rôle d'exécution : utilisé par ECS lui-même pour démarrer le conteneur
# (télécharger l'image depuis ECR, écrire dans CloudWatch Logs).
resource "aws_iam_role" "task_execution" {
  name               = "${var.project}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Rôle de la tâche : utilisé par le code de l'application.
# Volontairement vide : un Hello World n'appelle aucune API AWS.
# Moindre privilège = on n'ajoute des droits ici que le jour où l'application en a vraiment besoin.
resource "aws_iam_role" "task" {
  name               = "${var.project}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# Rôle des VPC Flow Logs : leur permet d'écrire dans leur groupe de logs, et nulle part ailleurs.
data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.project}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}
