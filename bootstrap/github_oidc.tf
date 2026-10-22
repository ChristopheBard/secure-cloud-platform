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

  # Début du "sub" du jeton GitHub. Par défaut "repo:<propriétaire>/<repo>".
  # Si le repo utilise le format "immuable" de GitHub ("repo:<propriétaire>@<id>/<repo>@<id>"),
  # on le renseigne dans var.oidc_sub_prefix : les ID numériques ne changent jamais,
  # même si le repo est renommé ou si quelqu'un recrée un repo du même nom.
  sub_prefix = var.oidc_sub_prefix != "" ? var.oidc_sub_prefix : "repo:${local.repo}"

  # ARN des ressources qui seront créées plus tard par infra/.
  # On les connaît à l'avance grâce à la convention de nommage "<project>-...".
  ecr_repository_arn = "arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.project}-app"
  eks_cluster_arn    = "arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.project}-eks"
  app_ssm_params_arn = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/app/*"

  # Rôles que la pipeline a le droit de gérer : uniquement ceux qui commencent par "scp-".
  # Les rôles de la pipeline s'appellent "gha-scp-..." : ils ne correspondent PAS à ce motif,
  # donc la pipeline ne peut pas modifier ses propres droits.
  project_role_arn             = "arn:aws:iam::${local.account_id}:role/${var.project}-*"
  project_instance_profile_arn = "arn:aws:iam::${local.account_id}:instance-profile/${var.project}-*"
  project_bucket_arn           = "arn:aws:s3:::${var.project}-*"

  # Seules politiques AWS que la pipeline peut attacher à un rôle (anti-escalade de privilèges).
  attachable_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole",
  ]
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
    plan   = "${local.sub_prefix}:pull_request"
    apply  = "${local.sub_prefix}:environment:production"
    deploy = "${local.sub_prefix}:ref:refs/heads/main"
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
  #checkov:skip=CKV2_AWS_40:Accès complet aux services, mais restreint à la région du projet via aws:RequestedRegion.

  # Les services utilisés par la stack, uniquement dans notre région.
  statement {
    sid = "StackServicesInRegion"
    actions = [
      "ec2:*", # VPC, subnets, NAT, security groups, VM MongoDB
      "eks:*",
      "ecr:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "events:*", # règle EventBridge GuardDuty -> SNS
      "ssm:*",    # mots de passe et URI MongoDB
      "cloudtrail:*",
      "guardduty:*",
      "config:*",
      "securityhub:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Buckets S3 du projet uniquement (sauvegardes, CloudTrail, Config).
  statement {
    sid       = "ProjectBuckets"
    actions   = ["s3:*"]
    resources = [local.project_bucket_arn, "${local.project_bucket_arn}/*"]
  }

  # IAM : uniquement sur les rôles et instance profiles du projet (scp-*).
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

  statement {
    sid = "ManageProjectInstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = [local.project_instance_profile_arn]
  }

  # Anti-escalade de privilèges : la pipeline ne peut attacher QUE les politiques AWS de la liste.
  # Impossible de s'attacher "AdministratorAccess" par exemple.
  statement {
    sid       = "AttachOnlyAllowedPolicies"
    actions   = ["iam:AttachRolePolicy"]
    resources = [local.project_role_arn]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = local.attachable_policy_arns
    }
  }

  # PassRole = "confier" un rôle à un service AWS. Limité aux services de la stack.
  statement {
    sid       = "PassProjectRolesToServices"
    actions   = ["iam:PassRole"]
    resources = [local.project_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "eks.amazonaws.com",
        "ec2.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
        "cloudtrail.amazonaws.com",
        "config.amazonaws.com",
      ]
    }
  }

  # Nécessaire la première fois qu'on utilise certains services dans un compte neuf.
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "guardduty.amazonaws.com",
        "malware-protection.guardduty.amazonaws.com",
        "config.amazonaws.com",
        "securityhub.amazonaws.com",
      ]
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
# Pousse l'image dans ECR et déploie la nouvelle version sur EKS.
# Utilisable seulement depuis la branche main. Ne peut rien faire d'autre dans AWS.
# Ses droits DANS Kubernetes sont donnés par une "access entry" EKS (infra/eks.tf).

resource "aws_iam_role" "app_deploy" {
  name                 = "gha-${var.project}-app-deploy"
  description          = "GitHub Actions - push de l'image dans ECR et deploiement sur EKS (branche main)"
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
  # Récupérer l'adresse du cluster pour configurer kubectl.
  statement {
    sid       = "DescribeProjectCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [local.eks_cluster_arn]
  }
  # Lire l'URI MongoDB et la clé JWT pour créer le Secret Kubernetes de l'application.
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [local.app_ssm_params_arn]
  }
}

resource "aws_iam_role_policy" "app_deploy" {
  name   = "app-deploy"
  role   = aws_iam_role.app_deploy.id
  policy = data.aws_iam_policy_document.app_deploy.json
}
