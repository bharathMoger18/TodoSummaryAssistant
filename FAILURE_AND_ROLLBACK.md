# Failure and Rollback

This document answers the six scenarios from the assessment. Where I tested something, I say so and give the numbers. Where I did not, I say that too, and mark the commands as untested.

## Setup in short

- **App host** (`todo-app`, t3.small): nginx frontend on port 80, Spring Boot backend, node-exporter and cAdvisor, run with `docker-compose.prod.yml`.
- **Ops host** (`todo-ops`, t3.medium): Prometheus, Grafana, node-exporter and cAdvisor.
- **Database:** RDS MySQL 8.4 (`db.t3.micro`), single-AZ, private, 3-day automated backups.
- **Images:** every build is tagged with the 8-character commit hash and pushed to ECR. Tags are immutable, so an old tag always points at the same image, and ECR keeps the 10 most recent images.
- **Deploy:** Jenkins runs as a native service on the operator's own machine. Each pipeline stage runs as a short-lived pod on a kubeadm cluster. The pipeline creates the AWS environment with Terraform, builds the images with Kaniko, and then runs `aws/deploy.sh <tag>` on the app host over SSH.
- **Where the important state lives:**
  - The Terraform state and the generated SSH key are in an S3 bucket (versioned, encrypted, locked), created once by `aws/bootstrap-state/`. They are not on the Jenkins machine and not in the repository.
  - The AWS keys, the Grafana password and the cluster token are in the Jenkins credential store.
  - The pipeline definition is in Git (`Jenkinsfile`, `k8s/todo-ci.yaml`). The Jenkins job and cluster settings are only in Jenkins.

## What was tested, and where

The full pipeline run (all stages in Kubernetes pods) and `ACTION = destroy` were tested on the Terraform-built environment. The rollback, crash and alert tests below were done on my first environment, which I built by hand and which used the same `deploy.sh`, compose files and monitoring configuration as the current pipeline. They were not repeated on the Terraform-built environment. Everything marked "untested" was not run at all, including every recovery step that involves Jenkins, the cluster or Terraform on an environment that already exists.

## 1. A faulty version is deployed. How do I roll back?

**Automatic rollback (tested).** `deploy.sh` waits up to 200 seconds (40 checks, 5 s apart) for both containers to report healthy and for `/api/todos` to answer through nginx. If that fails, it starts the previous tag again (it keeps the last good tag in `~/todo/.current_tag`) and checks health again. The build still ends red, so nobody mistakes it for a good deploy.

**What I tested.** I committed a deliberately broken change (the backend moved to port 9090, so the health check could not pass) and let the pipeline deploy it. The log showed `Health check FAILED`, then `Rolling back to <previous tag>`, then `Rollback OK`. The final verification stage was skipped and the build ended red. I then reverted the commit and the revert deployed normally.

**Measured downtime in that test: about 5 min 45 s.** The backend was recreated at 10:07:24 IST and the frontend came back at 10:13:10 IST. The whole site was down, not only the API, because the frontend waits for a healthy backend. My curl logger stopped while it was still returning errors, so the 5m45s comes from the Jenkins and Docker timestamps, not from the logger.

**Known improvement (not done).** The script waits the full 200 s even if Compose has already reported the backend unhealthy, so the rollback could start about 3 minutes earlier.

**Manual rollback to any earlier version** (untested on the current setup, but it runs the same script):
1. Find the previous tag in the Jenkins console output (`Deploying tag X (previous: Y)`).
2. Get the app host's address and the SSH key from the Terraform state in S3. From a machine with Terraform and AWS credentials:
   ```bash
   cd aws/iac
   terraform init -input=false   # backend flags: see "Running Terraform by hand" at the end of this file
   terraform output -raw app_public_ip
   ```
   The SSH private key is also in that state. Save it to a file and run `chmod 600` on it.
3. Run the deploy script with the old tag: `ssh -i todo-key.pem ubuntu@<app-ip> '~/todo/deploy.sh <old-tag>'`. SSH only works from the public IP that the last pipeline run detected.
4. Or revert the commit in Git and push, so the pipeline deploys the old code again. This is the simplest route, but it runs the whole pipeline, and a second run on an environment that already exists is one of the things I did not test.

## 2. The application crashes after deployment. What happens?

Containers use `restart: unless-stopped`, so Docker restarts a crashed container automatically.

**Tested.** I ran `kill -9` on the backend process. Docker restarted it within the same second. No alert fired, because the outage was shorter than the 2-minute `for:` on `ServiceDown`. The restart is still visible on the Grafana container-restarts panel.

If the app crashes repeatedly, it keeps restarting and `ServiceDown` fires after 2 minutes of failed scrapes. There is no automatic rollback after a deploy has already succeeded, so that case needs a manual rollback as in section 1.

## 3. The CI/CD tool is unavailable. Can I still deploy?

Yes, because the deploy logic lives in `aws/deploy.sh` on the app host, not in Jenkins, and the Terraform state is in S3, not in Jenkins. What I do depends on which part is down. None of these recoveries was tested.

- **Jenkins service stopped or crashed:** restart the service. Its settings, credentials and job survive a restart.
- **Kubernetes cluster down:** Jenkins itself works, but no stage can start, because every stage needs a pod. Fix or rebuild the cluster (`k8s/todo-ci.yaml` recreates the namespace, service account and quota), then update the `todo-ci-token` credential if the token changed.
- **Cloudflare tunnel down:** GitHub's webhook cannot reach Jenkins, so pushes stop starting builds. Builds still work with Build Now. After a tunnel restart, update the webhook URL.
- **Jenkins unusable but the state is available:** deploy by hand with the commands in section 1. The image has to exist in ECR already. If it does not, build and push it from a laptop with AWS credentials first.
- **The Jenkins machine is lost:** this is much less severe than before, because the Terraform state and the SSH key are in S3, so Terraform still knows what it created. What is lost is the Jenkins configuration: the job, the Kubernetes cloud settings, the three credentials and the build history. I rebuild it from section 6 of the README, and the pipeline itself comes back from Git. Because the AWS keys were on that machine, I also deactivate them in IAM and create new ones. I have not backed up the Jenkins configuration.
- **The weak point is now the S3 bucket.** If it is deleted, Terraform forgets what it created and I cannot SSH into either host (the key pair has only that key). The app keeps running, but I could not deploy to it or manage it with Terraform. The resources can be found by their `Project = todo-summary-assistant` tag and deleted by hand. Versioning protects against an overwritten state file, not against deleting the bucket or the account.

## 4. Secrets are leaked. What steps do I take?

Rotate first, investigate after. The leaked secret is useless once it is replaced.

- **Database password:** it is generated by Terraform and stored in SSM. Replacing the generated password with `terraform apply -replace=random_password.db` (with the same backend and variable flags as the pipeline) should change it on RDS and in SSM, and then the pipeline's deploy stage has to run again so the app host reads the new value. *(Untested.)*
- **Cohere key and Slack webhook:** revoke them at the provider, then set the new values with `aws ssm put-parameter --overwrite --name /todo/cohere-api-key --type SecureString --value ...`, and redeploy. Terraform ignores later changes to these two parameters.
- **AWS access keys (Jenkins credential `aws-creds`):** deactivate them in IAM, create new ones, and update the credential in Jenkins. The keys are long-lived and are never written to the repository or to a file. *(Untested.)*
- **Grafana password (`grafana-admin-password`):** update the credential in Jenkins and run the pipeline again, because the monitoring stage sends it to the ops host. Whether that changes an existing Grafana admin password is untested.
- **Cluster token (`todo-ci-token`):** delete and recreate the `jenkins-ci-token` Secret on the cluster, then update the credential in Jenkins. *(Untested.)*
- **The SSH key:** it is in the Terraform state and is passed between stages with `stash`. Replacing it replaces the key pair, which forces both EC2 instances to be recreated. *(Untested.)*
- **The Terraform state itself holds secrets** (the database password and the SSH private key). Anyone who can read the S3 bucket has them, so bucket access must be limited. The bucket is encrypted and blocks public access.
- **Then:** check CloudTrail for use of the leaked AWS keys, check the RDS and nginx logs for unexpected access, and remove the secret from the code and from Git history if it was ever committed.

**Honest status.** No secrets are committed to the repository (I checked the whole history). The Cohere key and Slack webhook are placeholders. The AWS keys are in the Jenkins credential store and are masked in build logs, but they belong to an administrator user. The webhook has no shared secret, and the Cloudflare tunnel makes Jenkins reachable from the internet, so Jenkins login must stay enabled.

## 5. The EC2 instance fails. How do I recover?

Everything that matters is rebuilt from outside the instance: images are in ECR, secrets are in SSM, the data is in RDS, and the infrastructure is in Terraform with its state in S3.

- **App host terminated or gone:** run the pipeline. Terraform compares the state with AWS, sees the instance is missing and should create a new one, after which the pipeline deploys to it. *(Untested: I have not run the pipeline against an existing environment.)* The public IP changes, because there is no Elastic IP. The database is untouched.
- **App host running but broken:** force a replacement with Terraform, then run the pipeline. *(Untested.)*
  ```bash
  cd aws/iac
  # first run the init and tfvars commands from "Running Terraform by hand" at the end of this file
  terraform apply -replace=aws_instance.app -var-file=/tmp/pipeline.tfvars.json
  ```
- **Ops host:** the same with `aws_instance.ops`, then run the pipeline again so the monitoring stage starts the containers. The Prometheus metric history on that host is lost.
- **The whole environment:** run the pipeline with `ACTION = destroy` and then `deploy`. That took about 7 minutes plus about 47 minutes in my tests. The destroy deletes the database too, with no final snapshot, so this is only acceptable for a test environment.

There is no Auto Scaling or load balancer, so the app is down until a replacement is running. Terraform makes the rebuild repeatable, not instant.

## 6. The RDS database becomes unavailable. What is the impact and the recovery plan?

**Impact.** The database is single-AZ with no standby. While it is down, the backend cannot read or write, and its health check fails. A deploy during that time would fail and roll back to the previous tag, which would also be unhealthy. Nothing is lost if the instance simply restarts.

**Recovery options:**
1. **Instance problem:** reboot it from the console or the CLI, or wait for AWS to recover it.
2. **Data loss or corruption:** restore from an automated backup or a point in time. Retention is **3 days**, so I can restore to any moment in that window. A restore creates a **new** instance with a new endpoint. I then put the new address into `/todo/db-host` in SSM and redeploy. The restored instance needs the same private security group (3306 from the app security group only). *(Untested.)*
3. **Terraform afterwards, and a trap in this pipeline:** a restored instance is not tracked by Terraform, and every pipeline run applies Terraform, which also manages the `/todo/db-host` parameter. A normal run could therefore create a new empty database or point the app back at the old address. After a restore I import the new instance into the state first, or deploy by hand with `deploy.sh` and leave the pipeline alone. *(Untested.)*
4. **Before risky changes:** take a manual snapshot.

**Not in place, stated plainly:**
- Multi-AZ is off, to stay inside a small budget. In production I would turn it on, so AWS fails over automatically in about a minute or two.
- Deletion protection is off, and `terraform destroy` takes no final snapshot, because this is a test environment.
- 3 days of backups is short for production.
- I have not run a restore drill.

## Running Terraform by hand

The pipeline passes its backend settings and a generated variables file to Terraform. Neither exists outside the pipeline pod, so to run Terraform from another machine with AWS credentials, recreate them first. *(Untested on an existing environment.)*

```bash
cd aws/iac
terraform init -input=false \
  -backend-config="bucket=todo-tfstate-9bd1a0e4" \
  -backend-config="key=todo/terraform.tfstate" \
  -backend-config="region=ap-south-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
jq -n --arg op "$(curl -fsS https://checkip.amazonaws.com)/32" \
  '{operator_cidr: $op, ssh_key_path: "/tmp/todo-key.pem", grafana_viewer_cidrs: []}' \
  > /tmp/pipeline.tfvars.json
```

`ssh_key_path` is only where Terraform writes the generated private key, so any writable path works. `operator_cidr` becomes the public IP of the machine you run this from, so SSH and Grafana access moves to that machine until the pipeline runs again. After this, `terraform apply` and `terraform destroy` take `-var-file=/tmp/pipeline.tfvars.json`, as in the pipeline.
