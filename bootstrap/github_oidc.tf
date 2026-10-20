# Connexion GitHub Actions -> AWS sans aucune clé d'accès stockée dans GitHub.
# Équivalent GCP : Workload Identity Federation (pool + provider + attribute condition).
#
# Comment ça marche :
#   1. À chaque exécution, GitHub fournit au workflow un jeton (JWT) signé, valable quelques minutes.
#      Ce jeton dit "je suis le repo X, sur la branche / l'environnement Y".
#   2. Le workflow présente ce jeton à AWS STS.
#   3. AWS vérifie la signature grâce au fournisseur OIDC ci-dessous, puis compare le contenu du jeton
#      à la "trust policy" du rôle demandé.
#   4. Si ça correspond, STS renvoie des identifiants temporaires (1 h max).

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"] # "audience" attendue dans le jeton
}

locals {
  repo = "${var.github_owner}/${var.github_repo}"

  # ARN des ressources qui seront créées plus tard par infra/.
  # On les connaît à l'avance grâce à la convention de nommage "<project>-...".
  ecr_repository_arn = "arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.project}-app"
  ecs_service_arn    = "arn:aws:ecs:${var.region}:${local.account_id}:service/${var.project}-cluster/${var.project}-service"
  ecs_role_arns = [
    "arn:aws:iam::${local.account_id}:role/${var.project}-ecs-task-execution",
    "arn:aws:iam::${local.account_id}:role/${var.project}-ecs-task",
  ]

  # Rôles que la pipeline a le droit de gérer : uniquement ceux qui commencent par "scp-".
  # Les rôles de la pipeline s'appellent "gha-scp-..." : ils ne correspondent PAS à ce motif,
  # donc la pipeline ne peut pas modifier ses propres droits.
  project_role_arn = "arn:aws:iam::${local.account_id}:role/${var.project}-*"
}

# Trust policy = QUI a le droit de prendre le rôle.
# (À ne pas confondre avec la permission policy = CE QUE le rôle peut faire.)
#
# On génère 3 trust policies, une par rôle. Seule la valeur du "sub" change :
#   plan   -> uniquement depuis une Pull Request du repo
#   apply  -> uniquement depuis l'environnement GitHub "production" (qui exige une approbation humaine)
#   deploy -> uniquement depuis la branche main
#
# On vérifie "aud" ET "sub". Sans la condition sur "sub", n'importe quel repo GitHub
# au monde pourrait prendre ce rôle : c'est l'erreur de configuration classique.
data "aws_iam_policy_document" "trust" {
  for_each = {
    plan   = "repo:${local.repo}:pull_request"
    apply  = "repo:${local.repo}:environment:production"
    deploy = "repo:${local.repo}:ref:refs/heads/main"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}


# Rôle 1 : gha-scp-infra-plan
# Lecture seule. Utilisé sur chaque Pull Request pour faire le "terraform plan".

resource "aws_iam_role" "infra_plan" {
  name                 = "gha-${var.project}-infra-plan"
  description          = "GitHub Actions - terraform plan sur les Pull Requests (lecture seule)"
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600 # 1 heure
}

# Politique AWS prête à l'emploi : lecture sur tous les services (nécessaire pour comparer le code à l'existant).
resource "aws_iam_role_policy_attachment" "infra_plan_readonly" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Accès au state : le plan peut le LIRE et poser le verrou (fichier .tflock), mais pas le réécrire.
data "aws_iam_policy_document" "infra_plan_state" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/infra/*"]
  }
  statement {
    sid       = "LockOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/infra/*.tflock"]
  }
}

resource "aws_iam_role_policy" "infra_plan_state" {
  name   = "terraform-state-read"
  role   = aws_iam_role.infra_plan.id
  policy = data.aws_iam_policy_document.infra_plan_state.json
}


# Rôle 2 : gha-scp-infra-apply
# Écriture. Utilisable seulement depuis l'environnement GitHub "production",
# donc seulement après validation d'un humain.

resource "aws_iam_role" "infra_apply" {
  name                 = "gha-${var.project}-infra-apply"
  description          = "GitHub Actions - terraform apply (environnement production, validation humaine)"
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "infra_apply_readonly" {
  role       = aws_iam_role.infra_apply.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "infra_apply" {
  #checkov:skip=CKV_AWS_109:Écriture limitée aux services de la stack et à une seule région (voir conditions).
  #checkov:skip=CKV_AWS_111:Idem ; les ARN des ressources n'existent pas encore au moment de la création.
  #checkov:skip=CKV_AWS_356:Idem.
  #checkov:skip=CKV2_AWS_40:Accès complet aux services, mais restreint à eu-west-3 via aws:RequestedRegion.

  # Les services utilisés par la stack, uniquement dans notre région.
  statement {
    sid = "StackServicesInRegion"
    actions = [
      "ec2:*",                  # VPC, subnets, security groups, endpoints
      "elasticloadbalancing:*", # ALB
      "ecs:*",
      "ecr:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "wafv2:*",
      "acm:*", # certificat TLS
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Validation DNS du certificat, seulement utile si on a un nom de domaine.
  statement {
    sid       = "Route53ForCertificate"
    actions   = ["route53:ChangeResourceRecordSets", "route53:GetChange"]
    resources = ["*"]
  }

  # IAM : uniquement sur les rôles du projet (scp-*).
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [local.project_role_arn]
  }

  # Anti-escalade de privilèges : la pipeline ne peut attacher QU'UNE seule politique AWS,
  # celle dont ECS a besoin. Impossible de s'attacher "AdministratorAccess" par exemple.
  statement {
    sid       = "AttachOnlyEcsExecutionPolicy"
    actions   = ["iam:AttachRolePolicy"]
    resources = [local.project_role_arn]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
    }
  }

  # PassRole = "confier" un rôle à un service AWS. Limité à ECS et aux Flow Logs.
  statement {
    sid       = "PassProjectRolesToServices"
    actions   = ["iam:PassRole"]
    resources = [local.project_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "vpc-flow-logs.amazonaws.com"]
    }
  }

  # Nécessaire la première fois qu'on utilise ECS ou un load balancer dans un compte neuf.
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  # Lecture et écriture du state.
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }
  statement {
    sid       = "ReadWriteState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/infra/*"]
  }
}

resource "aws_iam_role_policy" "infra_apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.infra_apply.id
  policy = data.aws_iam_policy_document.infra_apply.json
}


# Rôle 3 : gha-scp-app-deploy
# Pousse l'image dans ECR et déploie la nouvelle version sur ECS.
# Utilisable seulement depuis la branche main. Ne peut rien faire d'autre.

resource "aws_iam_role" "app_deploy" {
  name                 = "gha-${var.project}-app-deploy"
  description          = "GitHub Actions - push de l'image dans ECR et mise à jour du service ECS (branche main)"
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "app_deploy" {
  # Connexion au registre (cette API ne permet pas de cibler une ressource précise).
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  # Push de l'image, uniquement dans le repo ECR du projet.
  statement {
    sid = "PushToProjectRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [local.ecr_repository_arn]
  }
  # Création d'une nouvelle version de la "task definition" (la fiche qui décrit le conteneur).
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"] # ces API ne permettent pas de cibler une ressource précise
  }
  # Mise à jour du service, uniquement celui du projet.
  statement {
    sid       = "UpdateProjectService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [local.ecs_service_arn]
  }
  # La nouvelle task definition référence les 2 rôles ECS : il faut le droit de les "passer" à ECS.
  statement {
    sid       = "PassOnlyEcsRoles"
    actions   = ["iam:PassRole"]
    resources = local.ecs_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "app_deploy" {
  name   = "app-deploy"
  role   = aws_iam_role.app_deploy.id
  policy = data.aws_iam_policy_document.app_deploy.json
}
