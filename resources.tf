module "network" {
  source  = "kn47ytv9mv/vpc/aws"
  version = "~> 1.0"

  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count

  subnets = {
    public  = { public = true }
    tasks   = { nat_gateway_access = true }
    storage = {}
  }

  gateway_endpoints = {
    s3 = {}
  }

  flow_logs = [
    {
      destination_arn  = module.flow_log_group.arn
      destination_type = "cloud-watch-logs"
    },
  ]

  tags = var.tags
}

module "key" {
  source  = "kn47ytv9mv/kms-key/aws"
  version = "~> 1.0"

  description = "${var.name} container platform data key"

  tags = var.tags
}

module "key_alias" {
  source  = "kn47ytv9mv/kms-alias/aws"
  version = "~> 1.0"

  name          = var.name
  target_key_id = module.key.arn
}

module "flow_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/vpc/${var.name}"
  kms_key_id        = module.key.arn
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

module "service_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/ecs/${var.name}"
  kms_key_id        = module.key.arn
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

module "waf_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "aws-waf-logs-${var.name}"
  kms_key_id        = module.key.arn
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

module "log_bucket" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket = "${var.name}-logs"

  tags = var.tags
}

module "alb_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-alb"
  vpc_id      = module.network.vpc_id
  description = "Public entry point for ${var.name}."

  ingress_rules = [
    { description = "HTTPS from the internet", ip_protocol = "tcp", from_port = 443, to_port = 443, cidr_ipv4 = "0.0.0.0/0" },
    { description = "HTTP from the internet", ip_protocol = "tcp", from_port = 80, to_port = 80, cidr_ipv4 = "0.0.0.0/0" },
  ]

  egress_rules = [
    { description = "All outbound", ip_protocol = "-1", from_port = -1, to_port = -1, cidr_ipv4 = "0.0.0.0/0" },
  ]

  tags = var.tags
}

module "task_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-tasks"
  vpc_id      = module.network.vpc_id
  description = "Tasks for ${var.name}, reachable only from the load balancer."

  ingress_rules = [
    { description = "From the load balancer", ip_protocol = "tcp", from_port = var.container_port, to_port = var.container_port, referenced_security_group_id = module.alb_security_group.id },
  ]

  egress_rules = [
    { description = "All outbound", ip_protocol = "-1", from_port = -1, to_port = -1, cidr_ipv4 = "0.0.0.0/0" },
  ]

  tags = var.tags
}

module "storage_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-storage"
  vpc_id      = module.network.vpc_id
  description = "Shared file system for ${var.name}, reachable only from the tasks."

  ingress_rules = [
    { description = "NFS from the tasks", ip_protocol = "tcp", from_port = 2049, to_port = 2049, referenced_security_group_id = module.task_security_group.id },
  ]

  tags = var.tags
}

module "alb" {
  source  = "kn47ytv9mv/alb/aws"
  version = "~> 1.0"

  name               = "${var.name}-alb"
  internal           = false
  subnet_ids         = module.network.subnet_ids["public"]
  security_group_ids = [module.alb_security_group.id]

  access_logs_bucket = module.log_bucket.bucket
  access_logs_prefix = "alb"

  tags = var.tags
}

module "target_group" {
  source  = "kn47ytv9mv/alb-target-group/aws"
  version = "~> 1.0"

  name              = "${var.name}-tasks"
  vpc_id            = module.network.vpc_id
  port              = var.container_port
  protocol          = "HTTP"
  target_type       = "ip"
  health_check_path = var.health_check_path

  tags = var.tags
}

module "https_listener" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"

  load_balancer_arn = module.alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.domain_name != null ? module.certificate[0].arn : null
  target_group_arn  = module.target_group.arn

  tags = var.tags
}

module "http_redirect" {
  source  = "kn47ytv9mv/alb-listener/aws"
  version = "~> 1.0"

  load_balancer_arn = module.alb.arn
  port              = 80
  protocol          = "HTTP"
  type              = "redirect"

  redirect = {
    port        = "443"
    protocol    = "HTTPS"
    status_code = "HTTP_301"
  }

  tags = var.tags
}

module "internal_path_rule" {
  source  = "kn47ytv9mv/alb-listener-rule/aws"
  version = "~> 1.0"

  listener_arn  = module.https_listener.arn
  priority      = 10
  action_type   = "fixed-response"
  path_patterns = ["/internal", "/internal/*"]

  fixed_response = {
    content_type = "text/plain"
    status_code  = "403"
    message_body = "Not available."
  }

  tags = var.tags
}

module "web_acl" {
  source  = "kn47ytv9mv/wafv2-web-acl/aws"
  version = "~> 1.0"

  name           = var.name
  description    = "Request filtering for ${var.name}."
  scope          = "REGIONAL"
  default_action = "allow"

  rules_json = jsonencode([
    {
      Name           = "managed-rules"
      Priority       = 0
      OverrideAction = { None = {} }

      Statement = {
        ManagedRuleGroupStatement = {
          VendorName = "AWS"
          Name       = var.waf_managed_rule_group
        }
      }

      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "managed-rules"
        SampledRequestsEnabled   = true
      }
    },
    {
      Name     = "rate-limit"
      Priority = 1
      Action   = { Block = {} }

      Statement = {
        RateBasedStatement = {
          Limit            = var.waf_rate_limit
          AggregateKeyType = "IP"
        }
      }

      VisibilityConfig = {
        CloudWatchMetricsEnabled = true
        MetricName               = "rate-limit"
        SampledRequestsEnabled   = true
      }
    },
  ])

  visibility_config = {
    metric_name = var.name
  }

  log_destination_configs = [module.waf_log_group.arn]
  redacted_header_names   = ["authorization", "cookie"]

  tags = var.tags
}

module "web_acl_association" {
  source  = "kn47ytv9mv/wafv2-web-acl-association/aws"
  version = "~> 1.0"

  resource_arn = module.alb.arn
  web_acl_arn  = module.web_acl.arn
}

module "storage" {
  source  = "kn47ytv9mv/efs/aws"
  version = "~> 1.0"

  creation_token     = var.name
  kms_key_id         = module.key.arn
  backup_policy      = "enabled"
  subnet_ids         = module.network.subnet_ids["storage"]
  security_group_ids = [module.storage_security_group.id]

  tags = var.tags
}

module "storage_access_point" {
  source  = "kn47ytv9mv/efs-access-point/aws"
  version = "~> 1.0"

  file_system_id = module.storage.id

  posix_user = {
    uid = 1000
    gid = 1000
  }

  root_directory = {
    path = var.storage_path

    creation_info = {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = var.tags
}

module "app_secrets" {
  source  = "kn47ytv9mv/secretsmanager-secret/aws"
  version = "~> 1.0"

  name        = "${var.name}/app"
  description = "Application configuration for ${var.name}, read at runtime by the task role rather than baked into the task definition."
  kms_key_id  = module.key.arn

  tags = var.tags
}

module "execution_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-execution"
  principal_identifiers = ["ecs-tasks.amazonaws.com"]
  managed_policy_arns   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]

  tags = var.tags
}

module "task_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-task"
  principal_identifiers = ["ecs-tasks.amazonaws.com"]

  inline_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect   = "Allow"
        Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource = [module.storage.arn]

        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = module.storage_access_point.arn
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [module.app_secrets.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [module.key.arn]
      },
    ]
  })

  tags = var.tags
}

module "cluster" {
  source  = "kn47ytv9mv/ecs-cluster/aws"
  version = "~> 1.0"

  name               = var.name
  container_insights = true

  tags = var.tags
}

module "service" {
  source  = "kn47ytv9mv/ecs-service/aws"
  version = "~> 1.0"

  name        = var.name
  cluster_arn = module.cluster.arn

  cpu    = var.task_cpu
  memory = var.task_memory

  execution_role_arn = module.execution_role.arn
  task_role_arn      = module.task_role.arn

  desired_count      = var.min_task_count
  subnet_ids         = module.network.subnet_ids["tasks"]
  security_group_ids = [module.task_security_group.id]
  assign_public_ip   = false

  volumes = [
    {
      name            = "storage"
      file_system_id  = module.storage.id
      access_point_id = module.storage_access_point.id
      iam             = "ENABLED"
    },
  ]

  load_balancer = {
    container_name   = var.name
    container_port   = var.container_port
    target_group_arn = module.target_group.arn
  }

  container_definitions = jsonencode([
    {
      name      = var.name
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        },
      ]

      mountPoints = [
        {
          sourceVolume  = "storage"
          containerPath = var.storage_path
          readOnly      = false
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = module.service_log_group.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "task"
        }
      }
    },
  ])

  tags = var.tags
}

module "service_scaling" {
  source  = "kn47ytv9mv/appautoscaling-target/aws"
  version = "~> 1.0"

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${module.cluster.name}/${module.service.name}"

  min_capacity = var.min_task_count
  max_capacity = var.max_task_count

  policies = [
    {
      name = "cpu"

      target_tracking = {
        target_value           = var.target_cpu_utilization
        predefined_metric_type = "ECSServiceAverageCPUUtilization"
        scale_in_cooldown      = 300
        scale_out_cooldown     = 60
      }
    },
  ]

  tags = var.tags
}

module "certificate" {
  source  = "kn47ytv9mv/acm-certificate/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  domain_name = var.domain_name

  tags = var.tags
}

module "zone" {
  source  = "kn47ytv9mv/route53-zone/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  name = var.domain_name

  tags = var.tags
}

module "records" {
  source  = "kn47ytv9mv/route53-record/aws"
  version = "~> 1.0"
  count   = var.domain_name != null ? 1 : 0

  records = {
    apex = {
      zone_id = module.zone[0].id
      name    = var.domain_name
      type    = "A"

      alias = {
        name    = module.alb.dns_name
        zone_id = module.alb.zone_id
      }
    }
  }
}

module "alerts" {
  source  = "kn47ytv9mv/sns-topic/aws"
  version = "~> 1.0"

  name         = "${var.name}-alerts"
  display_name = "${var.name} alerts"

  subscriptions = var.alarm_email != null ? [
    { protocol = "email", endpoint = var.alarm_email },
  ] : []

  tags = var.tags
}

module "monitoring" {
  source  = "kn47ytv9mv/monitoring-baseline/aws"
  version = "~> 1.0"

  name_prefix   = var.name
  alarm_actions = [module.alerts.arn]
  ok_actions    = [module.alerts.arn]

  ecs_services = {
    app = {
      cluster_name = module.cluster.name
      service_name = module.service.name
    }
  }

  load_balancers = {
    public = { arn_suffix = module.alb.arn_suffix }
  }

  tags = var.tags
}

module "backup_vault" {
  source  = "kn47ytv9mv/backup-vault/aws"
  version = "~> 1.0"

  name        = var.name
  kms_key_arn = module.key.arn

  tags = var.tags
}

module "backup_role" {
  source  = "kn47ytv9mv/iam-role/aws"
  version = "~> 1.0"

  name                  = "${var.name}-backup"
  principal_identifiers = ["backup.amazonaws.com"]
  managed_policy_arns   = ["arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"]

  tags = var.tags
}

module "backup_plan" {
  source  = "kn47ytv9mv/backup-plan/aws"
  version = "~> 1.0"

  name = var.name

  rules = [
    {
      rule_name         = "daily"
      target_vault_name = module.backup_vault.name
      schedule          = "cron(0 5 * * ? *)"
      lifecycle         = { delete_after = 35 }
    },
  ]

  selections = [
    {
      name         = "tagged"
      iam_role_arn = module.backup_role.arn
      resources    = ["*"]

      selection_tags = [
        { key = "Backup", value = "true" },
      ]
    },
  ]

  tags = var.tags
}

module "budget" {
  source  = "kn47ytv9mv/budget/aws"
  version = "~> 1.0"
  count   = var.monthly_budget != null ? 1 : 0

  name         = "${var.name}-monthly"
  limit_amount = var.monthly_budget

  notifications = [
    {
      threshold                 = 80
      notification_type         = "FORECASTED"
      subscriber_sns_topic_arns = [module.alerts.arn]
    },
  ]

  tags = var.tags
}

output "vpc_id" {
  description = "The ID of the VPC this architecture created."
  value       = module.network.vpc_id
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer — the architecture's entry point when no domain_name was supplied."
  value       = module.alb.dns_name
}

output "cluster_name" {
  description = "Name of the ECS cluster the service runs in."
  value       = module.cluster.name
}

output "service_name" {
  description = "Name of the ECS service, for deploying a new task definition to it outside Terraform."
  value       = module.service.name
}

output "task_definition_arn" {
  description = "ARN of the task definition Terraform registered, including its revision number."
  value       = module.service.task_definition_arn
}

output "file_system_id" {
  description = "ID of the shared file system every task mounts."
  value       = module.storage.id
}

output "task_role_arn" {
  description = "ARN of the role the containers assume, and the identity to grant any further application permission to."
  value       = module.task_role.arn
}

output "web_acl_arn" {
  description = "ARN of the web ACL filtering requests to the load balancer."
  value       = module.web_acl.arn
}

output "log_group_name" {
  description = "CloudWatch log group the containers write to."
  value       = module.service_log_group.name
}

output "alerts_topic_arn" {
  description = "ARN of the topic every alarm in this architecture notifies."
  value       = module.alerts.arn
}

output "alarm_count" {
  description = "Number of CloudWatch alarms the monitoring baseline created."
  value       = module.monitoring.alarm_count
}

output "name_servers" {
  description = "Name servers for the hosted zone, to delegate the domain to. Empty when no domain_name was supplied."
  value       = var.domain_name != null ? module.zone[0].name_servers : []
}
