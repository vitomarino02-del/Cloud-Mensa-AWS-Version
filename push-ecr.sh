#!/bin/bash
# Questo file builda le immagini dei servizi e le carica su ECR
# Su AWS non serve copiare i tar nei nodi come in locale perché  c'e' un registry
# Usa con ./push-ecr.sh [tag]   (default: 1.0)
set -e

TAG="${1:-1.0}"
REGION="eu-central-1"
REGISTRY=$(terraform output -raw ecr_registry)
SRC="."

# login di docker verso ECR (token valido 12 ore)
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

for s in menu-service order-service kitchen-service frontend; do
  echo "== $s =="
  docker build -t $REGISTRY/mensa/$s:$TAG $SRC/$s
  docker push $REGISTRY/mensa/$s:$TAG
done

echo "Immagini su ECR con tag $TAG"
