
# VPC ,cluster Kubernetes su EC2 , servizi gestiti


terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Stato remoto, S3 lo conserva, DynamoDB impedisce apply simultanei
  # Bucket e tabella creati una sola volta con la AWS CLI
  backend "s3" {
    bucket         = "mensa-tfstate-862087104689"
    key            = "mensa/aws/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "mensa-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "cloud-mensa"
      Env     = "aws"
    }
  }
}

# ---------------------------------------------------------------- variabili

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "project" {
  type    = string
  default = "mensa"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Due subnet pubbliche in AZ diverse: RDS e i load balancer richiedono almeno due Availability Zone.
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

# Indirizzo da cui si collega in SSH e all'app
variable "my_ip_cidr" {
  type        = string
  description = "IP pubblico autorizzato per SSH"
}

variable "instance_type" {
  type    = string
  default = "t3.small" # kubeadm richiede 2 vCPU / 2 GB
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

# ------------------------------------------------------------------- rete
# VPC dedicata con due subnet pubbliche.
# Niente NAT Gateway, i nodi stanno in subnet pubbliche e protetti dai security_groups
#senza la vpc rds e ElastiCache non darebbero un endpoint DNS risolvibile

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project}-vpc" }
}
#INTERNET GATEWAY, serve per la rotta della vpc verso internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" { #una subnet creata per ogni cidr
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- Security group dei nodi del cluster ----
resource "aws_security_group" "nodes" {
  name        = "${var.project}-nodes"
  description = "Nodi Kubernetes"
  vpc_id      = aws_vpc.main.id

  # SSH solo dal proprio IP (per Ansible)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # API server Kubernetes 
  ingress {
    description = "kube-apiserver"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # NodePort dell'app raggiunta dal load balancer e dal proprio IP
  ingress {
    description = "NodePort frontend"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr, var.my_ip_cidr]
  }

  # Traffico interno al cluster (kubelet, etcd, Flannel VXLAN...)
  ingress {
    description = "Traffico tra i nodi"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-nodes-sg" }
}

# ---- Security group dei servizi gestiti: accessibili solo dai nodi ----
resource "aws_security_group" "data" {
  name        = "${var.project}-data"
  description = "RDS, ElastiCache, Amazon MQ"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.nodes.id] #possono connettersi a Postgres solo le risorse che appartengono al security group dei nodi
  }

  ingress {
    description     = "Redis"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.nodes.id]
  }

  ingress {
    description     = "AMQP (RabbitMQ)"
    from_port       = 5671
    to_port         = 5671
    protocol        = "tcp"
    security_groups = [aws_security_group.nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-data-sg" }
}

# ------------------------------------------------------------------- dati
# Bucket S3 per le foto dei piatti: sostituisce il volume locale della Fase 1
# (nel codice basta STORAGE_BACKEND=s3, nessuna modifica applicativa).

resource "aws_s3_bucket" "images" {
  bucket        = "${var.project}-images-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

# Password generate da Terraform, non scritte nel codice.
# special = false per non rompere il parsing delle URL di connessione
resource "random_password" "db" {
  length  = 20
  special = false
}

resource "random_password" "mq" {
  length  = 20
  special = false # Amazon MQ non ammette virgole, due punti e spazi
}

# RDS ed ElastiCache vanno in un gruppo di subnet su due AZ diverse
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnets"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-cache-subnets"
  subnet_ids = aws_subnet.public[*].id
}

# ---- RDS PostgreSQL: sostituisce il pod postgres ----
resource "aws_db_instance" "postgres" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro" # free tier

  allocated_storage = 20
  storage_encrypted = true

  db_name  = "mensa"
  username = "mensa"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.data.id]
  publicly_accessible    = false # raggiungibile solo dentro la VPC

  skip_final_snapshot = true # in produzione sarebbe da evitare
  apply_immediately   = true

  tags = { Name = "${var.project}-db" }
}

# ---- ElastiCache Redis: tabellone cucina ----
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project}-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.data.id]

  tags = { Name = "${var.project}-redis" }
}

# ---- Amazon MQ per RabbitMQ: coda eventi ordine ----
# AWS non supporta piu' mq.t3.micro con RabbitMQ: mq.m7g.medium e' il taglio
# piu' economico disponibile. Amazon MQ usa AMQPS (TLS) sulla porta 5671,
# non 5672 in chiaro: pika gestisce amqps:// senza modifiche al codice.
resource "aws_mq_broker" "rabbitmq" {
  broker_name        = "${var.project}-mq"
  engine_type        = "RabbitMQ"
  engine_version     = "3.13"
  host_instance_type = "mq.m7g.medium"
  deployment_mode    = "SINGLE_INSTANCE"

  subnet_ids                 = [aws_subnet.public[0].id]
  security_groups            = [aws_security_group.data.id]
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  user {
    username = "mensa"
    password = random_password.mq.result
  }

  tags = { Name = "${var.project}-mq" }
}

# ---- SSM Parameter Store: connection string dei servizi gestiti ----
# Lo script di deploy le legge da qui e crea il Secret Kubernetes:
# nessuna credenziale nel repo o nei manifest.
resource "aws_ssm_parameter" "database_url" {
  name  = "/${var.project}/DATABASE_URL"
  type  = "SecureString"
  value = "postgresql://mensa:${random_password.db.result}@${aws_db_instance.postgres.address}:5432/mensa"
}

resource "aws_ssm_parameter" "redis_url" {
  name  = "/${var.project}/REDIS_URL"
  type  = "String"
  value = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379/0"
}

resource "aws_ssm_parameter" "rabbitmq_url" {
  name  = "/${var.project}/RABBITMQ_URL"
  type  = "SecureString"
  # l'endpoint di Amazon MQ arriva gia' come "amqps://host:5671"
  value = "amqps://mensa:${random_password.mq.result}@${replace(aws_mq_broker.rabbitmq.instances[0].endpoints[0], "amqps://", "")}"
}

# --------------------------------------------------------------- computing
# Tre istanze EC2 (1 control plane + 2 worker): stesso ruolo delle VM

# AMI Ubuntu 22.04 piu' recente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# La chiave SSH del PC viene caricata su AWS e messa nelle istanze
resource "aws_key_pair" "main" {
  key_name   = "${var.project}-key"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# Ruolo IAM istanze, fa scaricare immagini da ECR e usare S3 senza mettere credenziali nel codice o nei pod
resource "aws_iam_role" "node" {
  name = "${var.project}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "s3_images" {
  name = "${var.project}-s3-images"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.images.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project}-node-profile"
  role = aws_iam_role.node.name
}

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name

  root_block_device {
    volume_size = 20
  }

  tags = { Name = "${var.project}-cp" }
}

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name

  root_block_device {
    volume_size = 20
  }

  tags = { Name = "${var.project}-worker-${count.index + 1}" }
}

# ----+++ QUI C'E' IL NETWORK LOAD BALANCER: unico punto di ingresso pubblico dell'app +++----
resource "aws_lb" "frontend" {
  name               = "${var.project}-nlb"
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project}-nlb" }
}

# Il target group punta alla NodePort 30080 dei worker
resource "aws_lb_target_group" "frontend" {
  name        = "${var.project}-tg"
  port        = 30080
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
  }
}

resource "aws_lb_target_group_attachment" "workers" {
  count            = var.worker_count
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.worker[count.index].id
  port             = 30080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# ---- ECR: registry privato per le immagini dei servizi ----
resource "aws_ecr_repository" "services" {
  for_each = toset(["menu-service", "order-service", "kitchen-service", "frontend"])

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # comodo in un progetto didattico: destroy senza svuotare a mano
}

# ---- Inventory Ansible generato con gli IP reali delle istanze ----
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/ansible/inventory.ini"

  content = <<-EOT
    [control_plane]
    ${var.project}-cp ansible_host=${aws_instance.control_plane.public_ip}

    [workers]
    %{for i, w in aws_instance.worker~}
    ${var.project}-worker-${i + 1} ansible_host=${w.public_ip}
    %{endfor~}

    [k8s_cluster:children]
    control_plane
    workers

    [k8s_cluster:vars]
    ansible_user=ubuntu
    ansible_ssh_private_key_file=${pathexpand(replace(var.ssh_public_key_path, ".pub", ""))}
    ansible_ssh_common_args='-o StrictHostKeyChecking=no'
  EOT
}

# ------------------------------------------------------------------ output

output "control_plane_ip" {
  value = aws_instance.control_plane.public_ip
}

output "worker_ips" {
  value = aws_instance.worker[*].public_ip
}

output "app_url" {
  description = "URL pubblico dell'app (Network Load Balancer)"
  value       = "http://${aws_lb.frontend.dns_name}"
}

output "s3_bucket_images" {
  value = aws_s3_bucket.images.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "mq_endpoint" {
  value = aws_mq_broker.rabbitmq.instances[0].endpoints[0]
}

output "ecr_registry" {
  description = "Registry ECR per docker login e push"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

data "aws_caller_identity" "current" {}

# Le foto dei piatti devono essere visibili dal browser: policy di sola
# lettura sugli oggetti. Le chiavi sono uuid casuali e nessuno puo' scrivere
# nel bucket dall'esterno. In alternativa si sarebbero potuti usare presigned
# URL, tenendo il bucket completamente privato.
resource "aws_s3_bucket_policy" "images_public_read" {
  bucket     = aws_s3_bucket.images.id
  depends_on = [aws_s3_bucket_public_access_block.images]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.images.arn}/*"
    }]
  })
}

# ---------------------------------------------------------------- CI/CD
# GitHub Actions si autentica su AWS con OIDC: niente chiavi statiche nei
# secret del repository, solo credenziali temporanee (1 ora).

variable "github_repo" {
  description = "owner/repo autorizzato ad assumere il ruolo"
  type        = string
  default     = "vitomarino02-del/Cloud-Mensa-AWS-Version"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Il ruolo puo' essere assunto SOLO dai workflow di questo repository
resource "aws_iam_role" "github_actions" {
  name = "${var.project}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

# Permessi minimi: push su ECR e invio comandi al control plane via SSM
resource "aws_iam_role_policy" "github_actions" {
  name = "${var.project}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage"
        ]
        Resource = [for r in aws_ecr_repository.services : r.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      }
    ]
  })
}

# Serve perche' SSM possa eseguire comandi sulle istanze
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

output "github_actions_role_arn" {
  description = "Da inserire nel secret AWS_ROLE_ARN del repository"
  value       = aws_iam_role.github_actions.arn
}
