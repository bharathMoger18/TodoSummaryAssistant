# Todo Summary Assistant: DevOps Assessment

A full-stack to-do application (Spring Boot backend, React frontend, MySQL) that can summarize pending tasks with Cohere and post the summary to Slack. This repository is the original project plus my DevOps work: Docker images, a Jenkins pipeline whose stages run as short-lived pods on a Kubernetes cluster, Terraform that builds the whole AWS environment, deployment of the app to EC2 with an RDS database, and Prometheus and Grafana for monitoring. A push to `main` starts the whole pipeline with no manual step.

The application features are unchanged. Everything below is about building, running, deploying and operating it.

## Documents

| File | What it covers |
|---|---|
| `aws/aws-setup.md`, `aws/architecture-diagram.png` | The AWS layout: networking, security groups, IAM, secrets |
| `aws/iac/` | The Terraform that creates all of it |
| `aws/bootstrap-state/` | One-time Terraform that creates the S3 bucket for the main Terraform state |
| `k8s/todo-ci.yaml` | The Kubernetes namespace, service account, RBAC and quota used by the pipeline pods |
| `Jenkinsfile` | The pipeline |
| `FAILURE_AND_ROLLBACK.md` | The six failure scenarios, with what I tested and what I did not |
| `MONITORING_AND_OPERATIONS.md` | Metrics, logs, alerts, early detection |
| `monitoring/` | `prometheus.yml`, `alert-rules.yml`, the Grafana dashboard and provisioning |

## Repository layout

```
Backend/todo-summary-assistant/   Spring Boot + Maven app, Dockerfile, .dockerignore
Frontend/todo/                    React app, Dockerfile, .dockerignore, nginx.conf.template
Jenkinsfile                       the pipeline: every stage runs in its own Kubernetes pod
k8s/todo-ci.yaml                  namespace, service account, Role, RoleBinding, token Secret, ResourceQuota
docker-compose.yml                local run: MySQL + backend + frontend
docker-compose.prod.yml           production stack on the app host (no MySQL, RDS is used)
aws/iac/                          Terraform for the whole AWS environment
aws/bootstrap-state/              one-time Terraform for the S3 state bucket
aws/deploy.sh                     runs on the app host: pull, start, health check, rollback
aws/aws-setup.md                  explanation of the AWS setup
aws/architecture-diagram.png      architecture diagram
monitoring/                       Prometheus, alert rules, Grafana, compose file for the monitoring host
.env.example                      environment variables for the local run
jenkins/, docker-compose.jenkins.yml, .env.jenkins.example
                                  legacy: the earlier Docker-based Jenkins setup, no longer used by the pipeline
```

The task suggests a `Jenkinsfile` in the root, which is what I used. `k8s/`, `aws/bootstrap-state/`, `aws/iac/`, `aws/deploy.sh` and `docker-compose.prod.yml` are extra files beyond the suggested layout. The earlier version of this project (Jenkins in a Docker container, a manual trigger) is preserved under the Git tag `submission-final`.

## 1. Run locally

**Requirements:** Docker with Compose v2. Nothing else is needed, because the images build the app themselves.

```bash
cp .env.example .env
# edit .env: set DB_PASSWORD to any password you like
docker compose up --build
```

Open http://localhost:3000. The first start takes a few minutes while images build. MySQL runs in a container with a named volume, the backend creates the `todo` table on startup (`ddl-auto=update`), and the frontend container proxies `/api` to the backend.

`COHERE_API_KEY` and `SLACK_WEBHOOK_URL` default to dummy values for local runs. Creating, editing, completing and deleting to-dos works without them. The "summarize and send to Slack" feature needs real values, and **I did not use real ones: the values in my deployment are placeholders**, so I did not test that feature end to end.

### Environment variables

| Variable | Used by | Purpose |
|---|---|---|
| `DB_PASSWORD` | local compose | MySQL root password (required locally) |
| `DB_NAME` | local compose | Database name, default `todo_db` |
| `COHERE_API_KEY` | backend | Cohere API key |
| `SLACK_WEBHOOK_URL` | backend | Slack incoming webhook |
| `FRONTEND_PORT` | local compose | Host port for the UI, default 3000 |
| `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD` | backend | JDBC settings. In production the compose file builds them from the values below. |
| `BACKEND_HOST`, `BACKEND_PORT`, `DNS_RESOLVER` | frontend (nginx) | Where nginx proxies `/api` |
| `DB_HOST`, `DB_USERNAME`, `DB_PASSWORD` | production compose | RDS endpoint and credentials, filled from SSM by `deploy.sh` |
| `ECR_REGISTRY`, `IMAGE_TAG`, `METRICS_BIND_IP` | production compose | Registry, image tag, and the host's private IP for the metrics ports |

The Jenkins settings (AWS credentials, Grafana password, cluster token) are not environment variables. They are stored in the Jenkins credential store (see section 4).

### Assumptions

- MySQL 8.x is the database, matching RDS MySQL 8.4.
- The backend listens on 8080 inside its container and is not published on the host locally. The frontend is the only entry point.
- The existing CORS setting in `application.properties` is unchanged.

## 2. Changes to application code (DevOps enablement only)

No business logic was changed. The changes are:

- `Backend/.../application.properties`: database URL, username and password, the Cohere key and the Slack webhook now come from environment variables, so no real values are committed. Actuator now exposes only `health` and `prometheus`, with an `application` tag on metrics.
- `Backend/.../pom.xml`: added `spring-boot-starter-actuator` and `micrometer-registry-prometheus`, which provide the health endpoint and the Prometheus metrics endpoint.
- `Frontend/todo/src/services/todoService.js` now uses the relative URL `/api/todos` instead of `http://localhost:8080/api/todos`, so nginx forwards `/api` to the backend. `package.json` got a `"proxy": "http://localhost:8080"` entry for running `npm start` in development.

## 3. Docker design

**Backend** (`Backend/todo-summary-assistant/Dockerfile`)
- Multi-stage: `maven:3.9.9-eclipse-temurin-17` builds the jar, then only the jar is copied into `eclipse-temurin:17-jre-alpine`, which keeps the final image small.
- `pom.xml` is copied and dependencies are downloaded before the source is copied, so dependency layers are cached between builds.
- Runs as a non-root user (`app`).
- `HEALTHCHECK` calls `/actuator/health`. Compose and the deploy script use it.
- `-XX:MaxRAMPercentage=75.0` makes the JVM respect the container's memory limit.
- Installs the patched `zlib` package in the runtime stage.

**Frontend** (`Frontend/todo/Dockerfile`)
- Multi-stage: `node:20-alpine` runs `npm ci` and `npm run build`, then the static files are served by `nginxinc/nginx-unprivileged:1.30-alpine`.
- The nginx image is the unprivileged variant, so it runs as non-root and listens on 8080.
- `nginx.conf.template` proxies `/api` to `BACKEND_HOST:BACKEND_PORT` and serves `/healthz`, so the same image works locally and on EC2 without a rebuild.
- `HEALTHCHECK` calls `/healthz`.

Both services have a `.dockerignore`. All configuration comes from environment variables, and no secrets are baked into images. In the pipeline the images are built by Kaniko inside a cluster pod. The cluster nodes are `linux/amd64`, the same architecture as the AWS hosts, so no cross-platform flag is needed.

## 4. CI/CD pipeline (`Jenkinsfile`)

### How it is wired

- **Controller.** Jenkins runs as a native service on **my own machine** (port 8081). It reads the `Jenkinsfile` from GitHub (job type: Pipeline script from SCM).
- **Agents.** The Jenkins Kubernetes plugin creates one **short-lived pod per stage** on a kubeadm cluster, in the namespace `todo-ci`, and deletes it when the stage ends. Each pod has a `jnlp` agent container (JDK 21) that connects back to Jenkins over WebSocket, plus the tool containers that stage needs.
- **Least privilege.** Jenkins uses a service account (`jenkins-ci`) whose Role only allows pod operations inside `todo-ci`. A ResourceQuota caps pods and memory there (`k8s/todo-ci.yaml`).
- **Passing files between pods.** Pods share nothing, so the source code, the Terraform outputs and the SSH key move between stages with `stash` and `unstash`. Build-wide values such as the image tag are Jenkins environment variables.
- **Terraform state.** It lives in an encrypted, versioned S3 bucket with S3 native locking (`use_lockfile`), not in a pod. The bucket is created once by `aws/bootstrap-state/`.
- **Trigger.** A push to `main` sends a GitHub webhook to Jenkins through a Cloudflare tunnel, and the build starts by itself. There is no manual approval gate anywhere.
- **Time.** A full run took about 47 minutes (RDS creation and the first image builds are the longest parts). A destroy took about 7 minutes.

The pipeline has two actions: `deploy` (the default) and `destroy`.

### Stages and why each one is there

**1. Prepare**
Pod with an Alpine tools container. Clones the repository, takes the first 8 characters of the commit hash as the image tag (so any running container can be traced to an exact commit), stashes the source, confirms the AWS credentials work, finds the public IP the pod reaches the internet from (used later to restrict SSH and Grafana to that address), and checks whether an environment already exists in the S3 state. The result is only written to the log; nothing in the pipeline acts on it.

**2. Backend tests**
Pod with three containers: the agent, Maven (`maven:3.9.9-eclipse-temurin-17`) and a MySQL 8.4 sidecar. Containers in a pod share a network, so the tests reach the database on `127.0.0.1:3306`. A loop waits until port 3306 is open before Maven starts. The Cohere key and Slack URL are dummy values because the tests never call those services. The only test in the project is a Spring context test, which starts the whole app and connects to MySQL. It is a smoke test, not full coverage. There are no frontend tests, so none run. Tests run first, so a broken commit fails before anything is created in AWS.

**3. Create AWS environment** (`deploy` only)
Terraform pod (`hashicorp/terraform:1.10`). Runs `terraform init` with the S3 backend settings passed as flags, then `terraform apply -auto-approve`. This creates everything: the VPC and subnets, security groups, IAM role, ECR repositories, the RDS database, the SSM secrets, an SSH key pair and both EC2 hosts (45 resources). The outputs (addresses, registry) and the generated SSH key are stashed for the later stages.

**4. Wait for hosts**
Each host installs Docker, Compose and the AWS CLI on first boot. This stage waits (up to 5 minutes per host) until the boot script has finished, so the deploy does not start on a half-ready server.

**5. Build and push images**
Pod with Kaniko and an AWS CLI helper container. The helper fetches a short-lived ECR login token into a shared volume. Kaniko then builds the backend and frontend images from their Dockerfiles and pushes them tagged with the commit hash. No Docker daemon or privileged container is needed. Before building, it checks whether that tag already exists, and tags are immutable in ECR, so an image that was already pushed for the same commit is skipped instead of failing.

**6. Deploy app**
Copies `docker-compose.prod.yml` and `aws/deploy.sh` to the app host over SSH and runs `deploy.sh <tag>`. That script logs in to ECR, reads the database details and API keys from SSM Parameter Store using the host's instance role, pulls the new images and starts them with Docker Compose. It then waits up to 200 seconds for both containers to be healthy and for `/api/todos` to answer through nginx. If that works, it records the tag. If it does not, it prints the last backend log lines, starts the previous tag again and exits with an error, so the build ends red.

**7. Verify app**
Checks from a pod, through port 80 like a real user: `/healthz` (retried a few times), `/api/todos`, and that the tag recorded on the host equals the tag that was just built.

**8. Start monitoring**
Generates the Prometheus target files from the `.example` files with the app host's private IP, copies the `monitoring/` folder to the second host, and starts Prometheus, Grafana, node-exporter and cAdvisor with Docker Compose. The Grafana password is sent through standard input so it never appears in a command line or log. The stage then waits until all 6 Prometheus targets report up, fails if they do not, and prints the app and Grafana addresses.

**Destroy AWS environment** (`destroy` only)
Terraform pod. Runs `terraform destroy` against the same S3 state, which deletes everything the pipeline created. It is manual on purpose, so nothing deletes the infrastructure by accident.

**Failing fast and safety settings**
Every shell step uses `set -e`, so a failing command stops its stage and later stages never run. Only one build runs at a time, a build is cancelled after 90 minutes, and Jenkins keeps the last 10 builds.

### Secrets

No secrets are in the repository. The database password is generated by Terraform and goes straight into SSM. The Cohere key and Slack URL in SSM are placeholders. The credentials Jenkins needs are in the **Jenkins credential store**, and `withCredentials` exposes them only inside the step that needs them, masked in the log:

| Credential ID | Kind | Used for |
|---|---|---|
| `aws-creds` | Username with password (access key ID / secret key) | Terraform, S3 state, ECR, tag checks |
| `grafana-admin-password` | Secret text | The Grafana admin password |
| `todo-ci-token` | Secret text | Jenkins signing in to the Kubernetes API |

### Trigger

The job is started by a **GitHub webhook**. Jenkins runs on my own machine, so GitHub cannot reach it directly. A Cloudflare quick tunnel (`cloudflared tunnel --url http://localhost:8081`) gives Jenkins a public HTTPS address, and the webhook points at `<tunnel address>/github-webhook/`. A quick-tunnel address changes whenever the tunnel restarts, so the webhook URL must be updated after a restart. There is no first-run guard: a push to an empty AWS account creates the whole environment, and costs money. Disable the Jenkins job between demos.

## 5. AWS deployment

Everything on AWS is created by the Terraform in `aws/iac/`. Details are in `aws/aws-setup.md` and `aws/architecture-diagram.png`. In short:

- `todo-app` (EC2 t3.small) runs the app containers, `todo-ops` (EC2 t3.medium) runs Prometheus and Grafana, and `todo-db` is an RDS MySQL 8.4 instance in private subnets.
- Only port 80 of the app is open to the internet. SSH and Grafana accept only the operator IP found by the Prepare stage (the address the pipeline pod reaches the internet from). RDS accepts connections only from the app security group and is not publicly accessible.
- The app host has an IAM role instead of access keys, limited to pulling from the two ECR repositories and reading `/todo/*` in SSM. The monitoring host has no role.
- The database password is generated by Terraform and stored in SSM Parameter Store.
- Terraform state is in an S3 bucket (versioned, encrypted, public access blocked), created once by `aws/bootstrap-state/`.

## 6. Run the whole thing yourself

My AWS environment is deleted, so there is no live app to open. Everything can be rebuilt from this repository in your own AWS account.

**What you need:** a machine for Jenkins (Linux, Java 21), a Kubernetes cluster (I used kubeadm 1.30) that Jenkins can reach on port 6443 and whose pods can reach Jenkins, Terraform 1.10 or newer on your machine for the one-time bucket step, and an AWS account with an IAM user that can create EC2, VPC, RDS, ECR, IAM roles, SSM parameters and S3 buckets (I used an administrator user and did not work out a smaller set of permissions). A run takes about 50 minutes and costs roughly ₹10 to ₹15 per hour while the environment exists, so check your own pricing.

1. **Create the state bucket (once).**
   ```bash
   cd aws/bootstrap-state
   terraform init && terraform apply
   ```
   Put the `bucket_name` output into `TF_STATE_BUCKET` in the `Jenkinsfile`.
2. **Prepare the cluster.**
   ```bash
   kubectl apply -f k8s/todo-ci.yaml
   kubectl -n todo-ci get secret jenkins-ci-token -o jsonpath='{.data.token}' | base64 -d
   kubectl -n todo-ci get secret jenkins-ci-token -o jsonpath='{.data.ca\.crt}' | base64 -d
   ```
3. **Configure Jenkins.** Install the Kubernetes plugin. Add the three credentials from the table above. Under Manage Jenkins, Clouds, add a Kubernetes cloud named `k8s-todo-ci` with the API server URL, the CA certificate, namespace `todo-ci`, the `todo-ci-token` credential, the Jenkins URL that pods can reach (for example `http://<jenkins-host-ip>:8081`), and WebSocket ticked.
4. **Create the job.** A Pipeline job with Definition Pipeline script from SCM, your repository URL, branch `*/main`, script path `Jenkinsfile`, and the trigger GitHub hook trigger for GITScm polling.
5. **Add the webhook.** In GitHub, Settings, Webhooks, add the public address of Jenkins plus `/github-webhook/` (content type `application/json`, push events).
6. **Run it.** Push a commit to `main`, or click Build Now. The last stage prints the app and Grafana addresses.
7. **Clean up.** Click **Build with Parameters**, set **ACTION** to `destroy`, and run it.

**Opening Grafana.** Grafana is reachable only from your own public IP, which the pipeline detects. Dashboards open read-only without a login. For admin access, log in as `admin` with your Grafana password. To let someone on another network see the dashboard, run **Build with Parameters** and enter their address in `GRAFANA_VIEWER_CIDRS` (for example `203.0.113.7/32`, several separated by commas). Opening Grafana to the whole internet is refused on purpose.

**Things to know before you run it**
- Jenkins reads the pipeline from GitHub, not from your local folder. If you change files, push them to your own fork.
- The agent container must use the same Java version as the controller or newer (the pipeline uses the JDK 21 agent image).
- Jenkins does not know the build parameters until the job has run once, so Build with Parameters appears after the first run.
- Port 80 of the app is open to the internet while it runs. SSH and Grafana are limited to the operator IP found by the Prepare stage (the address the pipeline pod reaches the internet from).
- Always run `destroy` when you are done. Left running, the environment costs a few hundred rupees a day (a few US dollars).
- Do not delete the S3 state bucket while AWS resources exist. It holds the Terraform state and the generated SSH key. Without it Terraform forgets what it created and the resources keep costing money.

## 7. Monitoring

Prometheus and Grafana run as containers on the second host (`todo-ops`). The pipeline's "Start monitoring" stage copies `monitoring/` there and generates the scrape targets from the `monitoring/targets/*.json.example` files with the app host's private IP. The datasource and dashboard are provisioned from `monitoring/grafana/`. `monitoring/grafana-dashboard.json` is a copy of the dashboard for review. Prometheus scrapes 6 targets: itself, the backend (`/actuator/prometheus`), and node-exporter and cAdvisor on both hosts.

Four alert rules are in `monitoring/alert-rules.yml`: service down, high 5xx rate, high CPU and low disk. Details are in `MONITORING_AND_OPERATIONS.md`.

## 8. Failure and rollback

Written up in `FAILURE_AND_ROLLBACK.md`. In short: `deploy.sh` rolls back to the previous image tag when the new one does not become healthy, Docker restarts crashed containers, the AWS side can be rebuilt with Terraform, and the database has 3-day automated backups.

## 9. What I tested, and what I did not

| What | Where | Result |
|---|---|---|
| A full pipeline run, all stages in Kubernetes pods | Terraform-built environment | Passed in about 47 minutes: tests, images pushed, app deployed and verified, all 6 Prometheus targets up |
| The trigger | Pipeline job | A push to `main` started the build by itself through the webhook ("Started by GitHub push") |
| `ACTION = destroy` | Same environment | Passed: 44 resources destroyed in about 7 minutes, AWS left empty. The apply created 45; the one not reported as destroyed is `local_sensitive_file.ssh_key`, a local copy of the SSH key and not an AWS resource. I did not establish why Terraform did not list it |
| A deliberately broken deploy (backend moved to the wrong port) | First environment, built by hand, with the same `deploy.sh` | Health check failed, rollback to the previous tag, build ended red. The whole site was down for about 5 min 45 s. |
| `kill -9` on the backend | First environment | Docker restarted it in the same second, no alert fired (the outage was shorter than the alert's 2 minutes) |
| Stopping the app to test the alert | First environment, same alert rules | Pending 26 s after the app stopped, firing after 2 min 26 s, and it cleared once the app was started again |
| Dashboards | Terraform-built environment | Every panel showed data |

**Not tested:** a second push while the environment already exists (an update of a running deployment through the new pipeline), a pipeline that fails halfway and is re-run, replacing an instance with Terraform, rotating the secrets, restoring RDS from a backup, and running the pipeline on another AWS account or cluster. The rollback, crash and alert tests were done on the first environment, which used the same `deploy.sh`, compose files and monitoring configuration as the current pipeline, but they were not repeated on the Terraform-built one.

## Known limitations

- **Grafana has no notification channel.** Alerts fire and are visible, but nobody is notified.
- **The Cohere key and Slack webhook are placeholders**, so the summary feature was not tested with real services.
- **The webhook trigger depends on a quick tunnel.** Its address changes on restart, the webhook has no shared secret, and the tunnel exposes the Jenkins address publicly, so Jenkins login must stay enabled. A named tunnel and a webhook secret would fix this.
- **No first-run guard.** A push to an empty AWS account builds and bills for everything. Disable the job between demos.
- **No approval step before `terraform apply`**, by design for this task.
- **HTTP only.** There is no TLS, no domain and no load balancer. The EC2 hosts have changing public IPs.
- **RDS is single-AZ** with 3-day backups, no deletion protection and no final snapshot on destroy, to keep cost low.
- **AWS credentials are long-lived keys** in the Jenkins credential store. The SSH private key also lives in the Terraform state and in Jenkins' stash. A production setup would use short-lived credentials and no SSH.
- **No build cache.** Every run downloads dependencies again, so the image build stage takes about 19 minutes.
- **The cluster nodes are small.** Memory is tight, so pod resource limits are set carefully.
- **The existing React dependencies report 106 vulnerabilities** (4 critical) in `npm ci`. I did not change the application's dependencies.
- I did not check the root access key of my AWS account or set a budget alert there.

## Cleaning up

Run the pipeline with `ACTION = destroy` when you are finished, and confirm in the AWS console that no instances, RDS databases or volumes remain. The S3 state bucket costs almost nothing and can be deleted last.
