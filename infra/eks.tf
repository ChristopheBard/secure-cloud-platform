# Cluster Kubernetes managé : EKS en "Auto Mode", dans les subnets privés.
# Équivalent GCP : GKE Autopilot.
#
# Auto Mode : AWS gère aussi les noeuds (création, mises à jour, taille), le réseau des pods
# et le contrôleur de load balancer. On ne maintient ni groupe de noeuds ni contrôleur à installer :
# moins de code, moins de choses à patcher.

resource "aws_cloudwatch_log_group" "eks" {
  #checkov:skip=CKV_AWS_158:Chiffré par défaut avec une clé gérée par AWS ; une clé KMS dédiée est hors périmètre.
  #checkov:skip=CKV_AWS_338:30 jours suffisent pour une démo (1 an serait exigé en production).
  # Nom imposé par EKS. Le créer nous-mêmes permet de fixer la durée de conservation.
  name              = "/aws/eks/${var.project}-eks/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "main" {
  #checkov:skip=CKV_AWS_39:API publique nécessaire pour les runners GitHub (IP variables) et kubectl en démo ; l'accès reste soumis à l'authentification IAM.
  #checkov:skip=CKV_AWS_38:Idem, pas de liste d'IP possible pour les runners GitHub hébergés.
  #checkov:skip=CKV_AWS_58:Les secrets Kubernetes sont chiffrés par défaut par EKS (clé gérée par AWS) ; une clé KMS dédiée est hors périmètre.
  name     = "${var.project}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  # Auto Mode installe et gère lui-même les composants réseau du cluster.
  bootstrap_self_managed_addons = false

  # Accès à l'API Kubernetes géré par des "access entries" IAM (voir plus bas),
  # et non par l'ancien fichier aws-auth.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true # le rôle de la pipeline qui crée le cluster en est admin
  }

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.eks_node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true # un Ingress crée automatiquement un Application Load Balancer
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id # noeuds et pods dans les subnets privés
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Logs d'audit du plan de contrôle Kubernetes : qui a fait quoi sur l'API du cluster.
  # Complément de CloudTrail (qui trace l'API AWS).
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_cloudwatch_log_group.eks,
    aws_iam_role_policy_attachment.eks_cluster,
  ]
}

# Accès kubectl "admin" pour les humains listés (ex : l'identité du lab utilisée en démo).
resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.eks_admin_principal_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.eks_admin_principal_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}

# Accès de la pipeline applicative (rôle gha-scp-app-deploy).
# Admin du cluster : le déploiement crée un ClusterRoleBinding vers cluster-admin (exigence de l'exercice),
# ce que Kubernetes n'autorise qu'à un compte qui possède lui-même ces droits.
resource "aws_eks_access_entry" "app_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${local.account_id}:role/gha-${var.project}-app-deploy"
}

resource "aws_eks_access_policy_association" "app_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.app_deploy.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
