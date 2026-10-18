# Todo Summary Assistant: DevOps Assessment

A to-do application (Spring Boot backend, React frontend, MySQL) that can summarize pending tasks with Cohere and post the summary to Slack. This repository is the original project plus my DevOps work: Docker, a Jenkins CI/CD pipeline, deployment to AWS EC2 with RDS, and Prometheus/Grafana monitoring.

The application features are unchanged. Everything below is about building, running, deploying and operating it.

## Documents

| File | What it covers |
|---|---|
| `aws/aws-setup.md`, `aws/architecture-diagram.png` | AWS layout, security groups, IAM, secrets |
| `FAILURE_AND_ROLLBACK.md` | The six failure scenarios, with what I tested |
| `MONITORING_AND_OPERATIONS.md` | Metrics, logs, alerts, early detection |
| `Jenkinsfile` | The pipeline |
| `monitoring/` | `prometheus.yml`, `alert-rules.yml`, Grafana dashboard and provisioning |

## Repository layout

```
Backend/todo-summary-assistant/   Spring Boot + Maven app, Dockerfile, .dockerignore
Frontend/todo/                    React app, Dockerfile, .dockerignore, nginx.conf.template
Jenkinsfile                       CI/CD pipeline
docker-compose.yml                local run: MySQL + backend + frontend
docker-compose.prod.yml           production stack on EC2 (no MySQL, RDS is used)
aws/                              deploy.sh, setup.sh, aws-setup.md, architecture diagram
monitoring/                       Prometheus, alert rules, Grafana, compose file for the ops host
.env.example                      environment variables
```

I used a `Jenkinsfile` in the repo root instead of `.github/workflows/ci-cd.yml`. `docker-compose.prod.yml`, `monitoring/docker-compose.yml` and `aws/deploy.sh` are extra files beyond the suggested layout.

## 1. Run locally

**Requirements:** Docker with Compose v2. Nothing else is needed, because the images build the app themselves.

```bash
cp .env.example .env
# edit .env: set DB_PASSWORD to any password you like
docker compose up --build
```

Open http://localhost:3000. The first start takes a few minutes while images build. MySQL runs in a container with a named volume, the backend creates the `todo` table on startup (`ddl-auto=update`), and the frontend container proxies `/api` to the backend.

`COHERE_API_KEY` and `SLACK_WEBHOOK_URL` default to dummy values for local runs. Creating, editing, completing and deleting to-dos works without them. The "summarize and send to Slack" feature needs real values, and **I did not use real ones: the keys in my deployment are placeholders**, so I did not test that feature end to end.

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

### Assumptions

- MySQL 8.x is the database, matching RDS MySQL 8.4.
- The backend listens on 8080 inside its container and is not published on the host locally. The frontend is the only entry point.
- The existing CORS setting in `application.properties` is unchanged.

## 2. Changes to application code (DevOps enablement only)

No business logic was changed. The changes are:

- `Backend/.../application.properties`: database URL, username and password, the Cohere key and the Slack webhook now come from environment variables, so no real values are committed. Actuator now exposes only `health` and `prometheus`, with an `application` tag on metrics.
- `Backend/.../pom.xml`: added `spring-boot-starter-actuator` and `micrometer-registry-prometheus`, which provide the health endpoint and the Prometheus metrics endpoint.
- `Frontend/todo/src/services/todoService.js` and `Frontend/todo/package.json`: `todoService.js` now uses the relative URL `/api/todos` instead of `http://localhost:8080/api/todos`, so nginx forwards `/api` to the backend. `package.json` got a `"proxy": "http://localhost:8080"` entry for running `npm start` in development.

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

Both services have a `.dockerignore`. All configuration comes from environment variables, and no secrets are baked into images.

## 4. CI/CD pipeline (`Jenkinsfile`)

Jenkins runs on the `todo-ops` EC2 instance as a multibranch pipeline. Every commit gets built and tested, but only commits on `main` are pushed and deployed. Other branches stop after the image build, so I can try things without touching the running app.

Here is what each stage does and why it is there.

**1. Prepare**
The image tag is the first 8 characters of the commit hash, so any running container can be traced back to an exact commit. The stage stops the build right away if `APP_HOST` is not set in Jenkins, which is better than finding out halfway through a deploy. It also asks AWS which account it is running in and builds the ECR address from that, so no account number is written in the repo.

**2. Backend tests**
Jenkins starts a throwaway MySQL 8.4 container on its own Docker network, with a random password made for that run only, and waits up to about two minutes for it to accept connections. Then it runs `mvn test` in a Maven container against that database. The Cohere key and Slack URL are dummy values here because the tests never call those services. A cleanup step removes the container and network even if the tests fail. The only test the project has is a Spring context test, which starts the whole app and connects to MySQL. It is a smoke test, not full coverage. There are no frontend tests, so none run.

**3. Build images**
Builds the backend and frontend images from their Dockerfiles, both tagged with the commit hash. `--pull` makes sure the base images are fresh instead of whatever was cached. The backend build skips tests because the previous stage already ran them. If either build fails, nothing gets pushed.

**4. Push to ECR** (`main` only)
Logs in to ECR with a short-lived token from the instance role. The Docker login config goes in a temporary folder that is deleted afterwards, so the token does not stay on disk. Before pushing, the stage checks whether that tag already exists in ECR. Tags are immutable, so if the commit was built before it skips the push instead of failing.

**5. Deploy to EC2** (`main` only)
Jenkins connects to the app host over SSH using a key stored in Jenkins credentials. It copies `docker-compose.prod.yml` and `aws/deploy.sh` to the host every time, so the server always runs the versions in the repo, then runs `deploy.sh <tag>`. That script logs in to ECR, reads the database details and API keys from SSM Parameter Store, pulls the new images and starts them with Docker Compose. It then waits up to 200 seconds for both containers to be healthy and for `/api/todos` to answer through nginx. If that works, it records the tag in `.current_tag`. If it does not, it prints the last backend log lines, starts the previous tag again and exits with an error, so the build ends red.

**6. Verify deployment** (`main` only)
This check runs from Jenkins, not from the app host, and goes through port 80 like a real user. It calls `/healthz` (retrying a few times), calls `/api/todos`, then reads `.current_tag` from the host and compares it with the tag that was just built. If the host is running a different version, the build fails.

**After the build (always)**
Removes the images from the Jenkins machine and prunes unused ones, so the disk does not fill up over many builds.

**Failing fast and safety settings**
The shell steps use `set -e` and `pipefail`, so any failing command stops its stage and the later stages never run. Only one build can run at a time, so two deploys cannot overlap. A build is cancelled after 45 minutes, and Jenkins keeps the last 10 builds.

**Secrets**
No secrets are in the Jenkinsfile or the repo. The SSH key is a Jenkins credential, AWS access comes from the instance role, and the database password and API keys come from SSM when the deploy runs.

**Trigger:** Jenkins checks the repository every minute and builds new commits automatically. It polls because its port is open only to my IP, so GitHub webhooks cannot reach it.

**Jenkins setup needed to reproduce:** Jenkins with Docker, the AWS CLI, Git and Java on a host that has an ECR push role; credentials `app-ssh` (SSH key for the app host) and `github-read`; and a global environment variable `APP_HOST` with the app host's address.

## 5. AWS deployment

See `aws/aws-setup.md` and `aws/architecture-diagram.png`. Short version: `todo-app` (EC2 t3.small) runs the app containers, `todo-ops` (EC2 t3.medium) runs Jenkins, Prometheus and Grafana, and `todo-db` is an RDS MySQL instance that accepts connections only from the app security group. Instance roles are used instead of access keys, and database credentials and API keys are in SSM Parameter Store under `/todo/*`.

## 6. Monitoring

Prometheus and Grafana run in containers on `todo-ops`. To start them, copy each `monitoring/targets/*.json.example` file to a file without `.example` and fill in the app host's private IP, then run `docker compose -f monitoring/docker-compose.yml up -d`. The datasource and dashboard are provisioned from `monitoring/grafana/`. `monitoring/grafana-dashboard.json` is a copy of the dashboard for review.

Four alert rules are in `monitoring/alert-rules.yml`: service down, high 5xx rate, high CPU and low disk. Details are in `MONITORING_AND_OPERATIONS.md`.

## 7. Failure and rollback

Written up in `FAILURE_AND_ROLLBACK.md`. I tested the automatic rollback by deploying a deliberately broken version: the health check failed, the previous version was restored, and the build ended red. The whole site was down for about 5 minutes 45 seconds during that test.

## 8. Run the whole pipeline yourself on AWS (optional)

My AWS environment was deleted after I submitted, so you can't open my live app. Instead, everything can be rebuilt from this repository with one Jenkins job. It runs on your own computer and creates everything in your own AWS account. Nothing of mine is involved.

This lives on the `iac-pipeline` branch, so clone that branch:

```bash
git clone -b iac-pipeline https://github.com/bharathMoger18/TodoSummaryAssistant.git
cd TodoSummaryAssistant
```

### What you need

- Docker with Compose v2, and Git.
- An AWS account and an IAM user that can create EC2, VPC, RDS, ECR, IAM roles and SSM parameters. I ran it with an administrator user and did not work out a smaller set of permissions.
- About 25 minutes, and a small AWS bill (roughly 10 to 15 US cents per hour while it runs, so check your own pricing).

### Steps

1. Create the settings file and set two passwords of your choice (letters and digits only):
   ```bash
   cp .env.jenkins.example .env.jenkins
   nano .env.jenkins
   ```
   `JENKINS_ADMIN_PASSWORD` is your Jenkins login. `GRAFANA_ADMIN_PASSWORD` is the Grafana admin login.
2. Add your AWS credentials to the same file. If you have an AWS CLI profile:
   ```bash
   aws configure export-credentials --profile <your-profile> --format env-no-export >> .env.jenkins
   ```
   Otherwise add `AWS_ACCESS_KEY_ID=...` and `AWS_SECRET_ACCESS_KEY=...` lines by hand (and `AWS_SESSION_TOKEN=...` if yours are temporary). `.env.jenkins` is git-ignored, so it is never committed.
3. Start Jenkins:
   ```bash
   docker compose -f docker-compose.jenkins.yml up -d --build
   ```
   The first build takes a few minutes. Then open http://localhost:8080 and log in as `admin`.
4. Click the job **todo-iac**, then **Build Now**, and open the build's **Console Output**. It takes about 20 to 25 minutes.
5. The last stage prints the address of the app and the address of Grafana.
6. When you are finished, click **Build with Parameters**, set **ACTION** to `destroy`, and run it. This deletes everything the pipeline created.

### What the pipeline does

| Stage | What happens |
|---|---|
| Prepare | Checks your AWS login, finds your public IP and builds the Terraform settings |
| Create AWS environment | `terraform apply` creates the VPC, security groups, two EC2 hosts, RDS, ECR, the IAM role and the SSM secrets (45 resources, see `aws/iac/`) |
| Wait for hosts | Waits until both servers have finished installing Docker |
| Backend tests | Runs the Maven tests against a temporary MySQL container |
| Build images | Builds the backend and frontend images for linux/amd64 |
| Push to ECR | Pushes both images tagged with the commit hash |
| Deploy app | Copies `docker-compose.prod.yml` and `aws/deploy.sh` to the app host and runs the deploy, with its health check and automatic rollback |
| Verify app | Calls `/healthz` and `/api/todos` through port 80 and checks that the running tag matches |
| Start monitoring | Starts Prometheus, Grafana, node-exporter and cAdvisor on the second host and waits until every target reports up |
| Summary | Prints the addresses |

`Jenkinsfile.iac` is the pipeline. The original `Jenkinsfile` is the one I used on the first AWS environment, where Jenkins ran on an EC2 host.

### Opening Grafana

Grafana is only reachable from your own public IP, which the pipeline detects automatically. Dashboards open read-only without a login. For admin access, log in as `admin` with your `GRAFANA_ADMIN_PASSWORD`. To let someone else on another network see the dashboard, run **Build with Parameters** and enter their address in `GRAFANA_VIEWER_CIDRS` (for example `203.0.113.7/32`, several separated by commas). Opening Grafana to the whole internet is refused on purpose.

### Things to know before you run it

- **Jenkins reads the pipeline from GitHub, not from your local folder.** If you change files, push them to your own fork and set `REPO_URL` and `REPO_BRANCH` in `.env.jenkins`.
- **Jenkins controls your Docker through its socket**, which gives it root-level access to your machine's Docker. Run it on a machine you are comfortable with.
- **Port 80 of the app is open to the internet while it runs.** SSH and Grafana are limited to your IP.
- **Always run `destroy` when you are done.** Left running, the environment costs a few dollars a day.
- **Do not run `docker compose ... down -v`** or delete the `todo-jenkins_jenkins_home` volume while AWS resources exist. That volume holds the Terraform state, and without it Terraform forgets what it created and the resources keep costing money.
- The Terraform state and the generated SSH key stay inside that Jenkins volume. They are not in the repository.
- The Cohere key and Slack webhook are placeholders in SSM, so the summarize feature is not exercised.
- Everything is plain HTTP. There is no TLS and no load balancer.
- I have run this end to end on my own account. I have not tried it on any other account or operating system.

## Known limitations

- **Grafana has no notification channel.** Alerts fire but nobody is notified.
- **Cohere key and Slack webhook are placeholders**, so the summary feature was not tested with real services.
- **HTTP only.** There is no TLS on the app, Grafana or Jenkins.
- **RDS is single-AZ** with 3-day backups and no deletion protection, to keep cost low.
- **The infrastructure was created by hand** (console and CLI). `aws/setup.sh` only contains the monitoring security-group rules, and there is no Terraform.
- **Not done:** root access key check and deactivation, and a monthly budget alert.
- **The existing React dependencies report 106 vulnerabilities** (4 critical) in `npm ci`. I did not change the application's dependencies.
- Jenkins logs `Could not update commit status` (403) because my GitHub token cannot write commit statuses. The builds are not affected.
- The deploy script waits its full 200 seconds before rolling back, even if Compose has already marked the backend unhealthy. Rollback could start about 3 minutes earlier.

## Cleaning up

When the review is finished, stop or delete both EC2 instances and the RDS instance to avoid charges.

## Status

The AWS resources (EC2, RDS, ECR, IAM, SSM) were deleted after submission to avoid charges. The deployment is described in `aws/aws-setup.md` and can be recreated on request. The application still runs locally with `docker compose up --build`.
