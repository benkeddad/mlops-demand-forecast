#Step 1: The Core Provider Configuration
# This is the AWS twin of ../terraform/main.tf — same app, same 3 images,
# a completely different infrastructure target (ECS on AWS instead of K3s).
# Pointed at LocalStack by default. To run this against real AWS, delete the
# `endpoints` block below and the three `skip_*`/`s3_use_path_style` lines,
# and set real credentials instead of "test"/"test" — nothing else changes.

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3             = "http://localhost:4566"
    rds            = "http://localhost:4566"
    ecs            = "http://localhost:4566"
    ecr            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    dynamodb       = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    logs           = "http://localhost:4566"
    servicediscovery = "http://localhost:4566"
    ec2            = "http://localhost:4566"
  }
}

locals {
  project     = "rossmann"
  db_username = "user"
  db_password = "Password" # NOTE: for real AWS, replace with a var + Secrets Manager-generated value, not a literal
  image_tag   = "latest"
}

#Step 2: Networking
# LocalStack (like every AWS account) ships a default VPC — reuse it instead
# of standing up a new one, same as most real teams do for a first deployment.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "rossmann_internal" {
  name_prefix = "${local.project}-internal-"
  vpc_id      = data.aws_vpc.default.id

  # Open between services on purpose for the demo — see README "Known
  # Limitations" for the same honest tradeoff already made on the K3s path.
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#Step 3: Storage — S3 replaces the local DVC cache and the MLflow artifact volume
resource "aws_s3_bucket" "dvc_remote" {
  bucket = "${local.project}-dvc-remote"
}

resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket = "${local.project}-mlflow-artifacts"
}

#Step 4: Database — RDS PostgreSQL replaces the containerized postgres service
# Same one-instance-four-databases pattern as the K3s path: db/create-databases.sql
# still creates mlflow/prefect/feast on top of the rossmann DB RDS provisions.
resource "aws_db_instance" "postgres" {
  identifier             = "${local.project}-postgres"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "rossmann"
  username               = local.db_username
  password               = local.db_password
  skip_final_snapshot    = true
  publicly_accessible    = false # ECS tasks reach it in-VPC via the security group, not the internet
  vpc_security_group_ids = [aws_security_group.rossmann_internal.id]
}

#Step 5: Container Registry — one ECR repo per image, same 3 Dockerfiles as the K3s path
resource "aws_ecr_repository" "api" {
  name = "${local.project}-api"
}

resource "aws_ecr_repository" "mlflow" {
  name = "${local.project}-mlflow"
}

resource "aws_ecr_repository" "prefect" {
  name = "${local.project}-prefect"
}

#Step 6: IAM — the ECS task execution role (pulls images, writes logs) and the
# task role (what the *application* is allowed to do: read/write S3 + DynamoDB)
resource "aws_iam_role" "ecs_execution" {
  name = "${local.project}-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${local.project}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_permissions" {
  name = "${local.project}-task-permissions"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          aws_s3_bucket.dvc_remote.arn, "${aws_s3_bucket.dvc_remote.arn}/*",
          aws_s3_bucket.mlflow_artifacts.arn, "${aws_s3_bucket.mlflow_artifacts.arn}/*",
        ]
      },
      {
        # Feast's DynamoDB online store creates/reads/writes its own table —
        # this is the AWS-native replacement for the Redis online store.
        Effect   = "Allow"
        Action   = ["dynamodb:CreateTable", "dynamodb:DescribeTable", "dynamodb:DeleteTable", "dynamodb:BatchWriteItem", "dynamodb:BatchGetItem"]
        Resource = ["arn:aws:dynamodb:*:*:table/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_credentials.arn]
      },
    ]
  })
}

#Step 7: Secrets — the plaintext credentials the K3s path admittedly hardcodes
# get moved here instead, and referenced from the task definitions below.
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${local.project}/db-credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = local.db_username
    password = local.db_password
  })
}

#Step 8: Logging — one CloudWatch log group per service
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.project}-api"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "mlflow" {
  name              = "/ecs/${local.project}-mlflow"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "prefect" {
  name              = "/ecs/${local.project}-prefect"
  retention_in_days = 7
}

#Step 9: Service Discovery — the AWS equivalent of Kubernetes' Service DNS names
# ("postgres", "mlflow", "prefect" resolving by hostname) that the K3s path
# relies on. Cloud Map gives ECS tasks the same trick: mlflow.rossmann.local
# resolves to whichever task is currently running the mlflow service.
resource "aws_service_discovery_private_dns_namespace" "rossmann" {
  name = "rossmann.local"
  vpc  = data.aws_vpc.default.id
}

resource "aws_service_discovery_service" "mlflow" {
  name = "mlflow"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.rossmann.id
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

resource "aws_service_discovery_service" "prefect" {
  name = "prefect"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.rossmann.id
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

#Step 10: The ECS Cluster all three services run in
resource "aws_ecs_cluster" "rossmann" {
  name = "${local.project}-cluster"
}

#Step 11: Task Definitions — one per image, mirroring deploy/docker-compose.yaml's
# commands and environment variables 1:1

resource "aws_ecs_task_definition" "mlflow" {
  family                   = "${local.project}-mlflow"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn             = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "mlflow"
    image     = "${aws_ecr_repository.mlflow.repository_url}:${local.image_tag}"
    essential = true
    portMappings = [{ containerPort = 5000, protocol = "tcp" }]
    command = [
      "server", "--host", "0.0.0.0", "--port", "5000",
      "--backend-store-uri", "postgresql://${local.db_username}:${local.db_password}@${aws_db_instance.postgres.address}:5432/mlflow",
      "--default-artifact-root", "s3://${aws_s3_bucket.mlflow_artifacts.bucket}",
      "--allowed-hosts", "*",
    ]
    environment = [
      # Only needed so boto3/MLflow inside the container talk to LocalStack
      # instead of real AWS. Delete this whole block when deploying to real AWS.
      # NOTE: host.docker.internal does NOT work here — per LocalStack's own
      # networking docs, a container that LocalStack itself created (this one)
      # can only reach LocalStack at localhost.localstack.cloud, not via
      # host.docker.internal or localhost:4566 (those only work from your host).
      { name = "AWS_ENDPOINT_URL", value = "http://localhost.localstack.cloud:4566" },
      { name = "MLFLOW_S3_ENDPOINT_URL", value = "http://localhost.localstack.cloud:4566" },
      { name = "AWS_ACCESS_KEY_ID", value = "test" },
      { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
      { name = "AWS_DEFAULT_REGION", value = "us-east-1" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mlflow.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "mlflow"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "prefect" {
  family                   = "${local.project}-prefect"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn             = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "prefect"
    image     = "${aws_ecr_repository.prefect.repository_url}:${local.image_tag}"
    essential = true
    portMappings = [{ containerPort = 4200, protocol = "tcp" }]
    command   = ["server", "start", "--host", "0.0.0.0"]
    environment = [
      { name = "PREFECT_API_DATABASE_CONNECTION_URL", value = "postgresql+asyncpg://${local.db_username}:${local.db_password}@${aws_db_instance.postgres.address}:5432/prefect" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.prefect.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "prefect"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.project}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn             = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${aws_ecr_repository.api.repository_url}:${local.image_tag}"
    essential = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = [
      { name = "DATABASE_URL", value = "postgresql://${local.db_username}:${local.db_password}@${aws_db_instance.postgres.address}:5432/rossmann" },
      { name = "MODEL_URI", value = "models:/Rossmann_XGBoost_Model/latest" },
      # Cloud Map DNS names replace the Docker/K8s service names "mlflow" and "prefect"
      { name = "MLFLOW_TRACKING_URI", value = "http://mlflow.rossmann.local:5000" },
      { name = "PREFECT_API_URL", value = "http://prefect.rossmann.local:4200/api" },
      # Only needed for LocalStack — delete for real AWS. See the note on the
      # mlflow container above: localhost.localstack.cloud is the address that
      # actually resolves from inside a container LocalStack created.
      { name = "AWS_ENDPOINT_URL", value = "http://localhost.localstack.cloud:4566" },
      { name = "AWS_ACCESS_KEY_ID", value = "test" },
      { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
      { name = "AWS_DEFAULT_REGION", value = "us-east-1" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

#Step 12: Services — one per task definition, each registered into Cloud Map
# so the others can find it by name, same dependency order as docker-compose.yaml

resource "aws_ecs_service" "mlflow" {
  name            = "mlflow"
  cluster         = aws_ecs_cluster.rossmann.id
  task_definition = aws_ecs_task_definition.mlflow.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.rossmann_internal.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.mlflow.arn
  }

  depends_on = [aws_db_instance.postgres]
}

resource "aws_ecs_service" "prefect" {
  name            = "prefect"
  cluster         = aws_ecs_cluster.rossmann.id
  task_definition = aws_ecs_task_definition.prefect.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.rossmann_internal.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.prefect.arn
  }

  depends_on = [aws_db_instance.postgres]
}

resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.rossmann.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.rossmann_internal.id]
    assign_public_ip = true
  }

  # Mirrors docker-compose.yaml's `depends_on: [postgres, redis, mlflow, prefect]`
  depends_on = [aws_db_instance.postgres, aws_ecs_service.mlflow, aws_ecs_service.prefect]
}

#Step 13: Useful outputs for a demo — run `terraform output` after `apply`
output "api_ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "mlflow_ecr_repository_url" {
  value = aws_ecr_repository.mlflow.repository_url
}

output "prefect_ecr_repository_url" {
  value = aws_ecr_repository.prefect.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}

output "dvc_remote_bucket" {
  value = aws_s3_bucket.dvc_remote.bucket
}

output "mlflow_artifacts_bucket" {
  value = aws_s3_bucket.mlflow_artifacts.bucket
}
