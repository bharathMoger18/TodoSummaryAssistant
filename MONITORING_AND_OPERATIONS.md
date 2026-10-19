# Monitoring and Operations

## What runs where

- **`todo-ops` host (t3.medium):** Prometheus, Grafana, and a node-exporter and cAdvisor for its own metrics. Nothing else runs there.
- **`todo-app` host (t3.small):** the app containers plus their own node-exporter and cAdvisor.
- **Jenkins** is not on AWS. It runs in a container on the operator's own machine, so its build logs are there too.
- **Scraping:** Prometheus scrapes every 15 s. It has 6 targets: itself, the backend at `/actuator/prometheus` (Spring Boot Actuator + Micrometer), and node-exporter and cAdvisor on both hosts.
- **Targets are generated, not committed.** The pipeline's "Start monitoring" stage fills `monitoring/targets/*.json.example` with the app host's private IP and copies the folder to the ops host. It then waits until all 6 targets report up, and fails the build if they do not.
- **Access:** Prometheus listens on localhost only. Grafana (port 3000) accepts only the operator's IP, plus any viewer IPs given to the pipeline. The metrics ports on the app host (8080, 9100, 8081) accept connections only from the ops security group, and are also published on the host's private IP only.
- **Grafana login:** dashboards open read-only without a login, because the pipeline turns on anonymous Viewer access (the address allow-list is what protects it). Admin access needs the password from `.env.jenkins`.

## Which metrics I monitor and why

| Metric | Source | Why |
|---|---|---|
| Request rate, 5xx error rate, latency | Micrometer `http_server_requests_seconds_*` | Shows what users actually experience. Rising errors or latency usually appear before a full outage. |
| `up` per scrape target | Prometheus | The cheapest "is it alive" signal for the app, the exporters and Prometheus itself. |
| CPU, memory, disk | node-exporter | Small instances. A full disk or exhausted CPU or memory will take the app down. |
| Container restarts and uptime | cAdvisor | A crash-looping container can look healthy between restarts. Restarts show it. |

The Grafana dashboard (`monitoring/grafana-dashboard.json`, provisioned from `monitoring/grafana/dashboards/todo-overview.json`) has panels for request rate, error rate, latency, CPU, memory, disk, container restarts and uptime. The error-rate panel shows 0% when there are no 5xx responses instead of "no data".

## Which logs are critical

- **Backend container log:** stack traces, database connection errors, failed startups. This is where I look first after a failed deploy. `deploy.sh` also prints the last 40 backend lines when a health check fails.
- **nginx (frontend) container log:** 502 and 504 errors mean nginx cannot reach the backend.
- **Jenkins build log** (on the operator's machine): shows which stage failed, what Terraform changed and whether a rollback ran.
- **First-boot log on each host** (`/var/log/cloud-init-output.log`): shows why a host did not finish installing Docker.
- **RDS logs:** connection and authentication errors in the RDS console.
- **Retention:** Docker keeps container logs on each host with rotation (10 MB x 3 files per container). Logs are **not** centralized, so they are lost when a host is replaced. A real setup would ship them to CloudWatch Logs or Loki.

## Alerts

Alerts are Prometheus rules in `monitoring/alert-rules.yml`:

| Alert | Condition | Severity | Why this threshold |
|---|---|---|---|
| ServiceDown | `up == 0` for 2 min | critical | Two minutes ignores a normal container restart but catches a real outage. |
| HighErrorRate | more than 5% of requests are 5xx for 5 min (`/actuator/*` excluded) | critical | Health and metrics scrapes should not skew the user-facing error rate. |
| HighCPU | CPU above 85% for 10 min | warning | Only sustained load matters on a burstable instance. |
| LowDisk | less than 15% free on `/` for 10 min | warning | Gives time to act before the disk fills. |

**Tested (on the first environment, with the same rules).** I stopped the app: the alert was pending 26 seconds later and firing after 2 min 26 s, and it cleared once the app was started again. I also killed the backend process with `kill -9`: Docker restarted it in the same second and no alert fired, which is the intended behavior.

**Deliberately not alerting (to avoid noise):**
- A single container restart. It shows on the restarts panel, but a page for every self-healing restart would train people to ignore alerts.
- Short CPU spikes (under 10 minutes) and 4xx responses (client mistakes, not service failures).
- Actuator and health-check traffic, which is excluded from the error-rate calculation.
- JVM and cAdvisor details. They are on the dashboard for investigation but are not paging signals.

## How issues are detected early

1. The `for:` durations separate real problems from blips, and the dashboard shows the blips anyway.
2. Every pipeline run checks the app after deploying: `/healthz`, `/api/todos` and the running image tag. A bad version rolls back automatically (see `FAILURE_AND_ROLLBACK.md`).
3. The monitoring stage fails the build if any Prometheus target is not up, so a broken scrape setup is caught at deploy time.
4. Container health checks (backend `/actuator/health`, frontend `/healthz`) mark a container unhealthy before users report it.
5. Restart counts on the dashboard reveal crash loops that never trigger `ServiceDown`.

## Limitations I know about

- **Grafana has no notification channel** (no email, Slack or PagerDuty). Alerts fire and are visible, but nobody is notified. This is the biggest gap. I would add a contact point and a notification policy first.
- **No external uptime check.** If `todo-ops` goes down, nothing monitors the app, and nothing alerts that monitoring is gone. A probe from outside AWS would fix that.
- **No RDS metrics** (CPU, connections, free storage). I would scrape CloudWatch or add an exporter.
- **No memory alert.** Memory is on the dashboard only.
- **No alert on the alert pipeline itself.** If Prometheus stops evaluating rules, nothing says so.
- **Idle periods.** With no traffic, the error-rate expression has nothing to divide, so it cannot fire. `ServiceDown` covers real outages.
- **Anonymous read-only viewing** is safe only because of the IP allow-list. Grafana runs over plain HTTP.
- **The Slack summary feature uses a placeholder webhook and the Cohere key is a placeholder**, so those integrations are not monitored or exercised.
