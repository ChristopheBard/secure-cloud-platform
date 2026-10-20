variable "region" {
  description = "Région AWS du projet."
  type        = string
  default     = "eu-west-3" # Paris
}

variable "project" {
  description = "Préfixe de nommage. Doit être le même que dans infra/ (les politiques IAM s'appuient dessus)."
  type        = string
  default     = "scp" # secure-cloud-platform
}

variable "github_owner" {
  description = "Compte GitHub propriétaire du repo."
  type        = string
}

variable "github_repo" {
  description = "Nom du repo GitHub (sans le propriétaire)."
  type        = string
}
