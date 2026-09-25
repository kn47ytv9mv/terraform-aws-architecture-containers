# terraform-aws-architecture-containers

Terraform module for a complete container platform — a public load
balancer and web ACL in front of a Fargate service running in private
subnets, backed by a shared file system — assembled from this family's
single-purpose modules.

## Cost

This is the most expensive kind of module in this family, because it
stands up running infrastructure rather than configuration. At the
defaults, the standing charges are two NAT gateways (one per
availability zone), two Fargate tasks at 0.5 vCPU and 1 GiB each, an
application load balancer, a WAFv2 web ACL and its two rules, an EFS
file system with a mount target per availability zone, Container
Insights on the cluster, and five CloudWatch alarms. Nothing here is
free-tier. Destroy it when you are finished with it, and set
`monthly_budget` so a forecast overrun reaches you.

Three costs grow without an obvious ceiling and are worth watching.
`max_task_count` bounds how far autoscaling may take the compute bill,
and the default of 10 is five times the resting cost. The web ACL
charges per million requests it inspects, so its cost tracks traffic
rather than capacity. EFS bills for what is stored rather than what is
provisioned, so a container writing logs or caches into `storage_path`
accrues charges no autoscaling policy will ever scale back down.

The single largest saving available is `availability_zone_count = 2`
rather than 3, which this module already defaults to — each added zone
adds a NAT gateway, its data processing charges, and another EFS mount
target.

## Design

Every resource comes from a published module in this family, resolved
from the Terraform Registry under a `~> 1.0` version constraint. This
module contains no `resource` blocks of its own; it is wiring and
nothing else. Read any individual module's README to
understand what it creates and why its defaults are what they are.

### What it builds

| Layer | Contents |
|---|---|
| Network | VPC across `availability_zone_count` zones, public, task, and storage subnets, an S3 gateway endpoint, and flow logs to CloudWatch |
| Edge | Internet-facing application load balancer, HTTPS listener, HTTP-to-HTTPS redirect, a fixed-response rule sealing `/internal`, access logs to S3 |
| Filtering | Regional WAFv2 web ACL carrying an AWS managed rule group and a per-address rate limit, associated with the load balancer, logging to CloudWatch with credential headers redacted |
| Compute | ECS cluster with Container Insights, a Fargate service in the private task subnets, target-tracking autoscaling on CPU between `min_task_count` and `max_task_count` |
| Storage | Encrypted EFS file system with a mount target per storage subnet, and an access point confining every task to `storage_path` |
| Cross-cutting | Customer managed KMS key, Secrets Manager secret, separate execution and task roles, SNS alarm topic, five CloudWatch alarms, daily AWS Backup plan, optional budget |

The three security groups form a chain: the internet reaches only the
load balancer, the load balancer reaches only the tasks on
`container_port`, and only the tasks reach the file system on 2049.
Nothing behind the load balancer is reachable from the internet, and
`assign_public_ip` is false, so a task's only route out is the NAT
gateway.

### Where the image comes from

This family has no container registry module, and this architecture does
not invent one. `container_image` is a plain reference to an image some
registry already holds — a public registry, or a private repository
managed outside this architecture. The default is a public image that
starts and answers on port 80, so the load balancer, the health check,
and the autoscaling wiring can be proven end to end before a real image
is substituted.

The consequence worth knowing is that Terraform registers a task
definition revision and then stops caring. Deploying a new image is a
change to `container_image` and another apply, or a deployment performed
outside Terraform against the `service_name` output. Terraform does not
watch a tag for movement, so `:stable` or `:latest` will drift from what
is actually running.

### Two roles, not one

The execution role and the task role are separate, and the distinction
matters. The execution role is what ECS itself assumes, before the
container exists, to pull the image and open the log stream; it carries
only the AWS managed policy for that. The task role is what code inside
the container assumes, and it is the one granted read access to the
Secrets Manager secret, decryption under the architecture's KMS key, and
IAM-authenticated access to the file system through the access point and
no other path.

Nothing is injected into the task definition from the secret. A secret
referenced in a container definition is fetched by the execution role at
start-up and frozen into the task's environment for its lifetime, which
means a rotation only takes effect on the next deployment. Reading it
through the task role at runtime costs a call and removes that trap.

### Where a domain fits

`domain_name` is optional, and it changes the shape of what is built.
Left null, the architecture's entry point is the load balancer's own
`*.elb.amazonaws.com` name and no certificate is issued — useful for a
staging environment nobody types a URL for. Set, it additionally creates
a public hosted zone, an ACM certificate, and an alias record at the
apex pointing to the load balancer.

**Setting `domain_name` does not finish the job.** A newly created
hosted zone is not authoritative for the domain until the registrar is
pointed at it, and ACM cannot validate the certificate until it is. Take
the `name_servers` output to the registrar; until you do, the apply will
wait on certificate validation and eventually time out.

### Things it deliberately does not do

Three Trivy findings survive on this configuration by design, and they
are worth stating rather than silently suppressing:

- **Unrestricted egress** on the load balancer and task security
  groups. A task that cannot reach the internet cannot pull its own
  image from a public registry, call a third-party API, or reach an AWS
  service without a VPC endpoint for it. Narrow this once you know what
  the workload actually talks to.
- **An internet-facing load balancer.** That is the point of the edge
  layer. Set `internal = true` on the `alb` module for a platform
  fronted by something else.
- **No access logging on the log bucket.** The bucket that receives the
  load balancer's access logs does not log access to itself.

The web ACL's `default_action` is `allow`, which is the opposite of the
`wafv2-web-acl` module's own safer default. A public site has to serve
requests nobody wrote a rule for, so the ACL is a filter on top of open
traffic rather than a gate in front of it. Reversing that means writing
an explicit allow rule for every legitimate request shape first, which
is the right model for a private API and the wrong one here.

Backups are arranged twice, on purpose. The file system carries EFS's
own backup policy, which AWS manages without a plan or a role. The
backup plan alongside it selects by the `Backup = "true"` tag and covers
anything else in the account carrying that tag, so a resource added
later is picked up without changing this module.

## Usage

```hcl
module "staging" {
  source  = "kn47ytv9mv/architecture-containers/aws"
  version = "~> 1.0"

  name            = "staging"
  container_image = "public.ecr.aws/nginx/nginx:stable"

  alarm_email = "ops@example.com"
}
```

A production platform across three availability zones, with a domain, a
larger task, and a budget:

```hcl
module "production" {
  source = "github.com/kn47ytv9mv/terraform-aws-architecture-containers"

  name                    = "production"
  region                  = "us-east-1"
  availability_zone_count = 3

  container_image   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/api:2026.09.24"
  container_port    = 8080
  health_check_path = "/healthz"

  task_cpu       = 1024
  task_memory    = 2048
  min_task_count = 3
  max_task_count = 30

  waf_rate_limit = 10000

  domain_name    = "example.com"
  alarm_email    = "ops@example.com"
  monthly_budget = "3000"

  tags = {
    Environment = "production"
    Backup      = "true"
  }
}
```

The `Backup` tag in that example is not decorative — the backup plan
selects resources by `Backup = "true"`, so anything without it is
created but never backed up.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.11 |
| aws | ~> 6.61 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| region | Region every resource in this architecture is created in. | `"us-east-1"` | no |
| name | Name prefix applied to every resource, so one account can hold several copies of this architecture without collision. | `"containers"` | no |
| vpc_cidr | IPv4 range for the VPC. Each tier carves a /24 out of it per availability zone. | `"10.0.0.0/16"` | no |
| availability_zone_count | Availability zones to spread across. Two is the minimum an application load balancer will accept, and the minimum at which the loss of one zone leaves the service running. | `2` | no |
| container_image | Image the service runs. This family has no container registry module, so the image is referenced by whatever registry already holds it — a public registry, or a private repository this architecture does not manage. The default is a public image that starts and answers on port 80, so the architecture is provably working before a real image replaces it. | `"public.ecr.aws/nginx/nginx:stable"` | no |
| container_port | Port the container listens on. The load balancer's target group, the task security group, and the health check all follow this value, so changing it in one place is enough. | `80` | no |
| health_check_path | Path the target group requests to decide whether a task is healthy. A task failing this check is killed and replaced, so it must be a path the container answers without authentication. | `"/"` | no |
| task_cpu | CPU units reserved for each task. Fargate accepts only a fixed set of values, and each one constrains the memory values that may accompany it. | `512` | no |
| task_memory | Memory in mebibytes reserved for each task. Fargate permits only certain values for each `task_cpu`, and a container exceeding this reservation is killed rather than throttled. | `1024` | no |
| min_task_count | Fewest tasks to keep running. Two spreads the service across availability zones, so a zone failure does not take the service with it. | `2` | no |
| max_task_count | Most tasks autoscaling may run up to. This is the ceiling on both the traffic the service can absorb and the bill it can generate. | `10` | no |
| target_cpu_utilization | Average CPU utilization autoscaling holds the service at. Lower values add tasks sooner and cost more; higher values leave less headroom for a traffic spike arriving faster than a task can start. | `60` | no |
| log_retention_in_days | Days container logs are kept before CloudWatch deletes them. Logs are charged for storage as well as ingestion, so an unbounded retention is a standing cost that only grows. | `30` | no |
| waf_rate_limit | Requests a single client address may make in any five-minute window before the web ACL blocks it. This is a blunt defence against scraping and brute force, not against a distributed attack, which arrives from too many addresses for a per-address limit to see. | `2000` | no |
| waf_managed_rule_group | AWS managed rule group the web ACL evaluates before its rate limit. The common set covers the broad OWASP categories; replace it or add to it once the workload's own traffic is understood. | `"AWSManagedRulesCommonRuleSet"` | no |
| storage_path | Directory inside the file system the access point exposes, and the path the container mounts it at. The access point creates this directory and confines every request through it, so a task cannot read anything outside it. | `"/data"` | no |
| domain_name | Domain the architecture serves. Setting it creates a public hosted zone, an ACM certificate, and an alias record to the load balancer. If null, the load balancer's own DNS name is the only entry point. | `null` | no |
| alarm_email | Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then. | `null` | no |
| monthly_budget | Monthly spend in USD to alarm on, as a string. If null, no budget is created. | `null` | no |
| tags | A map of tags applied to every resource in the architecture. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| vpc_id | The ID of the VPC this architecture created. |
| load_balancer_dns_name | DNS name of the load balancer — the architecture's entry point when no `domain_name` was supplied. |
| cluster_name | Name of the ECS cluster the service runs in. |
| service_name | Name of the ECS service, for deploying a new task definition to it outside Terraform. |
| task_definition_arn | ARN of the task definition Terraform registered, including its revision number. |
| file_system_id | ID of the shared file system every task mounts. |
| task_role_arn | ARN of the role the containers assume, and the identity to grant any further application permission to. |
| web_acl_arn | ARN of the web ACL filtering requests to the load balancer. |
| log_group_name | CloudWatch log group the containers write to. |
| alerts_topic_arn | ARN of the topic every alarm in this architecture notifies. |
| alarm_count | Number of CloudWatch alarms the monitoring baseline created. |
| name_servers | Name servers for the hosted zone, to delegate the domain to. Empty when no `domain_name` was supplied. |

## License

MIT — see [LICENSE.md](LICENSE.md).
