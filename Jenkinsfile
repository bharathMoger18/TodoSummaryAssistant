// Pipeline on a Jenkins controller (host) with one short-lived Kubernetes pod per stage.
// Terraform state lives in S3 (native locking). Files move between pods with stash/unstash.
// Credentials needed in Jenkins: "aws-creds" (Username with password = access key id / secret key)
//                                "grafana-admin-password" (Secret text)

def shouldDeploy() {
    return (params.ACTION ?: 'deploy') == 'deploy' && env.SKIP_DEPLOY != 'true'
}

// ---------- pod helpers ----------
def toolsC() {
    return '''  - name: tools
    image: alpine:3.20
    command: ["sleep"]
    args: ["infinity"]
    resources:
      requests: { memory: 128Mi, cpu: 100m }
      limits: { memory: 384Mi, cpu: 500m }
'''
}

def inPod(String containers, Closure body) {
    def yaml = """apiVersion: v1
kind: Pod
spec:
  containers:
  - name: jnlp
    image: jenkins/inbound-agent:latest-jdk21
    resources:
      requests: { memory: 128Mi, cpu: 50m }
      limits: { memory: 256Mi, cpu: 300m }
""" + containers
    podTemplate(cloud: 'k8s-todo-ci', yaml: yaml) {
        node(env.POD_LABEL) { body() }
    }
}

def withAws(Closure body) {
    withCredentials([usernamePassword(credentialsId: 'aws-creds',
                                      usernameVariable: 'AWS_ACCESS_KEY_ID',
                                      passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
        withEnv(['AWS_DEFAULT_REGION=ap-south-1', 'AWS_REGION=ap-south-1']) { body() }
    }
}

// tools pod (alpine + ssh/curl/jq/aws) with the sources and the Terraform outputs + SSH key restored
def inTools(Closure body) {
    inPod(toolsC()) {
        unstash 'src'
        unstash 'infra'
        withAws {
            container('tools') {
                sh 'apk add --no-cache bash openssh-client curl jq aws-cli > /dev/null && chmod 600 "$WORKSPACE/todo-key.pem"'
                body()
            }
        }
    }
}

def pre() {
    return '''set -euo pipefail
SSH_OPTS="-i $WORKSPACE/todo-key.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
OUT="$WORKSPACE/outputs.json"
'''
}

def tfContainers() {
    return '''  - name: terraform
    image: hashicorp/terraform:1.10
    command: ["sleep"]
    args: ["infinity"]
    resources:
      requests: { memory: 256Mi, cpu: 200m }
      limits: { memory: 512Mi, cpu: 1000m }
'''
}

def tfPrelude() {
    return '''set -euo pipefail
apk add --no-cache bash jq > /dev/null
cd "$WORKSPACE/aws/iac"
jq -n --arg op "$OPERATOR_CIDR" --arg key "$WORKSPACE/todo-key.pem" --arg v "${GRAFANA_VIEWER_CIDRS:-}" \\
    '{operator_cidr: $op, ssh_key_path: $key, grafana_viewer_cidrs: ($v | gsub(" "; "") | split(",") | map(select(length > 0)))}' \\
    > "$WORKSPACE/pipeline.tfvars.json"
terraform init -input=false \\
    -backend-config="bucket=$TF_STATE_BUCKET" \\
    -backend-config="key=todo/terraform.tfstate" \\
    -backend-config="region=ap-south-1" \\
    -backend-config="encrypt=true" \\
    -backend-config="use_lockfile=true"
'''
}

pipeline {
    agent none

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 90, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }


    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'destroy'],
               description: 'deploy: create everything on AWS. destroy: delete everything.')
        string(name: 'GRAFANA_VIEWER_CIDRS', defaultValue: '',
               description: 'Optional extra IPs allowed to open Grafana, comma separated, each like 203.0.113.4/32')
    }

    environment {
        AWS_REGION       = 'ap-south-1'
        TF_IN_AUTOMATION = '1'
        TF_STATE_BUCKET  = 'todo-tfstate-9bd1a0e4'
    }

    stages {
        stage('Prepare') {
            steps {
                script {
                    env.ACTION = params.ACTION ?: 'deploy'
                    env.GRAFANA_VIEWER_CIDRS = params.GRAFANA_VIEWER_CIDRS ?: ''
                    inPod(toolsC()) {
                        checkout scm
                        env.IMAGE_TAG = sh(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim()
                        stash name: 'src', excludes: '.git/**'
                        withAws {
                            container('tools') {
                                sh 'apk add --no-cache curl jq aws-cli > /dev/null'
                                sh 'aws sts get-caller-identity --query Arn --output text'
                                env.OPERATOR_CIDR = sh(script: 'curl -fsS https://checkip.amazonaws.com', returnStdout: true).trim() + '/32'
                                env.ENV_EXISTS = sh(script: '''
                                    if aws s3 cp "s3://$TF_STATE_BUCKET/todo/terraform.tfstate" - 2>/dev/null | jq -e '(.outputs | length) > 0' > /dev/null 2>&1; then echo yes; else echo no; fi
                                ''', returnStdout: true).trim()
                            }
                        }
                    }
                    def pushed = currentBuild.getBuildCauses('hudson.triggers.SCMTrigger$SCMTriggerCause')
                    env.SKIP_DEPLOY = 'false'
                    echo "Action: ${env.ACTION}, image tag: ${env.IMAGE_TAG}, your address: ${env.OPERATOR_CIDR}, environment exists: ${env.ENV_EXISTS}"
                    if (env.SKIP_DEPLOY == 'true') {
                        echo 'Push detected, but no AWS environment exists. Run Build Now once to create it. Nothing deployed.'
                    }
                }
            }
        }

        stage('Backend tests') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    def maven = '''  - name: maven
    image: maven:3.9.9-eclipse-temurin-17
    command: ["sleep"]
    args: ["infinity"]
    env:
    - { name: MAVEN_OPTS, value: "-Xmx256m" }
    - { name: SPRING_DATASOURCE_URL, value: "jdbc:mysql://127.0.0.1:3306/todo_db" }
    - { name: SPRING_DATASOURCE_USERNAME, value: "root" }
    - { name: SPRING_DATASOURCE_PASSWORD, value: "ci-only-pass" }
    - { name: COHERE_API_KEY, value: "ci-dummy" }
    - { name: SLACK_WEBHOOK_URL, value: "http://localhost/ci-dummy" }
    resources:
      requests: { memory: 384Mi, cpu: 200m }
      limits: { memory: 768Mi, cpu: 1000m }
  - name: mysql
    image: mysql:8.4
    args: ["--innodb-buffer-pool-size=64M", "--performance-schema=OFF"]
    env:
    - { name: MYSQL_ROOT_PASSWORD, value: "ci-only-pass" }
    - { name: MYSQL_DATABASE, value: "todo_db" }
    resources:
      requests: { memory: 256Mi, cpu: 100m }
      limits: { memory: 512Mi, cpu: 500m }
'''
                    inPod(maven) {
                        unstash 'src'
                        container('maven') {
                            sh '''#!/bin/bash
                                set -euo pipefail
                                for i in $(seq 1 40); do
                                    (echo > /dev/tcp/127.0.0.1/3306) 2>/dev/null && break
                                    sleep 3
                                done
                                (echo > /dev/tcp/127.0.0.1/3306)
                                cd Backend/todo-summary-assistant
                                mvn -B -q test
                            '''
                        }
                    }
                }
            }
        }

        stage('Create AWS environment') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    inPod(tfContainers()) {
                        unstash 'src'
                        withAws {
                            container('terraform') {
                                sh('#!/bin/bash\n' + tfPrelude() + '''
terraform apply -input=false -auto-approve -var-file="$WORKSPACE/pipeline.tfvars.json"
terraform output -json > "$WORKSPACE/outputs.json"
chown 1000:1000 "$WORKSPACE/outputs.json" "$WORKSPACE/todo-key.pem"
''')
                            }
                        }
                        stash name: 'infra', includes: 'outputs.json,todo-key.pem'
                    }
                }
            }
        }

        stage('Wait for hosts') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    inTools {
                        sh('#!/bin/bash\n' + pre() + '''
for ip in $(jq -r '.app_public_ip.value, .ops_public_ip.value' "$OUT"); do
    ready=no
    for i in $(seq 1 30); do
        if ssh $SSH_OPTS ubuntu@"$ip" 'cloud-init status --wait' > /dev/null 2>&1; then ready=yes; break; fi
        sleep 10
    done
    [ "$ready" = "yes" ] || { echo "Host $ip did not finish booting" >&2; exit 1; }
    echo "Host $ip is ready"
done
''')
                    }
                }
            }
        }

        stage('Build and push images') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    def kaniko = '''  - name: aws
    image: amazon/aws-cli:2.17.0
    command: ["sleep"]
    args: ["infinity"]
    volumeMounts:
    - { name: kaniko-docker, mountPath: /kaniko/.docker }
    resources:
      requests: { memory: 128Mi, cpu: 50m }
      limits: { memory: 256Mi, cpu: 300m }
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command: ["/busybox/cat"]
    tty: true
    volumeMounts:
    - { name: kaniko-docker, mountPath: /kaniko/.docker }
    resources:
      requests: { memory: 512Mi, cpu: 300m }
      limits: { memory: 1280Mi, cpu: 1500m }
  volumes:
  - name: kaniko-docker
    emptyDir: {}
'''
                    inPod(kaniko) {
                        unstash 'src'
                        withAws {
                            container('aws') {
                                sh '''#!/bin/bash
                                    set -euo pipefail
                                    ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
                                    REG="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
                                    TOKEN="$(aws ecr get-login-password)"
                                    AUTH="$(printf 'AWS:%s' "$TOKEN" | base64 -w0)"
                                    printf '{"auths":{"%s":{"auth":"%s"}}}' "$REG" "$AUTH" > /kaniko/.docker/config.json
                                    echo "$REG" > "$WORKSPACE/registry"
                                    : > "$WORKSPACE/build-list"
                                    for repo in todo-backend todo-frontend; do
                                        if aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$IMAGE_TAG" > /dev/null 2>&1; then
                                            echo "$repo:$IMAGE_TAG is already in ECR (tags are immutable), skipping"
                                        else
                                            echo "$repo" >> "$WORKSPACE/build-list"
                                        fi
                                    done
                                '''
                            }
                        }
                        container('kaniko') {
                            sh '''
                                REG="$(cat $WORKSPACE/registry)"
                                for repo in $(cat $WORKSPACE/build-list); do
                                    case "$repo" in
                                        todo-backend)  CTX=Backend/todo-summary-assistant ;;
                                        todo-frontend) CTX=Frontend/todo ;;
                                    esac
                                    /kaniko/executor --context="dir://$WORKSPACE/$CTX" --dockerfile="$WORKSPACE/$CTX/Dockerfile" \
                                        --destination="$REG/$repo:$IMAGE_TAG" --cache=false --snapshot-mode=redo
                                done
                            '''
                        }
                    }
                }
            }
        }

        stage('Deploy app') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    inTools {
                        sh('#!/bin/bash\n' + pre() + '''
APP_IP="$(jq -r .app_public_ip.value "$OUT")"
scp $SSH_OPTS docker-compose.prod.yml aws/deploy.sh ubuntu@"$APP_IP":~/todo/
ssh $SSH_OPTS ubuntu@"$APP_IP" "chmod +x ~/todo/deploy.sh && ~/todo/deploy.sh $IMAGE_TAG"
''')
                    }
                }
            }
        }

        stage('Verify app') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    inTools {
                        sh('#!/bin/bash\n' + pre() + '''
APP_IP="$(jq -r .app_public_ip.value "$OUT")"
curl -fsS --retry 5 --retry-delay 5 --retry-connrefused "http://$APP_IP/healthz"
curl -fsS "http://$APP_IP/api/todos" > /dev/null
RUNNING="$(ssh $SSH_OPTS ubuntu@"$APP_IP" 'cat ~/todo/.current_tag')"
echo "running tag: $RUNNING, expected: $IMAGE_TAG"
[ "$RUNNING" = "$IMAGE_TAG" ]
''')
                    }
                }
            }
        }

        stage('Start monitoring') {
            when { expression { shouldDeploy() } }
            steps {
                script {
                    withCredentials([string(credentialsId: 'grafana-admin-password', variable: 'GRAFANA_ADMIN_PASSWORD')]) {
                        inTools {
                            sh('#!/bin/bash\n' + pre() + '''
APP_PRIVATE="$(jq -r .app_private_ip.value "$OUT")"
OPS_IP="$(jq -r .ops_public_ip.value "$OUT")"
APP_IP="$(jq -r .app_public_ip.value "$OUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r monitoring/. "$WORK"/
for f in "$WORK"/targets/*.json.example; do
    sed "s/APP_PRIVATE_IP/$APP_PRIVATE/g" "$f" > "${f%.example}"
done

ssh $SSH_OPTS ubuntu@"$OPS_IP" 'mkdir -p ~/monitoring'
scp -r $SSH_OPTS "$WORK"/. ubuntu@"$OPS_IP":~/monitoring/
printf 'GRAFANA_ADMIN_PASSWORD=%s\\nGRAFANA_ANONYMOUS_VIEWER=true\\n' "$GRAFANA_ADMIN_PASSWORD" \
    | ssh $SSH_OPTS ubuntu@"$OPS_IP" 'umask 077; cat > ~/monitoring/.env'
ssh $SSH_OPTS ubuntu@"$OPS_IP" 'cd ~/monitoring && docker compose up -d'

for i in $(seq 1 24); do
    TARGETS="$(ssh $SSH_OPTS ubuntu@"$OPS_IP" 'curl -fsS localhost:9090/api/v1/targets' || echo '{}')"
    TOTAL="$(echo "$TARGETS" | jq '[.data.activeTargets[]?] | length')"
    BAD="$(echo "$TARGETS" | jq '[.data.activeTargets[]? | select(.health != "up")] | length')"
    echo "Prometheus targets: $TOTAL total, $BAD not up"
    if [ "$TOTAL" -ge 6 ] && [ "$BAD" -eq 0 ]; then
        echo "================================================================"
        echo "App:      http://$APP_IP"
        echo "Grafana:  http://$OPS_IP:3000"
        echo "Delete everything afterwards: Build with Parameters, ACTION = destroy"
        echo "================================================================"
        exit 0
    fi
    sleep 10
done
echo "$TARGETS" | jq '.data.activeTargets[]? | {job: .labels.job, host: .labels.host, health, lastError}' >&2
exit 1
''')
                        }
                    }
                }
            }
        }

        stage('Destroy AWS environment') {
            when { expression { params.ACTION == 'destroy' } }
            steps {
                script {
                    inPod(tfContainers()) {
                        unstash 'src'
                        withAws {
                            container('terraform') {
                                sh('#!/bin/bash\n' + tfPrelude() + '''
terraform destroy -input=false -auto-approve -var-file="$WORKSPACE/pipeline.tfvars.json"
''')
                            }
                        }
                    }
                }
            }
        }
    }

    post {
        success { echo "Pipeline finished (${env.ACTION})." }
        failure { echo 'Pipeline FAILED. If AWS resources were created, run it again with ACTION=destroy so nothing keeps costing money.' }
    }
}
