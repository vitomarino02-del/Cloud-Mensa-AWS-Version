#!/bin/bash
# Avvia tutto l'ambiente da zero: infrastruttura, cluster, applicazione.
# Da rilanciare anche dopo un down.sh (le istanze sono nuove ogni volta).
# Uso: bash up.sh
set -e

echo "== 1/6 IP pubblico corrente =="
# il security group apre SSH e API server solo a questo indirizzo
echo "my_ip_cidr = \"$(curl -s https://checkip.amazonaws.com | tr -d '\n')/32\"" > terraform.tfvars
cat terraform.tfvars

echo
echo "== 2/6 infrastruttura AWS (RDS e Amazon MQ sono lenti, anche 30 minuti) =="
terraform init -input=false
terraform apply -auto-approve

echo
echo "== 3/6 cluster Kubernetes sulle EC2 =="
# l'inventory con gli IP l'ha appena scritto Terraform
cd ansible
ansible-playbook -i inventory.ini site.yml
cd ..
export KUBECONFIG="$PWD/ansible/kubeconfig"
kubectl get nodes

echo
echo "== 4/6 immagini su ECR =="
bash push-ecr.sh

echo
echo "== 5/6 deploy dell'applicazione =="
bash deploy.sh

echo
echo "== 6/6 foto dei piatti =="
APP=$(terraform output -raw app_url)
# i pod devono essere pronti prima di accettare gli upload
kubectl -n mensa wait --for=condition=available --timeout=180s deployment --all
bash upload-images.sh "$APP"

echo
echo "Fatto. App su: $APP"
echo "Per usare kubectl: export KUBECONFIG=$PWD/ansible/kubeconfig"
