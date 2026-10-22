variable "region" {
  description = "Région AWS (celle autorisée par le lab CloudLabs)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Préfixe de nommage. Doit être le même que dans bootstrap/ (les politiques IAM s'appuient dessus)."
  type        = string
  default     = "scp"
}

variable "vpc_cidr" {
  description = "Plage d'adresses du VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "Version de Kubernetes d'EKS. null = version par défaut proposée par AWS au moment de la création."
  type        = string
  default     = null
}

variable "eks_admin_principal_arns" {
  description = "ARN IAM des humains autorisés à utiliser kubectl en admin (ex : l'utilisateur ou le rôle du lab)."
  type        = list(string)
  default     = []
}

variable "mongodb_instance_type" {
  description = "Taille de la VM MongoDB."
  type        = string
  default     = "t3.small"
}

variable "ssh_public_key" {
  description = "Clé publique SSH pour se connecter à la VM MongoDB. Vide = pas de clé (accès par SSM Session Manager)."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email qui reçoit les alertes de sécurité. Vide = pas d'abonnement."
  type        = string
  default     = ""
  sensitive   = true # masqué dans le plan publié dans la Pull Request (repo public)
}

variable "log_retention_days" {
  description = "Durée de conservation des logs CloudWatch (jours)."
  type        = number
  default     = 30
}

# Interrupteurs : si le compte du lab a déjà GuardDuty, Config ou Security Hub activés
# (un seul par région est possible), on les passe à false pour ne pas créer de doublon.
variable "enable_guardduty" {
  description = "Créer le détecteur GuardDuty."
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Créer l'enregistreur AWS Config et ses règles."
  type        = bool
  default     = true
}

variable "enable_securityhub" {
  description = "Activer Security Hub (standard AWS Foundational Security Best Practices). Nécessite AWS Config."
  type        = bool
  default     = true
}
