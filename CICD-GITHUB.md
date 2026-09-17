# Pipeline CI/CD su AWS con GitHub Actions

Tre workflow in `.github/workflows/`:

| File | Quando parte | Job |
|---|---|---|
| `infra.yml` | push/PR su `main.tf` o `ansible/**` (o a mano) | `plan` (commento sulla PR) → `provision` (**approvazione manuale**) → `configure` (Ansible, kubeconfig su SSM, primo deploy) |
| `deploy.yml` | push su `k8s/**` o sul codice dei servizi (o a mano) | build + push su ECR (tag = SHA) → kubeconfig da SSM → `kubectl apply` → rollout |
| `destroy.yml` | **solo a mano**, con approvazione | cancella il kubeconfig su SSM → `terraform destroy` |

Differenze rispetto al laboratorio, e perche':
- **build delle immagini** in `deploy.yml`: il lab usa l'immagine pubblica di nginx, noi 4 immagini nostre;
- **un solo playbook** `site.yml` (tre play) invece di `00/01/02-*.yml`;
- **primo deploy dentro `configure`**: servono i Secret con le credenziali dei servizi gestiti (`deploy.sh`);
- **servizi gestiti** (RDS, ElastiCache, Amazon MQ, ECR): il ruolo ha bisogno di piu' policy.

## Preparazione (una volta sola)

### 1. Ruolo OIDC, a mano dalla console IAM (come nel lab)

**Identity provider** (se non c'e' gia'):
```
IAM → Identity providers → Add provider
  Provider type: OpenID Connect
  Provider URL:  https://token.actions.githubusercontent.com
  Audience:      sts.amazonaws.com
```

**Ruolo** `mensa-github-actions` (se esiste gia', basta aggiornarne le policy):
```
IAM → Roles → Create role → Web identity
  Identity provider: token.actions.githubusercontent.com
  Audience:          sts.amazonaws.com
  GitHub organization: vitomarino02-del
  GitHub repository:   Cloud-Mensa-AWS-Version
```
Policy da collegare:
- `AmazonEC2FullAccess` — istanze, VPC, security group, NLB
- `AmazonS3FullAccess` — bucket immagini e stato Terraform
- `AmazonDynamoDBFullAccess` — lock dello stato
- `AmazonSSMFullAccess` — connection string e kubeconfig
- `AmazonRDSFullAccess`, `AmazonElastiCacheFullAccess`, `AmazonMQFullAccess`
- `AmazonEC2ContainerRegistryFullAccess`

Policy **inline** (serve a creare il ruolo IAM dei nodi):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "iam:*",
      "Resource": [ "arn:aws:iam::862087104689:role/mensa-node-role",
                    "arn:aws:iam::862087104689:instance-profile/mensa-node-profile" ] },
    { "Effect": "Allow", "Action": "iam:CreateServiceLinkedRole", "Resource": "*" }
  ]
}
```

**Trust policy**: deve accettare anche il formato con gli ID immutabili
(problema gia' incontrato):
```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": [
    "repo:vitomarino02-del/Cloud-Mensa-AWS-Version:*",
    "repo:vitomarino02-del@*/Cloud-Mensa-AWS-Version@*:*"
  ]
}
```

> Il ruolo prima era dentro `main.tf`. Ora `main.tf` ha tre blocchi `removed`
> (Terraform ≥ 1.7): al prossimo apply il ruolo esce dallo stato **senza essere
> cancellato**. Se l'infrastruttura era spenta con `down.sh`, il ruolo e' stato
> distrutto e va ricreato come sopra.

### 2. Secret del repository
```
Settings → Secrets and variables → Actions → New secret
AWS_ROLE_ARN    = arn:aws:iam::862087104689:role/mensa-github-actions
SSH_PRIVATE_KEY = contenuto di ~/.ssh/id_rsa
SSH_PUBLIC_KEY  = contenuto di ~/.ssh/id_rsa.pub
```
Usare la **stessa chiave del PC**: con una chiave diversa Terraform sostituirebbe
key pair e istanze.

### 3. Approvazione manuale
```
Settings → Environments → New environment: production
  Required reviewers: il tuo utente
```
(Sui repo privati richiede un piano GitHub a pagamento.)

### 4. Protezione di main 
```
Settings → Branches → Add rule: main
  Require a pull request before merging
  Require status checks: plan
```

## Demo
1. Branch → modifica a `main.tf` (es. un tag) → PR → leggere il plan nel commento
2. Merge → approvare `production` nella scheda Actions → `provision` → `configure`
3. URL dell'app nel riepilogo del job
4. Modifica visibile al frontend → push → `Deploy to Kubernetes`
   (`kubectl -n mensa get deploy -o wide`: il tag e' lo SHA del commit)
5. Rollback: `git revert HEAD && git push`
6. Fine: Actions → Destroy AWS → Run workflow → approvare

## Piano B
`bash up.sh` / `bash down.sh` dal PC: stesso stato remoto; `up.sh` salva anche il
kubeconfig su SSM, cosi' `deploy.yml` funziona pure dopo un avvio manuale.
