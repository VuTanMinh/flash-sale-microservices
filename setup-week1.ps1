# ============================================================
# Flash-Sale Microservices — Week 1 setup (native PowerShell)
# Generated from SETUP_GUIDE.md sections 1-7. Review before running.
# This script is NOT executed for you — run it yourself:
#   powershell -ExecutionPolicy Bypass -File .\setup-week1.ps1
# or paste sections into your terminal one at a time.
# ============================================================

# --- 1. Tools ---
winget install Microsoft.DotNet.SDK.9
dotnet tool install -g Volo.Abp.Cli
winget install Hashicorp.Terraform
# Docker Desktop: install manually if you haven't, enable WSL2 backend under
# Settings > Resources > WSL Integration.

dotnet --version
abp --version
terraform --version
docker --version

# --- 2. Repo & folder structure ---
# The repo already exists (github.com/VuTanMinh/flash-sale-microservices,
# cloned to D:\DACNTT, branch "week1") -- no `git init` here, just use it.
Set-Location D:\DACNTT
New-Item -ItemType Directory -Force -Path src, infra\terraform | Out-Null

# --- 3. Scaffold the three ABP services ---
Set-Location D:\DACNTT\src
abp new FlashSale.InventoryService -t app-nolayers -u none --database-provider ef -csf
abp new FlashSale.OrderService -t app-nolayers -u none --database-provider ef -csf
abp new FlashSale.WorkerService -t console -csf

# Verify each builds standalone
Set-Location D:\DACNTT\src\FlashSale.InventoryService
dotnet build
Set-Location D:\DACNTT\src\FlashSale.OrderService
dotnet build
Set-Location D:\DACNTT\src\FlashSale.WorkerService
dotnet build

# --- 4. Provision infra with Terraform ---
Set-Location D:\DACNTT\infra\terraform
New-Item -ItemType Directory -Force -Path modules\rabbitmq, modules\redis, modules\postgres, environments | Out-Null

@'
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

resource "docker_network" "flashsale_net" {
  name = "flashsale-network"
}

module "rabbitmq" {
  source  = "./modules/rabbitmq"
  network = docker_network.flashsale_net.name
}

module "redis" {
  source  = "./modules/redis"
  network = docker_network.flashsale_net.name
}

module "postgres" {
  source   = "./modules/postgres"
  network  = docker_network.flashsale_net.name
  password = var.postgres_password
  db_name  = var.postgres_db
}
'@ | Set-Content -Encoding utf8 main.tf

@'
variable "postgres_password" {
  description = "Password for the PostgreSQL superuser"
  type        = string
  sensitive   = true
  default     = "flashsale_dev_pw" # override per environment via tfvars
}

variable "postgres_db" {
  description = "Default database name"
  type        = string
  default     = "flashsale"
}
'@ | Set-Content -Encoding utf8 variables.tf

@'
output "rabbitmq_management_url" {
  value = "http://localhost:15672"
}

output "redis_connection" {
  value = "localhost:6379"
}

output "postgres_connection" {
  value     = "Host=localhost;Port=5432;Database=${var.postgres_db};Username=postgres;Password=${var.postgres_password}"
  sensitive = true
}
'@ | Set-Content -Encoding utf8 outputs.tf

@'
variable "network" {}

resource "docker_image" "rabbitmq" {
  name = "rabbitmq:3-management"
}

resource "docker_container" "rabbitmq" {
  name  = "flashsale-rabbitmq"
  image = docker_image.rabbitmq.image_id

  ports {
    internal = 5672
    external = 5672
  }
  ports {
    internal = 15672
    external = 15672
  }

  networks_advanced {
    name = var.network
  }
}
'@ | Set-Content -Encoding utf8 modules\rabbitmq\main.tf

@'
variable "network" {}

resource "docker_image" "redis" {
  name = "redis/redis-stack:latest"
}

resource "docker_container" "redis" {
  name  = "flashsale-redis"
  image = docker_image.redis.image_id

  ports {
    internal = 6379
    external = 6379
  }
  ports {
    internal = 8001
    external = 8001
  }

  networks_advanced {
    name = var.network
  }
}
'@ | Set-Content -Encoding utf8 modules\redis\main.tf

@'
variable "network" {}
variable "password" {}
variable "db_name" {
  default = "flashsale"
}

resource "docker_image" "postgres" {
  name = "postgres:16"
}

resource "docker_volume" "postgres_data" {
  name = "flashsale-postgres-data"
}

resource "docker_container" "postgres" {
  name  = "flashsale-postgres"
  image = docker_image.postgres.image_id

  env = [
    "POSTGRES_PASSWORD=${var.password}",
    "POSTGRES_DB=${var.db_name}"
  ]

  ports {
    internal = 5432
    external = 5432
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name = var.network
  }
}
'@ | Set-Content -Encoding utf8 modules\postgres\main.tf

@'
postgres_password = "local_dev_password_change_me"
postgres_db        = "flashsale_local"
'@ | Set-Content -Encoding utf8 environments\local.tfvars

@'
postgres_password = "loadtest_password_change_me"
postgres_db        = "flashsale_loadtest"
'@ | Set-Content -Encoding utf8 environments\loadtest.tfvars

terraform init
terraform plan -var-file="environments/local.tfvars"
terraform apply -var-file="environments/local.tfvars"
# If Terraform can't reach the Docker daemon, add to the provider block in main.tf:
#   provider "docker" { host = "npipe:////.//pipe//docker_engine" }

# --- 5. Verify infra ---
docker ps
# should list: flashsale-rabbitmq, flashsale-redis, flashsale-postgres
docker exec -it flashsale-redis redis-cli ping
# should return PONG
docker exec -it flashsale-postgres psql -U postgres -d flashsale_local -c "\l"
# RabbitMQ management UI: http://localhost:15672 (guest / guest)

# --- 6. Wire each service to its infra dependency ---

# 6.1 Inventory Service — Redis
Set-Location D:\DACNTT\src\FlashSale.InventoryService
dotnet add package StackExchange.Redis

$json = Get-Content appsettings.json -Raw | ConvertFrom-Json
$json | Add-Member -NotePropertyName Redis -NotePropertyValue ([PSCustomObject]@{ Configuration = "localhost:6379" }) -Force
$json | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 appsettings.json
# Manual smoke test (drop temporarily in Program.cs to confirm plumbing before Week 2 Cache-Aside work):
#   using StackExchange.Redis;
#   var redis = ConnectionMultiplexer.Connect("localhost:6379");
#   var db = redis.GetDatabase();
#   db.StringSet("healthcheck", "ok");
#   Console.WriteLine(db.StringGet("healthcheck")); // should print "ok"

# 6.2 Order Service — RabbitMQ event bus (publisher)
Set-Location D:\DACNTT\src\FlashSale.OrderService
abp add-package Volo.Abp.EventBus.RabbitMQ

$json = Get-Content appsettings.json -Raw | ConvertFrom-Json
$rabbitMq = [PSCustomObject]@{
    Connections = [PSCustomObject]@{ Default = [PSCustomObject]@{ HostName = "localhost" } }
    EventBus    = [PSCustomObject]@{ ClientName = "FlashSale_OrderService"; ExchangeName = "flashsale.order.exchange" }
}
$json | Add-Member -NotePropertyName RabbitMQ -NotePropertyValue $rabbitMq -Force
$json | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 appsettings.json
# Manual step — in FlashSaleOrderServiceModule.cs add to the class attribute:
#   [DependsOn(typeof(AbpEventBusRabbitMqModule))]

# 6.3 Worker Service — RabbitMQ event bus (consumer)
Set-Location D:\DACNTT\src\FlashSale.WorkerService
abp add-package Volo.Abp.EventBus.RabbitMQ

$json = Get-Content appsettings.json -Raw | ConvertFrom-Json
$rabbitMq = [PSCustomObject]@{
    Connections = [PSCustomObject]@{ Default = [PSCustomObject]@{ HostName = "localhost" } }
    EventBus    = [PSCustomObject]@{ ClientName = "FlashSale_WorkerService"; ExchangeName = "flashsale.order.exchange" }
}
$json | Add-Member -NotePropertyName RabbitMQ -NotePropertyValue $rabbitMq -Force
$json | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 appsettings.json
# Manual step — same [DependsOn(typeof(AbpEventBusRabbitMqModule))] in FlashSaleWorkerServiceModule.cs
# Note: ExchangeName must match the Order Service's ("flashsale.order.exchange") so the
# Worker receives what the Order Service publishes.

# --- Local commit only (no remote push — push it yourself when ready) ---
Set-Location D:\DACNTT
git add .
git commit -m "chore: scaffold 3 ABP services + terraform infra provisioning"
# git push origin week1
