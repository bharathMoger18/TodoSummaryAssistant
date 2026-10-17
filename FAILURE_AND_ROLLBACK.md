# Failure and Rollback

This document answers the six scenarios from the assessment. Where I tested something, I say so and give the numbers. Where I did not, I say that too.

## Setup in short

- **App host** (`todo-app`, t3.small): nginx frontend on port 80, Spring Boot backend, node-exporter and cAdvisor. Run with `docker-compose.prod.yml`.
- **Ops host** (`todo-ops`, t3.medium): Prometheus and Grafana.
- **Database:** RDS MySQL 8.4 (`db.t3.micro`), single-AZ, private, 3-day automated backups.
- **Images:** every build is tagged with the 8-character commit SHA and pushed to ECR. Tags are immutable, so an old tag always points at the same image.
- **Deploy:** Jenkins runs `aws/deploy.sh <tag>` on the app host over SSH. The script records the running tag in `~/todo/.current_tag`.

## 1. A faulty version is deployed. How do I roll back?

**Automatic rollback (tested).** `deploy.sh` waits up to 200 seconds (40 checks, 5 s apart) for both containers to report healthy and for `/api/todos` to answer through nginx. If that fails, it restarts the stack on the previous tag from `.current_tag` and checks health again. The build still ends red so nobody mistakes it for a good deploy.

**What I tested.** I committed a deliberately broken change (backend moved to port 9090, so the health check could not pass) and pushed it. The Jenkins log showed `Health check FAILED`, then `Rolling back to 7287296e`, then `Rollback OK`. The Verify stage was skipped and the build ended red. Production ended up on the last good version. I then reverted the commit on `main` and the revert deployed normally (`previous: 7287296e`, `Deploy OK: 72df7392`).

**Measured downtime in that test: about 5 min 45 s.** The backend was recreated at 10:07:24 IST and the frontend came back at 10:13:10 IST. The whole site was down, not only the API, because the frontend waits for a healthy backend. My curl logger stopped at 04:42:32 UTC while it was still returning 000, so it did not capture the recovery. The 5m45s comes from the Jenkins and Docker timestamps.

**Known improvement (not done).** The script waits the full 200 s even if Compose has already reported the backend unhealthy, so rollback could start about 3 minutes earlier. I did not change it before submission.

**Manual rollback to any earlier version:**
1. `ssh ubuntu@<app-host>`, then `cd ~/todo && ./deploy.sh <old-tag>`. Old tags stay in ECR.
2. Or `git revert <bad-commit>` and push, and the pipeline deploys the reverted code.

## 2. The application crashes after deployment. What happens?

Containers use `restart: unless-stopped`, so Docker restarts a crashed container automatically.

**Tested.** I ran `kill -9` on the backend process. Docker restarted it within the same second. No alert fired, because the outage was shorter than the 2-minute `for:` on `ServiceDown`. The restart is still visible on the Grafana container-restarts panel.

If the app crashes repeatedly, it keeps restarting and `ServiceDown` fires after 2 minutes of failed scrapes. There is no automatic rollback after a deploy has already succeeded. That is a manual rollback as in section 1.

## 3. The CI/CD tool is unavailable. Can I still deploy?

Yes, with one manual step. The deploy logic lives in `aws/deploy.sh` on the app host, not in Jenkins. Anyone with the SSH key can run `./deploy.sh <tag>` on the host, and it pulls from ECR using the instance role. The catch is that the image has to exist in ECR already. If Jenkins is down before a build, I would build and push from a laptop with AWS credentials, then run `deploy.sh`.

Jenkins runs on the `todo-ops` EC2 instance, next to Prometheus and Grafana, and reaches the app host over SSH (the app security group allows port 22 from the ops security group). My own laptop is also allowed on port 22 (restricted to my IP), so I can run `deploy.sh` by hand even when Jenkins is down. The trade-off is that Jenkins shares a host with monitoring and has no standby.

## 4. Secrets are leaked. What steps do I take?

1. **Rotate first, investigate after.** The leaked secret is dead the moment it is replaced.
   - **DB password:** change it on RDS (`modify-db-instance --master-user-password`), update `/todo/db-password` in SSM Parameter Store, then redeploy so the backend picks it up.
   - **Cohere key:** revoke it in the Cohere dashboard, create a new one, update `/todo/cohere-api-key`.
   - **Slack webhook:** delete and recreate it in Slack, update `/todo/slack-webhook-url`.
   - **AWS keys or the SSH key:** deactivate or replace them, and update the Jenkins credential.
2. **Check for use.** Look at CloudTrail for the AWS keys, and RDS and nginx logs for unexpected access.
3. **Clean the repo.** Remove the secret from the code, and from git history if it was committed (rewrite history or recreate the repo). Rotating is what matters, because anyone may already have copied it.
4. **Write down what happened** and how it got in.

**Honest status.** Secrets are in SSM Parameter Store and read by the instance role at deploy time, and no secrets are committed to the repo. The Cohere and Slack values are currently placeholders, not real credentials. I have not yet checked and deactivated any root access key, and I have not set up the monthly budget alert. Those are still open.

## 5. The EC2 instance fails. How do I recover?

- **App host:** launch a new instance with the same security group and the `todo-app-profile` instance role, install Docker, copy `docker-compose.prod.yml` and `aws/deploy.sh`, and run `./deploy.sh <tag>`. Nothing important lives only on the instance: images are in ECR, secrets are in SSM, and data is in RDS. Then update the Jenkins `APP_HOST` value to the new IP.
- **Ops host:** launch a new instance with the `todo-ops-profile` role and start the monitoring stack from `monitoring/docker-compose.yml`. Dashboards and the Prometheus datasource are provisioned from files in the repo. Prometheus metric history on that host would be lost. The scrape targets (`monitoring/targets/*.json`) are not committed, so I recreate them from the `.example` files with the app host's private IP. **Jenkins is also on this host.** The `Jenkinsfile` is in the repo, but the Jenkins install, its credentials (`app-ssh`, `github-read`) and the `APP_HOST` setting are not, so I would have to rebuild those by hand. Until then I deploy manually with `deploy.sh` from my laptop (see section 3).

**Honest gap.** I do not have a fully scripted bootstrap (installing Docker and so on). `aws/setup.sh` only contains the monitoring security-group rules, so rebuilding a host is partly manual. Recovery time is roughly the time to launch an instance and install Docker, plus one deploy (about 10 minutes in my tests). There is no Auto Scaling or load balancer, so there is downtime until I do this.

## 6. The RDS database becomes unavailable. What is the impact and the recovery plan?

**Impact.** The database is single-AZ with no standby. While it is down, the backend cannot read or write. The health check fails, so a deploy during that time would fail and roll back to the previous tag (which would also be unhealthy). Nothing is lost if the instance simply restarts.

**Recovery options:**
1. **Instance problem:** reboot it, or wait for AWS to recover it.
2. **Data loss or corruption:** restore from an automated backup or point-in-time restore. Retention is **3 days**, so I can restore to any moment in that window. A restore creates a **new** instance with a new endpoint. I then update `/todo/db-host` in SSM and redeploy. The restored instance needs the same private security group (3306 from the app security group only).
3. **Before risky changes:** take a manual snapshot.

**Not in place, stated plainly:**
- **Multi-AZ is off**, to stay inside the free-tier budget. In production I would turn it on so AWS fails over automatically in about a minute or two.
- **Deletion protection is off.** I would turn it on for a real system.
- Backup retention of 3 days is short for production.
- I have not run a restore drill.
