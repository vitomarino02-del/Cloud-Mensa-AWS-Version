# Cloud Mensa — versione AWS

Questa è la seconda parte del progetto di Sistemi Cloud: la stessa applicazione
della mensa universitaria, ma portata su AWS. La versione locale (Multipass +
kubeadm) sta qui: https://github.com/vitomarino02-del/Cloud-Mensa

La cosa che mi interessava dimostrare è che **il codice dell'applicazione non è
cambiato di una riga**. Tutta la configurazione arriva dall'ambiente, quindi per
passare dal cluster sul portatile ad AWS è bastato cambiare le variabili:
`DATABASE_URL` ora punta a RDS invece che al pod postgres, `STORAGE_BACKEND`
passa da `local` a `s3` e il codice boto3 che avevo scritto in Fase 1 (e che fino
a ieri non serviva a niente) inizia a scrivere su un bucket vero.

![Architettura su AWS](architettura-aws.png)

## Com'è fatta

Il cluster Kubernetes gira su tre istanze EC2 — una control plane e due worker —
montate con kubeadm tramite Ansible. Ho preferito questa strada a EKS: costa
molto meno, mi permette di riusare quasi identico il playbook della Fase 1, ed è
esplicitamente indicata come alternativa nella traccia. Davanti c'è un Network
Load Balancer che raccoglie il traffico e lo manda alla NodePort 30080 dei
worker, quindi l'app ha un indirizzo pubblico senza dover esporre i nodi.

I tre container di appoggio che in locale stavano dentro il cluster sono diventati
servizi gestiti: PostgreSQL è su **RDS**, Redis su **ElastiCache**, RabbitMQ su
**Amazon MQ**. Le foto dei piatti finiscono su **S3** invece che su un volume, e
le immagini Docker stanno su **ECR** — sparisce quindi lo script che in locale
copiava i tar dentro le VM, perché adesso i nodi fanno il pull da soli.

Un dettaglio su cui ho perso un po' di tempo: Amazon MQ parla AMQPS su TLS, porta
5671, non 5672 in chiaro come RabbitMQ in locale. Fortunatamente `pika` gestisce
`amqps://` senza modifiche, quindi è bastato cambiare la stringa di connessione.

## Le password

Non c'è nessuna credenziale nel repository, ed è una cosa a cui ho fatto
attenzione fin dall'inizio. Le password se le genera Terraform (`random_password`),
poi le scrive cifrate su **SSM Parameter Store** insieme agli endpoint. Quando
lancio `deploy.sh`, lo script le rilegge da lì e crea il Secret di Kubernetes al
volo. Anche lo stato di Terraform — che le contiene in chiaro — non è versionato:
sta su S3, cifrato, con una tabella DynamoDB che fa da lock per evitare due
`apply` in contemporanea.

Discorso simile per S3: il menu-service ci scrive sopra senza avere nessuna chiave
AWS, perché le istanze hanno un ruolo IAM e boto3 recupera credenziali temporanee
dal metadata service.

## Struttura

```
main.tf              rete, EC2, NLB, RDS, ElastiCache, Amazon MQ, S3, ECR, IAM, SSM
ansible/site.yml     installazione del cluster kubeadm sulle istanze
k8s/                 manifest dell'app (immagini da ECR, ConfigMap + Secret)
push-ecr.sh          build e push delle immagini
deploy.sh            legge i segreti da SSM e applica i manifest
menu-service/  order-service/  kitchen-service/  frontend/
```

## Come si tira su

Servono AWS CLI configurata, Terraform, Ansible, kubectl, Docker e una chiave SSH
in `~/.ssh/id_rsa`. Io lavoro da WSL2 perché Ansible su Windows nativo non gira.

Il backend dello stato va creato a mano una volta sola, prima del primo `init`
(problema dell'uovo e della gallina: Terraform non può creare il bucket in cui
salverà il proprio stato):

```
aws s3api create-bucket --bucket mensa-tfstate-<ACCOUNT_ID> --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1
aws dynamodb create-table --table-name mensa-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region eu-central-1
```

Poi il proprio IP pubblico, perché il security group apre SSH e API server solo a
quell'indirizzo:

```
echo "my_ip_cidr = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars
```

E da lì in avanti:

```
terraform init && terraform apply
cd ansible && ansible-playbook -i inventory.ini site.yml && cd ..
bash push-ecr.sh
bash deploy.sh
```

Terraform genera da solo l'inventory di Ansible con gli IP delle istanze, quindi
non c'è niente da copiare a mano fra un passaggio e l'altro. Alla fine `terraform
output app_url` stampa l'indirizzo del load balancer.

Avviso sui tempi: RDS ci ha messo mezz'ora buona a nascere e Amazon MQ una decina
di minuti, quindi il primo `apply` non è una cosa da fare di fretta.

## Cose che ho scoperto strada facendo

**mq.t3.micro non esiste più per RabbitMQ.** Amazon MQ lo supporta solo con
ActiveMQ; per RabbitMQ il taglio più piccolo disponibile è `mq.m7g.medium`, che
costa comunque un decimo di `m5.large`. Il primo `apply` è fallito proprio lì.

**Niente NAT Gateway.** Costa una trentina di dollari al mese fissi e per questo
progetto non serve: i nodi stanno in subnet pubbliche e sono protetti dai security
group, con SSH e API server aperti solo al mio IP.

**Il token di ECR dura 12 ore.** Il Secret `ecr-creds` che permette a Kubernetes
di scaricare le immagini va rigenerato (basta rilanciare `deploy.sh`). In
produzione si userebbe il credential provider di AWS, o direttamente EKS che se ne
occupa da solo: qui ho preferito la soluzione semplice e documentarne il limite.

**Il certificato dell'API server.** Il control plane pubblicizza l'IP privato per
parlare con i nodi, ma per usare `kubectl` dal mio PC serve che il certificato
includa anche quello pubblico — da cui il flag `--apiserver-cert-extra-sans` nel
playbook, e la riscrittura del kubeconfig scaricato.

## Costi

Con tutto acceso siamo sui pochi euro al giorno. `terraform destroy` smonta ogni
cosa e riporta la spesa a zero; restano solo il bucket dello stato e la tabella di
lock, che costano frazioni di centesimo. Quando riprendo, `terraform apply` ricrea
l'infrastruttura in qualche minuto — poi vanno rifatti il playbook Ansible e il
deploy, perché le istanze sono nuove.
