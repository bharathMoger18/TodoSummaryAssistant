// Pipeline for running the whole project from one machine:
//   deploy  -> Terraform creates the AWS environment, then the app and monitoring are deployed
//   destroy -> Terraform deletes everything it created
// AWS credentials, the Grafana password and the Jenkins settings come from .env.jenkins,
// which Docker passes into this Jenkins container as environment variables.

def shouldDeploy() {
    return (params.ACTION ?: 'deploy') == 'deploy' && env.SKIP_DEPLOY != 'true'
}

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    triggers { pollSCM('H/2 * * * *') }

    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'destroy'],
               description: 'deploy: create everything on AWS. destroy: delete everything.')
        string(name: 'GRAFANA_VIEWER_CIDRS', defaultValue: '',
               description: 'Optional extra IPs allowed to open Grafana, comma separated, each like 203.0.113.4/32')
    }

    environment {
        AWS_REGION         = 'ap-south-1'
        AWS_DEFAULT_REGION = 'ap-south-1'
        TF_IN_AUTOMATION   = '1'
        // Terraform state and the generated SSH key live in Jenkins' own volume, outside the repo
        STATE_DIR          = '/var/jenkins_home/todo-iac'
        // The AWS hosts are brand new every time, so their host keys are not checked
        SSH_OPTS           = '-i /var/jenkins_home/todo-iac/todo-key.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR'
    }

    stages {
        stage('Prepare') {
            steps {
                script {
                    // On the very first run Jenkins does not know the parameters yet, so use defaults
                    env.ACTION = params.ACTION ?: 'deploy'
                    env.GRAFANA_VIEWER_CIDRS = params.GRAFANA_VIEWER_CIDRS ?: ''
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim()
                    env.OPERATOR_CIDR = sh(script: 'curl -fsS https://checkip.amazonaws.com', returnStdout: true).trim() + '/32'
                    def pushed = currentBuild.getBuildCauses('hudson.triggers.SCMTrigger$SCMTriggerCause')
                    def exists = fileExists("${env.STATE_DIR}/outputs.json")
                    env.SKIP_DEPLOY = (pushed && !exists) ? 'true' : 'false'
                    if (env.SKIP_DEPLOY == 'true') {
                        echo 'Push detected, but no AWS environment exists. Run Build Now once to create it. Nothing deployed.'
                    }
                }
                sh '''#!/bin/bash
                    set -euo pipefail
                    echo "Action: $ACTION, image tag: $IMAGE_TAG, your address: $OPERATOR_CIDR"
                    aws sts get-caller-identity --query Arn --output text
                    terraform version | sed -n 1p
                    if [ "$ACTION" = "deploy" ] && [ "${SKIP_DEPLOY:-false}" != "true" ] && [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
                        echo "GRAFANA_ADMIN_PASSWORD is not set in .env.jenkins" >&2
                        exit 1
                    fi
                    mkdir -p "$STATE_DIR"
                    jq -n --arg op "$OPERATOR_CIDR" --arg key "$STATE_DIR/todo-key.pem" --arg v "${GRAFANA_VIEWER_CIDRS:-}" \
                        '{operator_cidr: $op, ssh_key_path: $key, grafana_viewer_cidrs: ($v | gsub(" "; "") | split(",") | map(select(length > 0)))}' \
                        > "$STATE_DIR/pipeline.tfvars.json"
                '''
            }
        }

        stage('Backend tests') {
            when { expression { shouldDeploy() } }
            steps {
                // The source is copied into the test container with "docker cp" instead of a bind mount,
                // because this Jenkins runs inside a container and bind-mount paths would point at the host.
                sh '''#!/bin/bash
                    set -euo pipefail
                    NET="ci-${BUILD_NUMBER}"
                    DB="ci-mysql-${BUILD_NUMBER}"
                    MVN="ci-mvn-${BUILD_NUMBER}"
                    CI_DB_PASS="$(openssl rand -hex 12)"
                    cleanup() {
                        docker rm -f "$DB" "$MVN" > /dev/null 2>&1 || true
                        docker network rm "$NET" > /dev/null 2>&1 || true
                    }
                    trap cleanup EXIT

                    docker network create "$NET"
                    docker run -d --name "$DB" --network "$NET" \
                        -e MYSQL_ROOT_PASSWORD="$CI_DB_PASS" -e MYSQL_DATABASE=todo_db mysql:8.4

                    for i in $(seq 1 40); do
                        if docker exec "$DB" mysqladmin ping -h 127.0.0.1 --silent; then break; fi
                        sleep 3
                    done
                    docker exec "$DB" mysqladmin ping -h 127.0.0.1 --silent

                    docker create --name "$MVN" --network "$NET" -w /app -v todo-m2-cache:/root/.m2 \
                        -e SPRING_DATASOURCE_URL="jdbc:mysql://$DB:3306/todo_db" \
                        -e SPRING_DATASOURCE_USERNAME=root \
                        -e SPRING_DATASOURCE_PASSWORD="$CI_DB_PASS" \
                        -e COHERE_API_KEY=ci-dummy -e SLACK_WEBHOOK_URL=http://localhost/ci-dummy \
                        maven:3.9.9-eclipse-temurin-17 mvn -B -q test
                    docker cp Backend/todo-summary-assistant/. "$MVN":/app
                    docker start -a "$MVN"
                '''
            }
        }

        stage('Create AWS environment') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    cd aws/iac
                    terraform init -input=false -backend-config="path=$STATE_DIR/terraform.tfstate"
                    terraform apply -input=false -auto-approve -var-file="$STATE_DIR/pipeline.tfvars.json"
                    terraform output -json > "$STATE_DIR/outputs.json"
                '''
            }
        }

        stage('Wait for hosts') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    for ip in $(jq -r '.app_public_ip.value, .ops_public_ip.value' "$STATE_DIR/outputs.json"); do
                        ready=no
                        for i in $(seq 1 30); do
                            if ssh $SSH_OPTS ubuntu@"$ip" 'cloud-init status --wait' > /dev/null 2>&1; then ready=yes; break; fi
                            sleep 10
                        done
                        [ "$ready" = "yes" ] || { echo "Host $ip did not finish booting" >&2; exit 1; }
                        echo "Host $ip is ready"
                    done
                '''
            }
        }

        stage('Build images') {
            when { expression { shouldDeploy() } }
            steps {
                // --platform makes the images run on the AWS hosts even if this machine is ARM (Apple Silicon)
                sh '''#!/bin/bash
                    set -euo pipefail
                    REG="$(jq -r .ecr_registry.value "$STATE_DIR/outputs.json")"
                    docker build --pull --platform linux/amd64 -t "$REG/todo-backend:$IMAGE_TAG" Backend/todo-summary-assistant
                    docker build --pull --platform linux/amd64 -t "$REG/todo-frontend:$IMAGE_TAG" Frontend/todo
                '''
            }
        }

        stage('Push to ECR') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    REG="$(jq -r .ecr_registry.value "$STATE_DIR/outputs.json")"
                    export DOCKER_CONFIG="$(mktemp -d)"
                    trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                    aws ecr get-login-password | docker login --username AWS --password-stdin "$REG"
                    for repo in todo-backend todo-frontend; do
                        if aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$IMAGE_TAG" > /dev/null 2>&1; then
                            echo "$repo:$IMAGE_TAG is already in ECR (tags are immutable), skipping push"
                        else
                            docker push "$REG/$repo:$IMAGE_TAG"
                        fi
                    done
                '''
            }
        }

        stage('Deploy app') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    APP_IP="$(jq -r .app_public_ip.value "$STATE_DIR/outputs.json")"
                    scp $SSH_OPTS docker-compose.prod.yml aws/deploy.sh ubuntu@"$APP_IP":~/todo/
                    ssh $SSH_OPTS ubuntu@"$APP_IP" "chmod +x ~/todo/deploy.sh && ~/todo/deploy.sh $IMAGE_TAG"
                '''
            }
        }

        stage('Verify app') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    APP_IP="$(jq -r .app_public_ip.value "$STATE_DIR/outputs.json")"
                    curl -fsS --retry 5 --retry-delay 5 --retry-connrefused "http://$APP_IP/healthz"
                    curl -fsS "http://$APP_IP/api/todos" > /dev/null
                    RUNNING="$(ssh $SSH_OPTS ubuntu@"$APP_IP" 'cat ~/todo/.current_tag')"
                    echo "running tag: $RUNNING, expected: $IMAGE_TAG"
                    [ "$RUNNING" = "$IMAGE_TAG" ]
                '''
            }
        }

        stage('Start monitoring') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    APP_PRIVATE="$(jq -r .app_private_ip.value "$STATE_DIR/outputs.json")"
                    OPS_IP="$(jq -r .ops_public_ip.value "$STATE_DIR/outputs.json")"

                    # Prometheus targets are generated from the .example files with the app host's private address
                    WORK="$(mktemp -d)"
                    trap 'rm -rf "$WORK"' EXIT
                    cp -r monitoring/. "$WORK"/
                    for f in "$WORK"/targets/*.json.example; do
                        sed "s/APP_PRIVATE_IP/$APP_PRIVATE/g" "$f" > "${f%.example}"
                    done

                    ssh $SSH_OPTS ubuntu@"$OPS_IP" 'mkdir -p ~/monitoring'
                    scp -r $SSH_OPTS "$WORK"/. ubuntu@"$OPS_IP":~/monitoring/
                    # The Grafana password goes in through stdin so it never appears in a command line or log
                    printf 'GRAFANA_ADMIN_PASSWORD=%s\\nGRAFANA_ANONYMOUS_VIEWER=true\\n' "$GRAFANA_ADMIN_PASSWORD" \
                        | ssh $SSH_OPTS ubuntu@"$OPS_IP" 'umask 077; cat > ~/monitoring/.env'
                    ssh $SSH_OPTS ubuntu@"$OPS_IP" 'cd ~/monitoring && docker compose up -d'

                    # Wait until every Prometheus target reports "up"
                    for i in $(seq 1 24); do
                        TARGETS="$(ssh $SSH_OPTS ubuntu@"$OPS_IP" 'curl -fsS localhost:9090/api/v1/targets' || echo '{}')"
                        TOTAL="$(echo "$TARGETS" | jq '[.data.activeTargets[]?] | length')"
                        BAD="$(echo "$TARGETS" | jq '[.data.activeTargets[]? | select(.health != "up")] | length')"
                        echo "Prometheus targets: $TOTAL total, $BAD not up"
                        if [ "$TOTAL" -ge 6 ] && [ "$BAD" -eq 0 ]; then exit 0; fi
                        sleep 10
                    done
                    echo "$TARGETS" | jq '.data.activeTargets[]? | {job: .labels.job, host: .labels.host, health, lastError}' >&2
                    exit 1
                '''
            }
        }

        stage('Summary') {
            when { expression { shouldDeploy() } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    APP_IP="$(jq -r .app_public_ip.value "$STATE_DIR/outputs.json")"
                    OPS_IP="$(jq -r .ops_public_ip.value "$STATE_DIR/outputs.json")"
                    echo "================================================================"
                    echo "App:      http://$APP_IP"
                    echo "Grafana:  http://$OPS_IP:3000   (open to $OPERATOR_CIDR and any viewer IPs you listed)"
                    echo "          Read-only dashboards need no login. Admin login: admin / GRAFANA_ADMIN_PASSWORD from .env.jenkins"
                    echo "Delete everything afterwards: Build with Parameters, ACTION = destroy"
                    echo "================================================================"
                '''
            }
        }

        stage('Destroy AWS environment') {
            when { expression { params.ACTION == 'destroy' } }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    cd aws/iac
                    terraform init -input=false -backend-config="path=$STATE_DIR/terraform.tfstate"
                    terraform destroy -input=false -auto-approve -var-file="$STATE_DIR/pipeline.tfvars.json"
                    rm -f "$STATE_DIR/outputs.json"
                '''
            }
        }
    }

    post {
        always {
            sh '''
                docker image prune -f > /dev/null 2>&1 || true
            '''
        }
        success { echo "Pipeline finished (${env.ACTION})." }
        failure { echo "Pipeline FAILED. If AWS resources were created, run it again with ACTION=destroy so nothing keeps costing money." }
    }
}
