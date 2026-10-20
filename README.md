# Secure Cloud Platform

Une application conteneurisée sur AWS, déployée **uniquement** par une pipeline CI/CD,
avec la sécurité intégrée à chaque étape : du code jusqu'à l'exécution dans le cloud.

![Architecture](docs/architecture.png)

## Ce que montre ce projet

| Thème | Mise en oeuvre |
|---|---|
| **Zéro clé statique** | GitHub Actions s'authentifie sur AWS par OIDC : identifiants temporaires (1 h), aucun secret dans le repo. |
| **Séparation des droits** | 3 rôles IAM : `plan` en lecture seule (Pull Requests), `apply` après validation humaine, `app-deploy` limité à ECR + ECS. |
| **Shift left** | Checkov bloque le Terraform non conforme, Trivy bloque les images vulnérables, **avant** le déploiement. |
| **Supply chain** | Actions GitHub épinglées par SHA, Dependabot, permissions minimales du jeton GitHub, tags d'image immuables. |
| **Réseau** | Conteneurs en subnets privés **sans aucune route vers Internet** (pas de NAT) : accès aux services AWS par VPC endpoints. |
| **Bordure** | AWS WAF (règles managées + limitation de débit) devant l'ALB, TLS via ACM si un domaine est configuré. |
| **Détection** | Scan ECR à chaque push, VPC Flow Logs, logs WAF, alarmes CloudWatch envoyées par email via SNS. |

## Organisation du repo

```
bootstrap/              Lancé une fois en local : bucket du state, OIDC GitHub, rôles IAM de la pipeline
infra/                  Infrastructure principale, déployée uniquement par la pipeline
app/                    Application Go + Dockerfile (image distroless, non-root)
.github/workflows/
  infra.yml             PR : fmt, validate, Checkov, plan  |  main : apply après validation
  app.yml               PR : build + Trivy                 |  main : build, Trivy, push ECR, déploiement ECS
.github/dependabot.yml  Mises à jour des actions, de l'image de base et des providers
```

## Déployer

### 1. Bootstrap (une seule fois, en local, avec un accès admin AWS)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

### 2. Configuration du repo GitHub

- **Variables** (Settings > Secrets and variables > Actions > Variables) :
  `AWS_ACCOUNT_ID` et `TF_STATE_BUCKET` (sorties du bootstrap), `ALERT_EMAIL`.
- **Environnement** `production` (Settings > Environments) avec un *required reviewer*.
- **Protection de `main`** (Settings > Branches) : Pull Request obligatoire, checks verts obligatoires.

### 3. Déploiement

1. Ouvrir une Pull Request qui touche `infra/` : contrôles + plan en commentaire.
2. Fusionner : l'`apply` attend la validation, puis crée l'infrastructure.
3. Lancer le workflow **Application** (onglet Actions > Run workflow) : la première image est construite, scannée, poussée et déployée.

Au tout premier apply, le service ECS démarre avant qu'une image existe : les conteneurs échouent
jusqu'à l'étape 3, c'est attendu.

## Coût et nettoyage

Quand l'infrastructure tourne : ALB, 3 VPC endpoints sur 2 AZ, WAF, 2 petites tâches Fargate,
soit quelques dollars par jour. Après la démo :

```bash
# infra/ : via la pipeline ou en local avec un accès admin
terraform -chdir=infra destroy
terraform -chdir=bootstrap destroy
```
