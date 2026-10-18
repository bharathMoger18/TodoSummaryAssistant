# Todo Summary Assistant: DevOps Assessment

A full-stack to-do application (Spring Boot backend, React frontend, MySQL) that can summarize pending tasks with Cohere and post the summary to Slack. This repository is the original project plus my DevOps work: Docker images, a Jenkins pipeline that builds the whole AWS environment with Terraform, deploys the app to EC2 with an RDS database, and starts Prometheus and Grafana for monitoring.

The application features are unchanged. Everything below is about building, running, deploying and operating it.

## Documents

| File | What it covers |
|---|---|
| `aws/aws-setup.md`, `aws/architecture-diagram.png` | The AWS layout: networking, security groups, IAM, secrets |
| `aws/iac/` | The Terraform that creates all of it |
| `Jenkinsfile` | The pipeline |
| `FAILURE_AND_ROLLBACK.md` | The six failure scenarios, with what I tested and what I did not |
| `MONITORING_AND_OPERATIONS.md` | Metrics, logs, alerts, early detection |
| `monitoring/` | `prometheus.yml`, `alert-rules.yml`, the Grafana dashboard and provisioning |

## Repository layout

```
Backend/todo-summary-assistant/   Spring Boot + Maven app, Dockerfile, .dockerignore
Frontend/todo/                    React app, Dockerfile, .dockerignore, nginx.conf.template
Jenkinsfile                       the pipeline: create the AWS environment, deploy, monitor (or destroy)
jenkins/                          Dockerfile and configuration for the Jenkins container
docker-compose.jenkins.yml        starts Jenkins on your own machine
.env.jenkins.example              settings for Jenkins (copy to .env.jenkins, which is git-ignored)
docker-compose.yml                local run: MySQL + backend + frontend
docker-compose.prod.yml           production stack on the app host (no MySQL, RDS is used)
aws/iac/                          Terraform for the whole AWS environment
aws/deploy.sh                     runs on the app host: pull, start, health check, rollback
aws/aws-setup.md                  explanation of the AWS setup
aws/architecture-diagram.png      architecture diagram
monitoring/                       Prometheus, alert rules, Grafana, compose file for the monitoring host
.env.example                      environment variables for the local run
```

The task suggests a `Jenkinsfile` in the root, which is what I used. `jenkins/`, `docker-compose.jenkins.yml`, `aws/iac/`, `aws/deploy.sh` and `docker-compose.prod.yml` are extra files beyond the suggested layout.

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
| `JENKINS_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `REPO_URL`, `REPO_BRANCH` | Jenkins container | See `.env.jenkins.example` |

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

Both services have a `.dockerignore`. All configuration comes from environment variables, and no secrets are baked into images. The pipeline builds both images for `linux/amd64`, so they also run on the AWS hosts when the pipeline is started from an ARM machine such as an Apple Silicon Mac.

## 4. CI/CD pipeline (`Jenkinsfile`)

The pipeline runs in Jenkins inside a container on **your own machine** (`docker-compose.jenkins.yml`). It uses your machine's Docker through the mounted socket, Terraform and the AWS CLI inside the container, and your AWS credentials from `.env.jenkins`. One run takes about 20 to 25 minutes. It has two actions: `deploy` (the default) and `destroy`.

Here is what each stage does and why it is there.

**1. Prepare**
Takes the first 8 characters of the commit hash as the image tag, so any running container can be traced to an exact commit. Finds your public IP (used later to restrict SSH and Grafana to you), checks that your AWS credentials work and Terraform is installed, and stops right away if `GRAFANA_ADMIN_PASSWORD` is missing. It writes the Terraform settings to a file in the Jenkins volume.

**2. Create AWS environment** (`deploy` only)
Runs `terraform init` and `terraform apply` in `aws/iac/`. This creates everything: the VPC and subnets, security groups, IAM role, ECR repositories, the RDS database, the SSM secrets, an SSH key pair and both EC2 hosts (45 resources). The Terraform state lives in the Jenkins volume, outside the repository, and the outputs (addresses, registry) are saved for the later stages.

**3. Wait for hosts**
Each host installs Docker, Compose and the AWS CLI on first boot. This stage waits (up to 5 minutes per host) until the boot script has finished, so the deploy does not start on a half-ready server.

**4. Backend tests**
Starts a throwaway MySQL 8.4 container on its own Docker network with a random password made for that run, then runs `mvn test` in a Maven container against it. The source is copied in with `docker cp` rather than a bind mount, because this Jenkins runs in a container and bind-mount paths would point at the host. The Cohere key and Slack URL are dummy values because the tests never call those services. A cleanup step removes the containers and network even if the tests fail. The only test in the project is a Spring context test, which starts the whole app and connects to MySQL. It is a smoke test, not full coverage. There are no frontend tests, so none run.

**5. Build images**
Builds the backend and frontend images from their Dockerfiles for `linux/amd64`, tagged with the commit hash. `--pull` refreshes the base images. The backend build skips tests because the previous stage already ran them. If a build fails, nothing is pushed.

**6. Push to ECR**
Logs in to ECR with a short-lived token, using a temporary Docker config folder that is deleted afterwards. Before pushing, it checks whether that tag already exists. Tags are immutable in my ECR setup, so an image that was already pushed for the same commit is skipped instead of failing.

**7. Deploy app**
Copies `docker-compose.prod.yml` and `aws/deploy.sh` to the app host over SSH and runs `deploy.sh <tag>`. That script logs in to ECR, reads the database details and API keys from SSM Parameter Store using the host's instance role, pulls the new images and starts them with Docker Compose. It then waits up to 200 seconds for both containers to be healthy and for `/api/todos` to answer through nginx. If that works, it records the tag. If it does not, it prints the last backend log lines, starts the previous tag again and exits with an error, so the build ends red.

**8. Verify app**
Checks from Jenkins, through port 80 like a real user: `/healthz` (retried a few times), `/api/todos`, and that the tag recorded on the host equals the tag that was just built.

**9. Start monitoring**
Generates the Prometheus target files from the `.example` files with the app host's private IP, copies the `monitoring/` folder to the second host, and starts Prometheus, Grafana, node-exporter and cAdvisor with Docker Compose. The Grafana password is sent through standard input so it never appears in a command line or log. The stage then waits until all 6 Prometheus targets report up, and fails if they do not.

**10. Summary**
Prints the app and Grafana addresses.

**Destroy AWS environment** (`destroy` only)
Runs `terraform destroy`, which deletes everything the pipeline created.

**Failing fast and safety settings**
Every shell step uses `set -e` and `pipefail`, so a failing command stops its stage and later stages never run. Only one build runs at a time, a build is cancelled after 60 minutes, and Jenkins keeps the last 10 builds.

**Secrets**
No secrets are in the repository. The database password is generated by Terraform and goes straight into SSM. The Cohere key and Slack URL in SSM are placeholders. Your AWS credentials and the two passwords are in `.env.jenkins`, which is git-ignored and handed to the Jenkins container as environment variables. They are not in Jenkins' own credential store, which I note as a difference from the task's wording.

**Trigger**
A run is started by hand (Build Now, or Build with Parameters for `destroy`). I did not add a push trigger to this pipeline. Each run creates paid AWS resources, and because Jenkins runs on your own machine, GitHub cannot send it webhooks. The first, hand-built environment used a polling trigger, but that pipeline is not part of this version (see the `submission-final` tag).

## 5. AWS deployment

Everything on AWS is created by the Terraform in `aws/iac/`. Details are in `aws/aws-setup.md` and `aws/architecture-diagram.png`. In short:

- `todo-app` (EC2 t3.small) runs the app containers, `todo-ops` (EC2 t3.medium) runs Prometheus and Grafana, and `todo-db` is an RDS MySQL 8.4 instance in private subnets.
- Only port 80 of the app is open to the internet. SSH and Grafana accept only your IP. RDS accepts connections only from the app security group and is not publicly accessible.
- The app host has an IAM role instead of access keys, limited to pulling from the two ECR repositories and reading `/todo/*` in SSM. The monitoring host has no role.
- The database password is generated by Terraform and stored in SSM Parameter Store.

## 6. Run the whole thing on AWS yourself

My AWS environment is deleted, so there is no live app to open. Instead, everything can be rebuilt from this repository in your own AWS account.

```bash
git clone https://github.com/bharathMoger18/TodoSummaryAssistant.git
cd TodoSummaryAssistant
```

**What you need:** Docker with Compose v2, Git, and an AWS account with an IAM user that can create EC2, VPC, RDS, ECR, IAM roles and SSM parameters (I used an administrator user and did not work out a smaller set of permissions). It takes about 25 minutes and costs roughly ₹10 to ₹15 per hour, or 10 to 15 US cents, while it runs, so check your own pricing.

1. Create the settings file and set two passwords of your choice (letters and digits only):
   ```bash
   cp .env.jenkins.example .env.jenkins
   nano .env.jenkins
   ```
2. Add your AWS credentials to the same file. With an AWS CLI profile:
   ```bash
   aws configure export-credentials --profile <your-profile> --format env-no-export >> .env.jenkins
   ```
   Otherwise add `AWS_ACCESS_KEY_ID=...` and `AWS_SECRET_ACCESS_KEY=...` lines by hand (plus `AWS_SESSION_TOKEN=...` for temporary credentials).
3. Start Jenkins:
   ```bash
   docker compose -f docker-compose.jenkins.yml up -d --build
   ```
   Then open http://localhost:8080 and log in as `admin` with your `JENKINS_ADMIN_PASSWORD`.
4. Click the job **todo-iac**, then **Build Now**, and open the **Console Output**. Wait about 20 to 25 minutes.
5. The last stage prints the app address and the Grafana address.
6. When you are finished, click **Build with Parameters**, set **ACTION** to `destroy`, and run it.

**Opening Grafana.** Grafana is reachable only from your own public IP, which the pipeline detects. Dashboards open read-only without a login. For admin access, log in as `admin` with your `GRAFANA_ADMIN_PASSWORD`. To let someone on another network see the dashboard, run **Build with Parameters** and enter their address in `GRAFANA_VIEWER_CIDRS` (for example `203.0.113.7/32`, several separated by commas). Opening Grafana to the whole internet is refused on purpose.

**Things to know before you run it**
- Jenkins reads the pipeline from GitHub, not from your local folder. If you change files, push them to your own fork and set `REPO_URL` and `REPO_BRANCH` in `.env.jenkins`.
- Jenkins controls your Docker through its socket, which gives it root-level access to your machine's Docker. Run it on a machine you are comfortable with.
- Port 80 of the app is open to the internet while it runs. SSH and Grafana are limited to your IP.
- Always run `destroy` when you are done. Left running, the environment costs a few hundred rupees a day (a few US dollars).
- Do not run `docker compose ... down -v` or delete the `todo-jenkins_jenkins_home` volume while AWS resources exist. That volume holds the Terraform state and the generated SSH key. Without it Terraform forgets what it created and the resources keep costing money.

## 7. Monitoring

Prometheus and Grafana run as containers on the second host (`todo-ops`). The pipeline's "Start monitoring" stage copies `monitoring/` there and generates the scrape targets from the `monitoring/targets/*.json.example` files with the app host's private IP. The datasource and dashboard are provisioned from `monitoring/grafana/`. `monitoring/grafana-dashboard.json` is a copy of the dashboard for review. Prometheus scrapes 6 targets: itself, the backend (`/actuator/prometheus`), and node-exporter and cAdvisor on both hosts.

Four alert rules are in `monitoring/alert-rules.yml`: service down, high 5xx rate, high CPU and low disk. Details are in `MONITORING_AND_OPERATIONS.md`.

## 8. Failure and rollback

Written up in `FAILURE_AND_ROLLBACK.md`. In short: `deploy.sh` rolls back to the previous image tag when the new one does not become healthy, Docker restarts crashed containers, the AWS side can be rebuilt with Terraform, and the database has 3-day automated backups.

## 9. What I tested, and what I did not

| What | Where | Result |
|---|---|---|
| A full pipeline run, all stages | Terraform-built environment | Passed: tests, images pushed, app deployed and verified, all Prometheus targets up |
| A deliberately broken deploy (backend moved to the wrong port) | First environment, built by hand, with the same `deploy.sh` | Health check failed, rollback to the previous tag, build ended red. The whole site was down for about 5 min 45 s. |
| `kill -9` on the backend | First environment | Docker restarted it in the same second, no alert fired (the outage was shorter than the alert's 2 minutes) |
| Stopping the app to test the alert | First environment, same alert rules | Pending 26 s after the app stopped, firing after 2 min 26 s, and it cleared once the app was started again |
| Dashboards | First environment | Every panel showed data |

**Not tested:** running the pipeline a second time on the same commit, replacing an instance with Terraform, rotating the secrets, restoring RDS from a backup, and running the pipeline on another AWS account or operating system. The rollback, crash and alert tests were done on the first environment, which used the same `deploy.sh`, compose files and monitoring configuration as the current pipeline, but they were not repeated on the Terraform-built one.

The first version of this project (the hand-built environment, with Jenkins on an EC2 instance) is preserved under the Git tag `submission-final`.

## Known limitations

- **Grafana has no notification channel.** Alerts fire and are visible, but nobody is notified.
- **The Cohere key and Slack webhook are placeholders**, so the summary feature was not tested with real services.
- **The pipeline is started by hand**, not by a push (see section 4).
- **HTTP only.** There is no TLS, no domain and no load balancer. The EC2 hosts have changing public IPs.
- **RDS is single-AZ** with 3-day backups, no deletion protection and no final snapshot on destroy, to keep cost low.
- **AWS credentials come from `.env.jenkins`**, not from Jenkins' credential store, and the Docker socket is shared with Jenkins.
- **The existing React dependencies report 106 vulnerabilities** (4 critical) in `npm ci`. I did not change the application's dependencies.
- I did not check the root access key of my AWS account or set a budget alert there.

## Cleaning up

Run the pipeline with `ACTION = destroy` when you are finished, and confirm in the AWS console that no instances, RDS databases or volumes remain.
