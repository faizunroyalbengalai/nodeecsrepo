terraform {
  backend "s3" {
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {}

variable "image_tag" {
  default = "latest"
}

variable "app_port" {
  type    = number
  default = 3000
}

variable "health_check_path" {
  default = "/"
}

variable "database_url" {
  default = ""
}

variable "mongo_uri" {
  default = ""
}

variable "db_host" {
  default = ""
}

variable "db_port" {
  default = ""
}

variable "db_name" {
  default = ""
}

variable "db_user" {
  default = ""
}

variable "db_password" {
  default = ""
}

variable "rds_install_db" {
  default = ""
}

variable "db_type" {
  default = ""
}

variable "db_username" {
  default = ""
}

# ECR
resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

# VPC (use default)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Groups
resource "aws_security_group" "alb" {
  name   = "${var.project_name}-alb-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_security_group" "ecs" {
  name   = "${var.project_name}-ecs-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  count  = (var.rds_install_db == "true" && (var.db_type == "postgres" || var.db_type == "mysql")) ? 1 : 0
  name   = "${var.project_name}-rds-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = var.db_type == "postgres" ? 5432 : 3306
    to_port         = var.db_type == "postgres" ? 5432 : 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS (optional)
locals {
  provision_rds  = var.rds_install_db == "true" && (var.db_type == "postgres" || var.db_type == "mysql")
  project_slug   = replace(replace(var.project_name, "_", "-"), "/[^a-z0-9-]/", "")
  rds_port       = var.db_type == "postgres" ? 5432 : 3306
  rds_engine     = var.db_type == "postgres" ? "postgres" : "mysql"
  rds_engine_ver = var.db_type == "postgres" ? "15" : "8.0"
  rds_param_grp  = var.db_type == "postgres" ? "default.postgres15" : "default.mysql8.0"
  rds_endpoint   = local.provision_rds ? aws_db_instance.app[0].address : var.db_host
  rds_db_port    = local.provision_rds ? tostring(local.rds_port) : var.db_port
  rds_db_name    = local.provision_rds ? (var.db_name != "" ? var.db_name : "appdb") : var.db_name
  rds_db_user    = local.provision_rds ? (var.db_username != "" ? var.db_username : (var.db_user != "" ? var.db_user : "appuser")) : var.db_user
  rds_db_pass    = local.provision_rds ? var.db_password : var.db_password
  resolved_db_url = (
    local.provision_rds
    ? (
        var.db_type == "postgres"
        ? "postgresql://${local.rds_db_user}:${local.rds_db_pass}@${local.rds_endpoint}:${local.rds_db_port}/${local.rds_db_name}"
        : "mysql://${local.rds_db_user}:${local.rds_db_pass}@${local.rds_endpoint}:${local.rds_db_port}/${local.rds_db_name}"
      )
    : var.database_url
  )
}

resource "aws_db_instance" "app" {
  count                  = local.provision_rds ? 1 : 0
  identifier             = "${local.project_slug}-db"
  engine                 = local.rds_engine
  engine_version         = local.rds_engine_ver
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = local.rds_db_name
  username               = local.rds_db_user
  password               = local.rds_db_pass
  parameter_group_name   = local.rds_param_grp
  publicly_accessible    = true
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds[0].id]
}

# ALB
resource "aws_lb" "main" {
  name               = "${replace(var.project_name, "_", "-")}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app" {
  name        = "${replace(var.project_name, "_", "-")}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# IAM
resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch log group
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

# Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = var.project_name
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.app_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "NODE_ENV",      value = "production" },
        { name = "DATABASE_URL",  value = local.resolved_db_url },
        { name = "MONGO_URI",     value = var.mongo_uri },
        { name = "DB_HOST",       value = local.rds_endpoint },
        { name = "DB_PORT",       value = local.rds_db_port },
        { name = "DB_NAME",       value = local.rds_db_name },
        { name = "DB_USER",       value = local.rds_db_user },
        { name = "DB_PASSWORD",   value = local.rds_db_pass }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.project_name}"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "app" {
  name                              = "${var.project_name}-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.app.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 180

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.project_name
    container_port   = var.app_port
  }

  depends_on = [aws_lb_listener.http]
}

output "alb_url" {
  value = "http://${aws_lb.main.dns_name}"
}