# AWS Setup

Everything here is created by the Terraform in `aws/iac/`, run by the Jenkins pipeline (stages run as pods on a Kubernetes cluster, see the README, section 4). Region: `ap-south-1` (Mumbai). The diagram is in `aws/architecture-diagram.png`.

## How it is created

The pipeline's "Create AWS environment" stage runs `terraform init` and `terraform apply` (45 resources) in a Terraform pod, using the AWS credentials stored in the Jenkins credential store (`aws-creds`). `ACTION = destroy` runs `terraform destroy` against the same state and removes everything the pipeline created.

**Terraform state.** The state is in an S3 bucket, not in a pod, on the Jenkins machine or in the repository. The bucket is versioned, encrypted and has public access blocked, and Terraform locks the state with S3 native locking (`use_lockfile`). It is created once, separately, by `aws/bootstrap-state/`. The bucket name is set in the `Jenkinsfile` (`TF_STATE_BUCKET`) and passed to `terraform init` as flags. The bucket name has a random suffix and contains no account ID. The state holds the outputs, the generated database password and the generated SSH private key.

**Between stages.** Pods share nothing, so the Terraform outputs (addresses, registry) and the SSH key are passed to later stages with `stash` and `unstash`.

| File | What it creates |
|---|---|
| `network.tf` | VPC, internet gateway, two public subnets, two private subnets, route tables, the DB subnet group, three security groups and their rules |
| `iam.tf` | The app host's IAM role, policy and instance profile |
| `database.tf` | Two ECR repositories (with a lifecycle policy), the RDS instance, a generated database password and the SSM parameters |
| `compute.tf` | An SSH key pair, and the two EC2 instances with their first-boot script |
| `variables.tf`, `outputs.tf`, `providers.tf` | Inputs, outputs, and the provider and state backend settings |
| `aws/bootstrap-state/` | Separate one-time Terraform: the S3 bucket for the state above. It is not part of the 45 resources and is not removed by `destroy`. |

## Components

| Component | Details |
|---|---|
| App host `todo-app` | EC2 t3.small, Ubuntu 24.04, public subnet. Runs the nginx frontend (port 80), the Spring Boot backend, node-exporter and cAdvisor with Docker Compose (`docker-compose.prod.yml`). |
| Ops host `todo-ops` | EC2 t3.medium, Ubuntu 24.04, public subnet. Runs Prometheus (localhost only) and Grafana (port 3000), plus its own node-exporter and cAdvisor. |
| Database `todo-db` | RDS MySQL 8.4, `db.t3.micro`, single-AZ, in private subnets, **not publicly accessible**, storage encrypted, 3-day automated backups. |
| Registry | ECR repositories `todo-backend` and `todo-frontend`, immutable tags (the first 8 characters of the commit hash), scan on push, the 10 most recent images kept. |
| Secrets | SSM Parameter Store under `/todo/`: `db-host` and `db-username` (String); `db-password`, `cohere-api-key` and `slack-webhook-url` (SecureString). |

Both hosts have a 20 GB encrypted gp3 disk and require IMDSv2 (token-based metadata requests). On first boot, a script installs Docker, Docker Compose and the AWS CLI, and the pipeline's "Wait for hosts" stage waits (up to 5 minutes per host) for it to finish. The hosts are in public subnets with public IPs that change when an instance is replaced. There is no NAT gateway, load balancer or Elastic IP, to keep the footprint and cost small. The two RDS subnets are in different availability zones because RDS requires a subnet group that spans two, and they have no route to the internet.

## Security groups

**`todo-app-sg` (app host)**

| Port | Source | Purpose |
|---|---|---|
| 80 | `0.0.0.0/0` | The public application. This is the only port open to the internet. |
| 22 | the operator's IP `/32` | SSH, used by the pipeline to deploy |
| 8080, 9100, 8081 | `todo-ops-sg` only | Prometheus scrapes backend metrics, node-exporter and cAdvisor |

The metrics ports are also published on the host's private IP only (`METRICS_BIND_IP` in `docker-compose.prod.yml`), so they are not reachable on the public interface even if a rule were added by mistake.

**`todo-ops-sg` (ops host)**

| Port | Source | Purpose |
|---|---|---|
| 22 | the operator's IP `/32` | SSH, used by the pipeline to start monitoring |
| 3000 | the operator's IP `/32`, plus optional viewer IPs | Grafana |

The pipeline's "Prepare" stage detects the operator's public IP on every run (the address the pipeline pod reaches the internet from) and passes it to Terraform. Extra Grafana viewers are added with the `GRAFANA_VIEWER_CIDRS` parameter. `0.0.0.0/0` is refused by a validation in `variables.tf`.

**`todo-rds-sg` (database)**

| Port | Source |
|---|---|
| 3306 | `todo-app-sg` only (no CIDR rules) |

Limitations: the operator's IP can change, and a new pipeline run then updates the rules. Everything uses plain HTTP, with no TLS. A real setup would put a load balancer with a certificate in front of the app and use SSM Session Manager instead of public SSH.

## IAM

No AWS keys are stored on the hosts.

**`todo-app-role`** (app host only):
- `ecr:GetAuthorizationToken` on `*` (this action cannot be scoped to a resource).
- Pull-only ECR actions (`BatchCheckLayerAvailability`, `BatchGetImage`, `GetDownloadUrlForLayer`) on the two repositories only.
- `ssm:GetParameter`, `GetParameters` and `GetParametersByPath` on `parameter/todo/*` only.

**The ops host has no instance role**, because Prometheus and Grafana never call AWS.

**The pipeline's own access** comes from an IAM user's long-lived access key, stored in the Jenkins credential store as `aws-creds` and exposed only inside the steps that need it, masked in the log. It is not in the repository, in a file or in an environment file. I ran it with an administrator user and did not work out a minimal permission set. That is the least-privilege gap in this setup.

**The pipeline's access to the cluster** is separate: Jenkins signs in to the Kubernetes API with the `todo-ci-token` credential, which belongs to the `jenkins-ci` service account. Its Role only allows pod operations in the `todo-ci` namespace (`k8s/todo-ci.yaml`).

## Secrets

Real values are never in the repository.
- The database password is generated by Terraform (`random_password`) and stored in SSM. It also exists in the Terraform state, which is in the S3 bucket (encrypted, versioned, public access blocked).
- `aws/deploy.sh` reads the five `/todo/*` parameters with the instance role at deploy time and passes them to Compose as environment variables.
- The Cohere API key and Slack webhook URL are **placeholders**. The app starts and the to-do features work, but the "summarize and send to Slack" feature does not work with real services. Real values can be set later with `aws ssm put-parameter --overwrite`, and Terraform will not overwrite them.
- The Grafana password comes from the Jenkins credential `grafana-admin-password` and is sent to the ops host through standard input, so it never appears in a command line or log.
- The generated SSH private key is in the Terraform state and is also copied between stages with `stash`, so it is stored in Jenkins for the duration of a build. A production setup would use SSM Session Manager and no SSH key at all.

## How a deploy reaches the hosts

1. A Kaniko pod builds the backend and frontend images and pushes them to ECR with the commit tag, using a short-lived ECR login token. Tests run before anything is created in AWS.
2. A pod copies `docker-compose.prod.yml` and `aws/deploy.sh` to the app host over SSH and runs `deploy.sh <tag>`.
3. `deploy.sh` logs in to ECR, fetches secrets from SSM, starts the stack, checks health and rolls back on failure (details in `FAILURE_AND_ROLLBACK.md`).
4. The pipeline then copies `monitoring/` to the ops host and starts Prometheus and Grafana.

## What is not covered

- Multi-AZ, deletion protection and longer backup retention on RDS (kept off for cost, and `destroy` takes no final snapshot).
- TLS, a domain name and a load balancer.
- A minimal IAM policy for the user the pipeline runs as, and short-lived credentials instead of a long-lived key.
- A root access key check and a budget alert on my own AWS account.

## Cleanup

Run the pipeline with `ACTION = destroy`. It removes everything above except the S3 state bucket. Check the AWS console afterwards for leftover instances, RDS databases and volumes. Delete the state bucket last, and never while AWS resources still exist: it holds the Terraform state and the SSH key, and without it Terraform forgets what it created and the resources keep costing money.
