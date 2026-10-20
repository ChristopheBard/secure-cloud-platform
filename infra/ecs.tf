# Conteneurs "serverless" : ECS sur Fargate, dans les subnets privés.
# Équivalent GCP : Cloud Run. Pas de serveur ni d'OS à gérer ou patcher.
#
# Vocabulaire ECS :
#   cluster         : regroupement logique (avec Fargate, il n'y a aucune machine dedans)
#   task definition : la "fiche" du conteneur (image, CPU, mémoire, rôles, logs...)
#   service         : maintient N conteneurs en vie et les branche sur l'ALB

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  # Métriques CPU / mémoire détaillées dans CloudWatch.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # chaque conteneur a sa propre carte réseau et son security group
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn # rôle utilisé par ECS (télécharger l'image, écrire les logs)
  task_role_arn            = aws_iam_role.task.arn           # rôle utilisé par le code de l'application

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    # Durcissement du conteneur :
    readonlyRootFilesystem = true          # le conteneur ne peut pas modifier ses propres fichiers
    user                   = "65532:65532" # utilisateur non-root
    privileged             = false
    linuxParameters = {
      capabilities = { drop = ["ALL"] } # retire tous les privilèges Linux spéciaux
    }

    environment = [{ name = "PORT", value = tostring(var.container_port) }]

    # Les logs du conteneur partent vers CloudWatch (via le VPC endpoint "logs").
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name             = "${var.project}-service"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = false # pas de shell interactif dans les conteneurs de production
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false # aucune IP publique sur les conteneurs
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # Déploiement progressif : les nouveaux conteneurs démarrent avant que les anciens s'arrêtent.
  # Si la nouvelle version n'arrive jamais à être "healthy", ECS revient seul à la version précédente.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # C'est la pipeline app qui déploie les nouvelles versions de l'image.
  # Sans cette ligne, le prochain terraform apply remettrait l'ancienne version :
  # Terraform et la pipeline se battraient sur la version déployée.
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http]
}
