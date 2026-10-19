# Failure and Rollback

This document answers the six scenarios from the assessment. Where I tested something, I say so and give the numbers. Where I did not, I say that too, and mark the commands as untested.

## Setup in short

- **App host** (`todo-app`, t3.small): nginx frontend on port 80, Spring Boot backend, node-exporter and cAdvisor, run with `docker-compose.prod.yml`.
- **Ops host** (`todo-ops`, t3.medium): Prometheus, Grafana, node-exporter and cAdvisor.
- **Database:** RDS MySQL 8.4 (`db.t3.micro`), single-AZ, private, 3-day automated backups.
- **Images:** every build is tagged with the 8-character commit hash and pushed to ECR. Tags are immutable, so an old tag always points at the same image, and ECR keeps the 10 most recent images.
- **Deploy:** the Jenkins pipeline runs on the operator's own machine, in a container. It creates the AWS environment with Terraform and then runs `aws/deploy.sh <tag>` on the app host over SSH.
- **Where the important state lives:** the Terraform state and the generated SSH key are in the Jenkins container's Docker volume (`todo-jenkins_jenkins_home`), not on AWS and not in the repository.

## What was tested, and where

The rollback, crash and alert tests below were done on my first environment, which I built by hand and which used the same `deploy.sh`, compose files and monitoring configuration as the current pipeline. They were not repeated on the Terraform-built environment. The commands marked "untested" were not run at all.

## 1. A faulty version is deployed. How do I roll back?

**Automatic rollback (tested).** `deploy.sh` waits up to 200 seconds (40 checks, 5 s apart) for both containers to report healthy and for `/api/todos` to answer through nginx. If that fails, it starts the previous tag again (it keeps the last good tag in `~/todo/.current_tag`) and checks health again. The build still ends red, so nobody mistakes it for a good deploy.

**What I tested.** I committed a deliberately broken change (the backend moved to port 9090, so the health check could not pass) and let the pipeline deploy it. The log showed `Health check FAILED`, then `Rolling back to <previous tag>`, then `Rollback OK`. The final verification stage was skipped and the build ended red. I then reverted the commit and the revert deployed normally.

**Measured downtime in that test: about 5 min 45 s.** The backend was recreated at 10:07:24 IST and the frontend came back at 10:13:10 IST. The whole site was down, not only the API, because the frontend waits for a healthy backend. My curl logger stopped while it was still returning errors, so the 5m45s comes from the Jenkins and Docker timestamps, not from the logger.

**Known improvement (not done).** The script waits the full 200 s even if Compose has already reported the backend unhealthy, so the rollback could start about 3 minutes earlier.

**Manual rollback to any earlier version** (untested on the current setup, but it is the same script):
1. Find the previous tag in the Jenkins console output (`Deploying tag X (previous: Y)`).
2. Copy the SSH key out of the Jenkins volume and find the app host's address:
   ```bash
   docker cp todo-jenkins-jenkins-1:/var/jenkins_home/todo-iac/todo-key.pem ./todo-key.pem && chmod 600 todo-key.pem
   docker compose -f docker-compose.jenkins.yml exec jenkins jq -r .app_public_ip.value /var/jenkins_home/todo-iac/outputs.json
   ```
3. Run the deploy script with the old tag: `ssh -i todo-key.pem ubuntu@<app-ip> '~/todo/deploy.sh <old-tag>'`. SSH only works from the IP that ran the pipeline.
4. Or revert the commit in Git and run the pipeline again.

## 2. The application crashes after deployment. What happens?

Containers use `restart: unless-stopped`, so Docker restarts a crashed container automatically.

**Tested.** I ran `kill -9` on the backend process. Docker restarted it within the same second. No alert fired, because the outage was shorter than the 2-minute `for:` on `ServiceDown`. The restart is still visible on the Grafana container-restarts panel.

If the app crashes repeatedly, it keeps restarting and `ServiceDown` fires after 2 minutes of failed scrapes. There is no automatic rollback after a deploy has already succeeded, so that case needs a manual rollback as in section 1.

## 3. The CI/CD tool is unavailable. Can I still deploy?

Yes. Jenkins is a container on the operator's machine, not a server, and the deploy logic lives in `aws/deploy.sh` on the app host, not in Jenkins.

- **Jenkins container stopped or crashed:** start it again with `docker compose -f docker-compose.jenkins.yml up -d`. The Terraform state and SSH key are in the volume and survive a restart.
- **Jenkins unusable but the key is still available:** deploy by hand with the commands in section 1. The image has to exist in ECR already. If it does not, build and push from a laptop with AWS credentials first.
- **The machine or the Docker volume is lost:** this is the real weak point. Without the state file, Terraform no longer knows what it created, and without the private key I cannot SSH into either host (the key pair has only that key). The app keeps running, but I cannot deploy to it or manage it with Terraform. The resources can be found by their `Project = todo-summary-assistant` tag and deleted by hand. The mitigation is to back up the Jenkins volume, which I have not set up.

## 4. Secrets are leaked. What steps do I take?

Rotate first, investigate after. The leaked secret is useless once it is replaced.

- **Database password:** it is generated by Terraform and stored in SSM. Replacing the generated password with `terraform apply -replace=random_password.db` should change it on RDS and in SSM, and then the pipeline's deploy stage has to run again so the app host reads the new value. *(Untested.)*
- **Cohere key and Slack webhook:** revoke them at the provider, then set the new values with `aws ssm put-parameter --overwrite --name /todo/cohere-api-key --type SecureString --value ...`, and redeploy. Terraform ignores later changes to these two parameters.
- **AWS access keys in `.env.jenkins`:** deactivate them in IAM, create new ones, update the file and restart the Jenkins container.
- **The SSH key:** replacing it replaces the key pair, which forces both EC2 instances to be recreated. *(Untested.)*
- **Then:** check CloudTrail for use of the leaked AWS keys, check the RDS and nginx logs for unexpected access, and remove the secret from the code and from Git history if it was ever committed.

**Honest status.** No secrets are committed to the repository (I checked the whole history). The Cohere key and Slack webhook are placeholders. `.env.jenkins` holds the operator's AWS keys in plain text on their own machine and is git-ignored.

## 5. The EC2 instance fails. How do I recover?

Everything that matters is rebuilt from outside the instance: images are in ECR, secrets are in SSM, the data is in RDS, and the infrastructure is in Terraform.

- **App host:** replace it with Terraform, then run the pipeline to deploy to the new instance. *(Untested.)*
  ```bash
  docker compose -f docker-compose.jenkins.yml exec jenkins bash -c 'cd /var/jenkins_home/workspace/todo-iac/aws/iac && terraform init -input=false -backend-config="path=/var/jenkins_home/todo-iac/terraform.tfstate" && terraform apply -replace=aws_instance.app -var-file=/var/jenkins_home/todo-iac/pipeline.tfvars.json'
  ```
  The public IP changes, because there is no Elastic IP. The database is untouched.
- **Ops host:** the same command with `aws_instance.ops`, then run the pipeline again so the monitoring stage starts the containers. The Prometheus metric history on that host is lost.
- **The whole environment:** run the pipeline with `ACTION = destroy` and then `deploy` (about 25 minutes). The destroy deletes the database too, with no final snapshot, so this is only acceptable for a test environment.

There is no Auto Scaling or load balancer, so the app is down until a replacement is running. Terraform makes the rebuild repeatable, not instant.

## 6. The RDS database becomes unavailable. What is the impact and the recovery plan?

**Impact.** The database is single-AZ with no standby. While it is down, the backend cannot read or write, and its health check fails. A deploy during that time would fail and roll back to the previous tag, which would also be unhealthy. Nothing is lost if the instance simply restarts.

**Recovery options:**
1. **Instance problem:** reboot it from the console or the CLI, or wait for AWS to recover it.
2. **Data loss or corruption:** restore from an automated backup or a point in time. Retention is **3 days**, so I can restore to any moment in that window. A restore creates a **new** instance with a new endpoint. I then put the new address into `/todo/db-host` in SSM and redeploy. The restored instance needs the same private security group (3306 from the app security group only). *(Untested.)*
3. **Terraform afterwards:** a restored instance is not tracked by Terraform, so the state would be out of date. For a real system I would import it or rebuild from it.
4. **Before risky changes:** take a manual snapshot.

**Not in place, stated plainly:**
- Multi-AZ is off, to stay inside a small budget. In production I would turn it on, so AWS fails over automatically in about a minute or two.
- Deletion protection is off, and `terraform destroy` takes no final snapshot, because this is a test environment.
- 3 days of backups is short for production.
- I have not run a restore drill.
