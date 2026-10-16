pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        AWS_REGION         = 'ap-south-1'
        AWS_DEFAULT_REGION = 'ap-south-1'
        APP_HOST           = '10.0.2.184'   // private IP of the app host, not a secret
    }

    stages {
        stage('Prepare') {
            steps {
                script {
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim()
                    def account = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    env.ECR_REGISTRY = "${account}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                }
                echo "Building commit tag ${env.IMAGE_TAG}"
            }
        }

        stage('Backend tests') {
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    NET="ci-${BUILD_NUMBER}"
                    DB="ci-mysql-${BUILD_NUMBER}"
                    CI_DB_PASS="$(openssl rand -hex 12)"
                    cleanup() {
                        docker rm -f "$DB" > /dev/null 2>&1 || true
                        docker network rm "$NET" > /dev/null 2>&1 || true
                    }
                    trap cleanup EXIT

                    docker network create "$NET"
                    docker run -d --name "$DB" --network "$NET" \
                        -e MYSQL_ROOT_PASSWORD="$CI_DB_PASS" -e MYSQL_DATABASE=todo_db mysql:8.4

                    # wait until MySQL answers over TCP (the first-start temporary server does not)
                    for i in $(seq 1 40); do
                        if docker exec "$DB" mysqladmin ping -h 127.0.0.1 --silent; then break; fi
                        sleep 3
                    done
                    docker exec "$DB" mysqladmin ping -h 127.0.0.1 --silent

                    mkdir -p "$HOME/.m2-ci"
                    docker run --rm --network "$NET" -u "$(id -u):$(id -g)" \
                        -v "$PWD/Backend/todo-summary-assistant:/app" -w /app \
                        -v "$HOME/.m2-ci:/tmp/.m2" \
                        -e MAVEN_OPTS="-Duser.home=/tmp -Dmaven.repo.local=/tmp/.m2" \
                        -e SPRING_DATASOURCE_URL="jdbc:mysql://$DB:3306/todo_db" \
                        -e SPRING_DATASOURCE_USERNAME=root \
                        -e SPRING_DATASOURCE_PASSWORD="$CI_DB_PASS" \
                        -e COHERE_API_KEY=ci-dummy -e SLACK_WEBHOOK_URL=http://localhost/ci-dummy \
                        maven:3.9.9-eclipse-temurin-17 mvn -B -q test
                '''
            }
        }

        stage('Build images') {
            steps {
                sh '''
                    set -eu
                    docker build -t "${ECR_REGISTRY}/todo-backend:${IMAGE_TAG}" Backend/todo-summary-assistant
                    docker build -t "${ECR_REGISTRY}/todo-frontend:${IMAGE_TAG}" Frontend/todo
                '''
            }
        }

        stage('Push to ECR') {
            when { branch 'main' }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    export DOCKER_CONFIG="$(mktemp -d)"
                    trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                    aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                    for repo in todo-backend todo-frontend; do
                        if aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$IMAGE_TAG" > /dev/null 2>&1; then
                            echo "$repo:$IMAGE_TAG is already in ECR (tags are immutable), skipping push"
                        else
                            docker push "${ECR_REGISTRY}/${repo}:${IMAGE_TAG}"
                        fi
                    done
                '''
            }
        }

        stage('Deploy to EC2') {
            when { branch 'main' }
            steps {
                sshagent(credentials: ['app-ssh']) {
                    sh '''#!/bin/bash
                        set -euo pipefail
                        SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
                        ssh $SSH_OPTS ubuntu@${APP_HOST} 'mkdir -p ~/todo'
                        scp $SSH_OPTS docker-compose.prod.yml aws/deploy.sh ubuntu@${APP_HOST}:~/todo/
                        ssh $SSH_OPTS ubuntu@${APP_HOST} "chmod +x ~/todo/deploy.sh && ~/todo/deploy.sh ${IMAGE_TAG}"
                    '''
                }
            }
        }

        stage('Verify deployment') {
            when { branch 'main' }
            steps {
                sshagent(credentials: ['app-ssh']) {
                    sh '''#!/bin/bash
                        set -euo pipefail
                        curl -fsS --retry 5 --retry-delay 5 --retry-connrefused "http://${APP_HOST}/healthz"
                        curl -fsS "http://${APP_HOST}/api/todos" > /dev/null
                        RUNNING="$(ssh -o StrictHostKeyChecking=accept-new ubuntu@${APP_HOST} 'cat ~/todo/.current_tag')"
                        echo "running tag: $RUNNING, expected: $IMAGE_TAG"
                        [ "$RUNNING" = "$IMAGE_TAG" ]
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                docker rmi "${ECR_REGISTRY}/todo-backend:${IMAGE_TAG}" "${ECR_REGISTRY}/todo-frontend:${IMAGE_TAG}" > /dev/null 2>&1 || true
                docker image prune -f > /dev/null 2>&1 || true
            '''
        }
        success { echo "Pipeline finished: ${env.IMAGE_TAG} is deployed (if this was main)." }
        failure { echo "Pipeline FAILED. The previous version keeps running (deploy.sh rolls back on a failed health check)." }
    }
}
