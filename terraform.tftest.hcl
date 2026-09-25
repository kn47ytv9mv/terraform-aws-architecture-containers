mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

mock_provider "random" {}

run "a_single_availability_zone_is_rejected" {
  command = plan

  variables {
    availability_zone_count = 1
  }

  expect_failures = [var.availability_zone_count]
}

run "a_cpu_size_fargate_does_not_offer_is_rejected" {
  command = plan

  variables {
    task_cpu = 768
  }

  expect_failures = [var.task_cpu]
}

run "a_maximum_task_count_below_the_minimum_is_rejected" {
  command = plan

  variables {
    min_task_count = 4
    max_task_count = 2
  }

  expect_failures = [var.max_task_count]
}

run "the_default_platform_alarms_on_its_service_and_load_balancer" {
  command = plan

  assert {
    condition     = module.monitoring.alarm_count == 5
    error_message = "The default platform should alarm on the service's CPU and memory, and on the load balancer's 5XX responses, unhealthy hosts, and response time."
  }

  assert {
    condition     = length(module.monitoring.alarm_names) == module.monitoring.alarm_count
    error_message = "Every alarm created should appear in the alarm_names output."
  }
}

run "the_service_is_registered_as_a_scalable_target_with_one_policy" {
  command = plan

  assert {
    condition     = module.service_scaling.resource_id == "service/${module.cluster.name}/${module.service.name}"
    error_message = "Application autoscaling addresses an ECS service by cluster and service name, so the scalable target must be built from both."
  }

  assert {
    condition     = length(module.service_scaling.policy_arns) == 1
    error_message = "A scalable target with no policies registers the service and then never scales it, so exactly one CPU policy is expected."
  }
}

run "every_tier_spans_the_requested_availability_zones" {
  command = plan

  variables {
    availability_zone_count = 3
  }

  assert {
    condition     = length(module.network.subnet_ids["tasks"]) == 3
    error_message = "The task subnets should cover every requested availability zone."
  }

  assert {
    condition     = length(module.network.subnet_ids["storage"]) == 3
    error_message = "The storage subnets should cover every requested availability zone, so each zone's tasks reach a mount target without crossing zones."
  }

  assert {
    condition     = length(module.network.subnet_ids["public"]) == 3
    error_message = "The public subnets should cover every requested availability zone, since the load balancer spans all of them."
  }
}

run "no_domain_name_creates_no_dns_and_no_certificate" {
  command = plan

  assert {
    condition     = length(module.certificate) == 0
    error_message = "A certificate should only be created when a domain name is supplied."
  }

  assert {
    condition     = length(module.zone) == 0
    error_message = "A hosted zone should only be created when a domain name is supplied."
  }

  assert {
    condition     = length(module.records) == 0
    error_message = "An alias record should only be created when a domain name is supplied."
  }

  assert {
    condition     = length(output.name_servers) == 0
    error_message = "Without a hosted zone there are no name servers to delegate to."
  }
}

run "a_domain_name_creates_the_zone_certificate_and_record" {
  command = plan

  variables {
    domain_name = "example.com"
  }

  assert {
    condition     = length(module.certificate) == 1
    error_message = "Supplying a domain name should create a certificate for it."
  }

  assert {
    condition     = length(module.zone) == 1
    error_message = "Supplying a domain name should create a hosted zone for it."
  }

  assert {
    condition     = length(module.records) == 1
    error_message = "Supplying a domain name should create an alias record pointing at the load balancer."
  }
}

run "no_budget_amount_creates_no_budget" {
  command = plan

  assert {
    condition     = length(module.budget) == 0
    error_message = "A budget should only be created when a monthly amount is supplied."
  }
}

run "a_budget_amount_creates_a_budget_notifying_the_alarm_topic" {
  command = plan

  variables {
    monthly_budget = "500"
  }

  assert {
    condition     = length(module.budget) == 1
    error_message = "Supplying a monthly amount should create a budget."
  }
}

run "an_alarm_email_subscribes_to_the_topic" {
  command = plan

  variables {
    alarm_email = "ops@example.com"
  }

  assert {
    condition     = length(module.alerts.subscription_arns) == 1
    error_message = "Supplying an address should subscribe it to the alarm topic."
  }
}
