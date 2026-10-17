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

Jenkins runs on the `todo-ops` EC2 instance as a multibranch pipeline. The Prepare, test and build stages run on every branch. Push, deploy and verify run only on `main`.

| Stage | What it does |
|---|---|
| Prepare | Tags the build with the 8-character commit SHA, checks `APP_HOST` is set, and reads the AWS account ID. |
| Backend tests | Starts a throwaway MySQL 8.4 container with a random password, runs `mvn test` against it, then removes it. The only test in the project is a Spring context test. There are no frontend tests, so none run. |
| Build images | Builds the backend and frontend images tagged `<ECR>/todo-backend:<sha>` and `todo-frontend:<sha>`. |
| Push to ECR | Logs in with the instance role and pushes both images. Skips a push if the tag already exists, because tags are immutable. |
| Deploy to EC2 | Copies `docker-compose.prod.yml` and `aws/deploy.sh` to the app host over SSH and runs `deploy.sh <tag>`. The script reads secrets from SSM, starts the stack, waits for health, and rolls back to the previous tag if the new one is not healthy. |
| Verify deployment | Calls `/healthz` and `/api/todos` through port 80 and checks that the running tag equals the built tag. |

Other behavior: the pipeline stops at the first failing stage, one build runs at a time, there is a 45-minute timeout, and only the last 10 builds are kept. Secrets are never in the repo. The SSH key is a Jenkins credential (`app-ssh`), and AWS access comes from the instance role.

**Trigger:** Jenkins checks the repository every minute and builds new commits automatically. It polls because its port is open only to my IP, so GitHub webhooks cannot reach it.

**Jenkins setup needed to reproduce:** Jenkins with Docker, the AWS CLI, Git and Java on a host that has an ECR push role; credentials `app-ssh` (SSH key for the app host) and `github-read`; and a global environment variable `APP_HOST` with the app host's address.

## 5. AWS deployment

See `aws/aws-setup.md` and `aws/architecture-diagram.png`. Short version: `todo-app` (EC2 t3.small) runs the app containers, `todo-ops` (EC2 t3.medium) runs Jenkins, Prometheus and Grafana, and `todo-db` is an RDS MySQL instance that accepts connections only from the app security group. Instance roles are used instead of access keys, and database credentials and API keys are in SSM Parameter Store under `/todo/*`.

## 6. Monitoring

Prometheus and Grafana run in containers on `todo-ops`. To start them, copy each `monitoring/targets/*.json.example` file to a file without `.example` and fill in the app host's private IP, then run `docker compose -f monitoring/docker-compose.yml up -d`. The datasource and dashboard are provisioned from `monitoring/grafana/`. `monitoring/grafana-dashboard.json` is a copy of the dashboard for review.

Four alert rules are in `monitoring/alert-rules.yml`: service down, high 5xx rate, high CPU and low disk. Details are in `MONITORING_AND_OPERATIONS.md`.

## 7. Failure and rollback

Written up in `FAILURE_AND_ROLLBACK.md`. I tested the automatic rollback by deploying a deliberately broken version: the health check failed, the previous version was restored, and the build ended red. The whole site was down for about 5 minutes 45 seconds during that test.

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
