#!/bin/bash
# Deploy dell'app sul cluster EC2.
# Crea i due Secret necessari (credenziali dei servizi gestiti e token ECR)
# e applica i manifest. Le password non sono mai nel repo: si leggono da SSM.
# Uso: ./deploy.sh
set -e

REGION="eu-central-1"
REGISTRY=$(terraform output -raw ecr_registry)
export KUBECONFIG="$PWD/ansible/kubeconfig"

kubectl apply -f k8s/00-namespace.yaml

# --- Secret con le connection string lette da SSM Parameter Store ---
DATABASE_URL=$(aws ssm get-parameter --name /mensa/DATABASE_URL --with-decryption --region $REGION --query Parameter.Value --output text)
REDIS_URL=$(aws ssm get-parameter --name /mensa/REDIS_URL --region $REGION --query Parameter.Value --output text)
RABBITMQ_URL=$(aws ssm get-parameter --name /mensa/RABBITMQ_URL --with-decryption --region $REGION --query Parameter.Value --output text)

kubectl -n mensa create secret generic mensa-secrets \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=REDIS_URL="$REDIS_URL" \
  --from-literal=RABBITMQ_URL="$RABBITMQ_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- Secret per scaricare le immagini da ECR (token valido 12 ore) ---
kubectl -n mensa create secret docker-registry ecr-creds \
  --docker-server=$REGISTRY \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region $REGION)" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/

echo
echo "App in arrivo su: $(terraform output -raw app_url)"
kubectl -n mensa get pods
