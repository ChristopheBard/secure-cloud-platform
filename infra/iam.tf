# Identités des workloads.
# Équivalent GCP : les service accounts attachés à un cluster GKE ou à une VM.
#
# Tous les noms commencent par "scp-" : ce sont les seuls rôles que la pipeline d'apply a le droit de gérer
# (voir bootstrap/github_oidc.tf).

# Rôle du cluster EKS (utilisé par le plan de contrôle et par Auto Mode).

data "aws_iam_policy_document" "eks_cluster_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_trust.json
}

# Politiques AWS exigées par EKS Auto Mode (noeuds, stockage, load balancers, réseau).
resource "aws_iam_role_policy_attachment" "eks_cluster" {
  for_each = toset([
    "AmazonEKSClusterPolicy",
    "AmazonEKSComputePolicy",
    "AmazonEKSBlockStoragePolicy",
    "AmazonEKSLoadBalancingPolicy",
    "AmazonEKSNetworkingPolicy",
  ])
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# Rôle des noeuds EKS : le strict minimum (rejoindre le cluster, télécharger les images depuis ECR).

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "AmazonEKSWorkerNodeMinimalPolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}


# Rôle de la VM MongoDB.

resource "aws_iam_role" "mongodb" {
  name               = "${var.project}-mongodb-vm"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_instance_profile" "mongodb" {
  name = "${var.project}-mongodb-vm"
  role = aws_iam_role.mongodb.name
}

# Session Manager : accès shell à la VM via IAM et CloudTrail, sans dépendre du port SSH.
resource "aws_iam_role_policy_attachment" "mongodb_ssm" {
  role       = aws_iam_role.mongodb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "mongodb" {
  #checkov:skip=CKV_AWS_107:INTENTIONNEL (exercice) - la VM a des droits trop larges.
  #checkov:skip=CKV_AWS_108:INTENTIONNEL (exercice).
  #checkov:skip=CKV_AWS_109:INTENTIONNEL (exercice).
  #checkov:skip=CKV_AWS_110:INTENTIONNEL (exercice) - ec2:* permet une escalade de privilèges.
  #checkov:skip=CKV_AWS_111:INTENTIONNEL (exercice).
  #checkov:skip=CKV_AWS_356:INTENTIONNEL (exercice).
  #checkov:skip=CKV2_AWS_40:INTENTIONNEL (exercice).

  # INTENTIONNEL (exercice) : tous les droits EC2, donc la VM peut créer d'autres VM.
  # Un attaquant qui prend la main sur la VM peut lancer des machines (cryptominage) ou en modifier d'autres.
  statement {
    sid       = "OverlyPermissiveEc2"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # Besoins réels de la VM : écrire les sauvegardes, lire ses mots de passe.
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/backups/*"]
  }
  statement {
    sid       = "ReadMongoPasswords"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/mongodb/*"]
  }

  # Contrôle PRÉVENTIF : un "Deny" explicite l'emporte toujours sur un "Allow" dans IAM.
  # Même si quelqu'un élargit ce rôle plus tard, la VM ne pourra jamais aveugler la détection
  # (arrêter CloudTrail, GuardDuty, Config) ni toucher à IAM pour s'octroyer plus de droits.
  statement {
    sid    = "GuardrailNoDefenseEvasion"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "guardduty:DeleteDetector",
      "guardduty:UpdateDetector",
      "guardduty:DisassociateFromMasterAccount",
      "config:StopConfigurationRecorder",
      "config:DeleteConfigurationRecorder",
      "config:DeleteDeliveryChannel",
      "logs:DeleteLogGroup",
      "iam:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "mongodb" {
  name   = "mongodb-vm"
  role   = aws_iam_role.mongodb.id
  policy = data.aws_iam_policy_document.mongodb.json
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
