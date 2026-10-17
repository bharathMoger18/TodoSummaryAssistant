# AWS Setup

Region: `ap-south-1` (Mumbai). The diagram is in `aws/architecture-diagram.png`.

## Components

| Component | Name | Details |
|---|---|---|
| App host | `todo-app` | EC2 t3.small. Runs the nginx frontend (port 80), the Spring Boot backend, node-exporter and cAdvisor with Docker Compose (`docker-compose.prod.yml`). |
| Ops host | `todo-ops` | EC2 t3.medium. Runs Jenkins (port 8080), Prometheus (localhost only) and Grafana (port 3000), plus its own node-exporter and cAdvisor. |
| Database | `todo-db` | RDS MySQL 8.4.7, `db.t3.micro`, single-AZ, **not publicly accessible**, storage encrypted, 3-day automated backups. |
| Registry | `todo-backend`, `todo-frontend` | ECR repositories. Images are tagged with the 8-character commit SHA. |
| Secrets | `/todo/*` | SSM Parameter Store: `db-host`, `db-username` (String); `db-password`, `cohere-api-key`, `slack-webhook-url` (SecureString). |

The two hosts are in different subnets (private IPs `10.0.1.x` for ops and `10.0.2.x` for app). Both have public IPs, because there is no NAT gateway or load balancer in this small setup.

## Security groups

**`todo-app-sg` (app host)**

| Port | Source | Purpose |
|---|---|---|
| 80 | `0.0.0.0/0` | The public application. This is the only port open to the internet. |
| 22 | my IP `/32`, and `todo-ops-sg` | SSH for me, and for Jenkins deploys. |
| 8080, 9100, 8081 | `todo-ops-sg` only | Prometheus scrapes backend metrics, node-exporter and cAdvisor. |

The metrics ports are also published on the host's private IP only (`METRICS_BIND_IP` in `docker-compose.prod.yml`), so they are not reachable on the public interface even if a rule were added by mistake.

**`todo-ops-sg` (ops host)**

| Port | Source | Purpose |
|---|---|---|
| 22 | my IP `/32` | SSH |
| 3000 | my IP `/32` | Grafana |
| 8080 | my IP `/32` | Jenkins UI |

**RDS security group**

| Port | Source |
|---|---|
| 3306 | `todo-app-sg` only (no CIDR rules) |

Limitations: my IP changes when my network changes, and then I must update the three `/32` rules. Port 80 is plain HTTP with no TLS, and Grafana and Jenkins also use plain HTTP. A real setup would put a load balancer with a certificate in front, and use a VPN or SSM Session Manager instead of public SSH.

## IAM

No AWS keys are stored on the hosts. Each host has an instance role.

**`todo-app-role`** (app host):
- `ecr:GetAuthorizationToken` on `*` (this action cannot be scoped to a resource).
- Pull-only ECR actions (`BatchCheckLayerAvailability`, `BatchGetImage`, `GetDownloadUrlForLayer`) on the two repositories only.
- `ssm:GetParameter`, `GetParameters` and `GetParametersByPath` on `parameter/todo/*` only.

**`todo-ops-role`** (ops host, where Jenkins runs):
- `ecr:GetAuthorizationToken` on `*`.
- Push and read actions on the two repositories only (upload, `PutImage`, `DescribeImages`, `ListImages`, plus pull).
- No SSM, EC2 or RDS permissions. Jenkins can push images but cannot read the database password.

Jenkins uses this role for ECR and uses an SSH credential (`app-ssh`) stored in Jenkins to deploy. I also use a separate IAM user profile from my laptop to run `aws/setup.sh` and the checks in this document.

## Secrets

Real values are never in the repo. `aws/deploy.sh` reads the five `/todo/*` parameters with the instance role at deploy time and passes them to Compose as environment variables. `.env.example` lists the variable names with fake values.

**The Cohere API key and Slack webhook URL are placeholders.** The app starts and the to-do features work, but the "summarize and send to Slack" feature does not work with real services.

## How a deploy reaches the host

1. Jenkins (on `todo-ops`) builds and tests, then pushes both images to ECR with the commit tag.
2. Jenkins copies `docker-compose.prod.yml` and `aws/deploy.sh` to the app host over SSH and runs `deploy.sh <tag>`.
3. `deploy.sh` logs in to ECR, fetches secrets from SSM, starts the stack, checks health and rolls back on failure (details in `FAILURE_AND_ROLLBACK.md`).

## What is scripted and what is not

- `aws/deploy.sh` is the deploy script run on the app host.
- `aws/setup.sh` only contains the monitoring security-group rules. The rest of the infrastructure (EC2, RDS, ECR, IAM roles, SSM parameters, the other security groups) was created by hand through the AWS console and CLI, and there is no Terraform or CloudFormation. Rebuilding it needs this document, not a single command.

## Not done

- Root access key check and deactivation.
- A monthly budget alert.
- Multi-AZ, deletion protection and longer backup retention on RDS (kept off for cost).

## Cleanup after review

Stop both EC2 instances and the RDS instance. Delete them if they are no longer needed, because RDS and EC2 cost money while running.
