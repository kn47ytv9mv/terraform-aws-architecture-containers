variable "region" {
  default     = "us-east-1"
  description = "Region every resource in this architecture is created in."
}

variable "name" {
  default     = "containers"
  description = "Name prefix applied to every resource, so one account can hold several copies of this architecture without collision."
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "IPv4 range for the VPC. Each tier carves a /24 out of it per availability zone."
}

variable "availability_zone_count" {
  default     = 2
  description = "Availability zones to spread across. Two is the minimum an application load balancer will accept, and the minimum at which the loss of one zone leaves the service running."

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "This architecture needs at least two availability zones: an application load balancer requires subnets in two, and a single-zone task placement has nowhere to fail over to."
  }
}

variable "container_image" {
  default     = "public.ecr.aws/nginx/nginx:stable"
  description = "Image the service runs. This family has no container registry module, so the image is referenced by whatever registry already holds it — a public registry, or a private repository this architecture does not manage. The default is a public image that starts and answers on port 80, so the architecture is provably working before a real image replaces it."
}

variable "container_port" {
  default     = 80
  description = "Port the container listens on. The load balancer's target group, the task security group, and the health check all follow this value, so changing it in one place is enough."
}

variable "health_check_path" {
  default     = "/"
  description = "Path the target group requests to decide whether a task is healthy. A task failing this check is killed and replaced, so it must be a path the container answers without authentication."
}

variable "task_cpu" {
  default     = 512
  description = "CPU units reserved for each task. Fargate accepts only a fixed set of values, and each one constrains the memory values that may accompany it."

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.task_cpu)
    error_message = "Fargate accepts only 256, 512, 1024, 2048, 4096, 8192, or 16384 CPU units. Any other value is rejected at registration time, not at plan time, so it is checked here instead."
  }
}

variable "task_memory" {
  default     = 1024
  description = "Memory in mebibytes reserved for each task. Fargate permits only certain values for each task_cpu, and a container exceeding this reservation is killed rather than throttled."
}

variable "min_task_count" {
  default     = 2
  description = "Fewest tasks to keep running. Two spreads the service across availability zones, so a zone failure does not take the service with it."
}

variable "max_task_count" {
  default     = 10
  description = "Most tasks autoscaling may run up to. This is the ceiling on both the traffic the service can absorb and the bill it can generate."

  validation {
    condition     = var.max_task_count >= var.min_task_count
    error_message = "max_task_count must be at least min_task_count. Application autoscaling rejects a scalable target whose maximum is below its minimum."
  }
}

variable "target_cpu_utilization" {
  default     = 60
  description = "Average CPU utilization autoscaling holds the service at. Lower values add tasks sooner and cost more; higher values leave less headroom for a traffic spike arriving faster than a task can start."
}

variable "log_retention_in_days" {
  default     = 30
  description = "Days container logs are kept before CloudWatch deletes them. Logs are charged for storage as well as ingestion, so an unbounded retention is a standing cost that only grows."
}

variable "waf_rate_limit" {
  default     = 2000
  description = "Requests a single client address may make in any five-minute window before the web ACL blocks it. This is a blunt defence against scraping and brute force, not against a distributed attack, which arrives from too many addresses for a per-address limit to see."
}

variable "waf_managed_rule_group" {
  default     = "AWSManagedRulesCommonRuleSet"
  description = "AWS managed rule group the web ACL evaluates before its rate limit. The common set covers the broad OWASP categories; replace it or add to it once the workload's own traffic is understood."
}

variable "storage_path" {
  default     = "/data"
  description = "Directory inside the file system the access point exposes, and the path the container mounts it at. The access point creates this directory and confines every request through it, so a task cannot read anything outside it."
}

variable "domain_name" {
  default     = null
  description = "Domain the architecture serves. Setting it creates a public hosted zone, an ACM certificate, and an alias record to the load balancer. If null, the load balancer's own DNS name is the only entry point."
}

variable "alarm_email" {
  default     = null
  description = "Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then."
}

variable "monthly_budget" {
  default     = null
  description = "Monthly spend in USD to alarm on, as a string. If null, no budget is created."
}

variable "tags" {
  default     = null
  description = "A map of tags applied to every resource in the architecture."
}
