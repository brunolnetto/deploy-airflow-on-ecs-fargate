# A role to control API permissions on our scheduler tasks.
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#task_role_arn
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html
resource "aws_iam_role" "airflow_scheduler_task" {
  name_prefix = "airflowSchedulerTask"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Allow airflow scheduler to read SecretManager secrets
resource "aws_iam_role_policy_attachment" "airflow_scheduler_read_secret" {
  role       = aws_iam_role.airflow_scheduler_task.name
  policy_arn = aws_iam_policy.secret_manager_read_secret.arn
}

# Scheduler service security group (no incoming connections)
resource "aws_security_group" "airflow_scheduler_service" {
  name_prefix = "airflow-scheduler"
  description = "Deny all incoming traffic"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Direct scheduler logs to this Cloud Watch log group
resource "aws_cloudwatch_log_group" "airflow_scheduler" {
  name_prefix = "deploy-airflow-on-ecs-fargate/airflow-scheduler/"
}

# Scheduler service task definition
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition
resource "aws_ecs_task_definition" "airflow_scheduler" {
  family             = "airflow-scheduler"
  cpu                = 2048
  memory             = 4096
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn      = aws_iam_role.airflow_scheduler_task.arn
  network_mode       = "awsvpc"
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  requires_compatibilities = ["FARGATE"]
  container_definitions = jsonencode([
    {
      name   = "scheduler"
      image  = join(":", [aws_ecr_repository.airflow.repository_url, "latest"])
      cpu    = 2048
      memory = 4096
      healthcheck = {
        command = [
          "CMD-SHELL",
          "airflow jobs check --job-type SchedulerJob --hostname \"$${HOSTNAME}\""
        ]
        interval = 10
        timeout  = 10
        retries  = 5
      }
      essential = true
      command   = ["scheduler"]
      environment = [
        {
          name  = "AIRFLOW__WEBSERVER__INSTANCE_NAME"
          value = "deploy-airflow-on-ecs-fargate"
        }
      ]
      user = "50000:0"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.airflow_scheduler.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "airflow-scheduler"
        }
      }
    }
  ])
}

# Airflow ECS scheduler service
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service
resource "aws_ecs_service" "airflow_scheduler" {
  name = "airflow-scheduler"
  # If a revision is not specified, the latest ACTIVE revision is used.
  task_definition = aws_ecs_task_definition.airflow_scheduler.family
  cluster         = aws_ecs_cluster.airflow.arn
  # If using awsvpc network mode, do not specify this role.
  # iam_role =
  deployment_controller {
    type = "ECS"
  }
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  desired_count                      = 1
  lifecycle {
    ignore_changes = [desired_count]
  }
  launch_type = "FARGATE"
  network_configuration {
    subnets = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    # For tasks on Fargate, in order for the task to pull the container image it must either
    # 1. use a public subnet and be assigned a public IP address
    # 2. use a private subnet that has a route to the internet or a NAT gateway
    assign_public_ip = true
    security_groups  = [aws_security_group.airflow_scheduler_service.id]
  }
  platform_version    = "1.4.0"
  scheduling_strategy = "REPLICA"
  # This can be used to update tasks to use a newer container image with same
  # image/tag combination (e.g., myimage:latest)
  force_new_deployment = true
}
