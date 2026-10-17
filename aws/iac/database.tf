# --- Container registry ---
resource "aws_ecr_repository" "backend" {
  name                 = "todo-backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lets "destroy" work even when images are present

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "todo-frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "keep_recent" {
  for_each   = { backend = aws_ecr_repository.backend.name, frontend = aws_ecr_repository.frontend.name }
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# --- Database ---
# The password is generated here and goes straight into SSM. Nobody types or commits it.
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_instance" "main" {
  identifier             = "todo-db"
  engine                 = "mysql"
  engine_version         = "8.4"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = "todo_db"
  username               = "todoadmin"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false
  backup_retention_period = 3

  # Convenient for a test environment: "destroy" does not stall on a final snapshot.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# --- Secrets read by aws/deploy.sh through the app host's instance role ---
resource "aws_ssm_parameter" "db_host" {
  name  = "/todo/db-host"
  type  = "String"
  value = aws_db_instance.main.address
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/todo/db-username"
  type  = "String"
  value = aws_db_instance.main.username
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/todo/db-password"
  type  = "SecureString"
  value = random_password.db.result
}

# Placeholders. Put real values in later with "aws ssm put-parameter --overwrite";
# Terraform will not overwrite them afterwards.
resource "aws_ssm_parameter" "cohere_api_key" {
  name  = "/todo/cohere-api-key"
  type  = "SecureString"
  value = "placeholder-set-a-real-key"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "slack_webhook_url" {
  name  = "/todo/slack-webhook-url"
  type  = "SecureString"
  value = "http://localhost/placeholder-webhook"

  lifecycle {
    ignore_changes = [value]
  }
}
