#!/bin/bash
# Spegne tutto e azzera la spesa. Restano solo il bucket dello stato e la
# tabella di lock, che costano pochi centesimi l'anno.
# Uso: bash down.sh
set -e

# il kubeconfig su SSM non e' gestito da Terraform
aws ssm delete-parameter --region eu-central-1 --name /mensa/kubeconfig 2>/dev/null || true
terraform destroy -auto-approve

echo
echo "Rimasto in piedi (verifica):"
terraform state list || true
aws ec2 describe-instances --region eu-central-1 \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text
