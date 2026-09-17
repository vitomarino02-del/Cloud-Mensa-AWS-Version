#!/bin/bash
# Avvia tutto l'ambiente da zero: infrastruttura, cluster, applicazione.
# Da rilanciare anche dopo un down.sh (le istanze sono nuove ogni volta).
# Uso: bash up.sh
# Strada principale: le pipeline GitHub Actions (.github/workflows). Questo
# script resta come piano B, per avviare tutto dal PC.
set -e

# SSH e API server ora sono aperti come nel laboratorio: il vecchio
# terraform.tfvars con my_ip_cidr non serve piu'
rm -f terraform.tfvars

echo "== 1/5 infrastruttura AWS (RDS e Amazon MQ sono lenti, anche 30 minuti) =="
terraform init -input=false
terraform apply -auto-approve

echo
echo "== 2/5 cluster Kubernetes sulle EC2 =="
# l'inventory con gli IP l'ha appena scritto Terraform
cd ansible
ansible-playbook -i inventory.ini site.yml
cd ..
export KUBECONFIG="$PWD/ansible/kubeconfig"
kubectl get nodes
# il kubeconfig va anche su SSM: la pipeline deploy.yml lo legge da li'
aws ssm put-parameter --region eu-central-1 --name /mensa/kubeconfig \
  --value "$(cat "$KUBECONFIG")" --type SecureString --tier Advanced --overwrite > /dev/null

echo
echo "== 3/5 immagini su ECR =="
bash push-ecr.sh

echo
echo "== 4/5 deploy dell'applicazione =="
bash deploy.sh

echo
echo "== 5/5 foto dei piatti =="
APP=$(terraform output -raw app_url)
# i pod devono essere pronti prima di accettare gli upload
kubectl -n mensa wait --for=condition=available --timeout=180s deployment --all
bash upload-images.sh "$APP"

echo
echo "Fatto. App su: $APP"
echo "Per usare kubectl: export KUBECONFIG=$PWD/ansible/kubeconfig"
