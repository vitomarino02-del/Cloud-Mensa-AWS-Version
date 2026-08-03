#!/bin/bash
# Spegne tutto e azzera la spesa. Restano solo il bucket dello stato e la
# tabella di lock, che costano pochi centesimi l'anno.
# Uso: bash down.sh
set -e

terraform destroy -auto-approve

echo
echo "Rimasto in piedi (verifica):"
terraform state list || true
aws ec2 describe-instances --region eu-central-1 \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text
