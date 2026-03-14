# ECS CLUSTER
resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = { Name = "${var.app_name}-cluster" }
}

# LATEST ECS-OPTIMISED AMI
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

#LAUNCH TEMPLATE
resource "aws_launch_template" "ecs" {
  name_prefix            = "${var.app_name}-ecs-lt-"
  image_id               = data.aws_ssm_parameter.ecs_ami.value
  instance_type          = "t3.small"
  vpc_security_group_ids = [aws_security_group.ecs.id]

  iam_instance_profile { arn = aws_iam_instance_profile.ecs.arn }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_CONTAINER_METADATA=true >> /etc/ecs/ecs.config
  EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }
  tags = { Name = "${var.app_name}-ecs-instance" }
}

#AUTO SCALING GROUP
resource "aws_autoscaling_group" "ecs" {
  name                  = "${var.app_name}-ecs-asg"
  desired_capacity      = 2
  min_size              = 1
  max_size              = 4
  vpc_zone_identifier   = aws_subnet.private[*].id
  protect_from_scale_in = true

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = "${var.app_name}-ecs-instance"
    propagate_at_launch = true
  }
}

#CAPACITY PROVIDER
resource "aws_ecs_capacity_provider" "main" {
  name = "${var.app_name}-cp"
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 80
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]
  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.main.name
  }
}

# CLOUDWATCH LOG GROUP
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 30
}

# ALB
resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${var.app_name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.app_name}-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/healthz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  deregistration_delay = 30
  tags                 = { Name = "${var.app_name}-tg" }
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

# ECS TASK DEFINITION 
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app_name}-task"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  cpu                      = 256
  memory                   = 512

  container_definitions = jsonencode([{
    name      = "app"
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = 3000
      hostPort      = 0
      protocol      = "tcp"
    }]

    environment = [
      { name = "ENV",           value = var.environment },
      { name = "DB_NAME",       value = "appdb" },
      { name = "DB_USER",       value = "appuser" },
      { name = "DB_HOST",       value = aws_db_instance.main.address },
      { name = "S3_BUCKET",     value = aws_s3_bucket.frontend.bucket },
      { name = "SNS_TOPIC_ARN", value = aws_sns_topic.alerts.arn },
      { name = "APP_NAME",      value = var.app_name },
      { name = "AWS_REGION",    value = var.aws_region }
    ]

    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = aws_secretsmanager_secret.db_password.arn
      },
      {
        name      = "JWT_SECRET"
        valueFrom = "${aws_secretsmanager_secret.app_secrets.arn}:jwt_secret::"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "app"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/healthz || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = { Name = "${var.app_name}-task" }
}

# ECS SERVICE 
resource "aws_ecs_service" "app" {
  name            = "${var.app_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 100
    base              = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]
  tags       = { Name = "${var.app_name}-service" }
}
