variable "region" {
  description = "Région AWS."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Préfixe de nommage. Doit être le même que dans bootstrap/ (les politiques IAM s'appuient dessus)."
  type        = string
  default     = "scp"
}

variable "availability_zones" {
  description = "Les 2 zones de disponibilité utilisées."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b"]
}

variable "vpc_cidr" {
  description = "Plage d'adresses du VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "container_port" {
  description = "Port écouté par l'application dans le conteneur."
  type        = number
  default     = 8080
}

variable "desired_count" {
  description = "Nombre de conteneurs (au moins un par AZ pour la haute disponibilité)."
  type        = number
  default     = 2
}

variable "task_cpu" {
  description = "CPU d'un conteneur Fargate (256 = 0,25 vCPU)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Mémoire d'un conteneur Fargate (Mo)."
  type        = number
  default     = 512
}

variable "image_tag" {
  description = "Tag d'image utilisé au tout premier déploiement. Ensuite, c'est la pipeline app qui choisit la version."
  type        = string
  default     = "initial"
}

variable "domain_name" {
  description = "Nom de domaine optionnel (ex : demo.example.com). Vide = HTTP seulement, sans certificat."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Zone Route 53 qui contient domain_name (ex : example.com). Utilisée seulement si domain_name est renseigné."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email qui reçoit les alertes. Vide = pas d'abonnement."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Durée de conservation des logs CloudWatch (jours)."
  type        = number
  default     = 30
}
