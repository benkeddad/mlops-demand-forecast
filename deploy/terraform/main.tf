#Step 1: The Core Provider Configuration
terraform {
  required_version = ">= 1.0.0"
  
  # 1. Declare that we need the Kubernetes engine manager
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24.0" 
    }
    # Claude added: only used to mint the self-signed cert for the ingress
    # below - no external CA or DNS provider needed for a local K3s demo.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# 2. Point Terraform directly to your K3s cluster credentials
provider "kubernetes" {
  config_path = "${path.module}/k3s.yaml"
}

# Claude added: credentials as variables instead of hardcoded literals, so the
# actual values live in a Kubernetes Secret (below) instead of being pasted
# directly into every Deployment resource. Defaults match the project's
# existing demo credentials so `terraform apply` still works with zero flags -
# a real deployment overrides these via terraform.tfvars (gitignored) or
# TF_VAR_postgres_password / TF_VAR_postgres_user environment variables
# instead of editing this file.
variable "postgres_user" {
  description = "PostgreSQL superuser name shared by every service in the stack."
  type        = string
  default     = "user"
}

variable "postgres_password" {
  description = "PostgreSQL superuser password. Override via terraform.tfvars or TF_VAR_postgres_password for a real deployment."
  type        = string
  default     = "Password"
  sensitive   = true
}

variable "postgres_db" {
  description = "Name of the primary application database (train/test tables)."
  type        = string
  default     = "rossmann"
}

# NEW: A real Kubernetes Secret instead of the plaintext env values every
# Deployment below used to declare inline (see Known Limitations in the
# README). Storing the fully-composed connection strings as their own keys
# means no Deployment has to concatenate user/password fragments together.
resource "kubernetes_secret" "postgres_credentials" {
  metadata {
    name = "postgres-credentials"
  }

  data = {
    POSTGRES_USER     = var.postgres_user
    POSTGRES_PASSWORD = var.postgres_password
    POSTGRES_DB       = var.postgres_db

    API_DATABASE_URL         = "postgresql://${var.postgres_user}:${var.postgres_password}@postgres:5432/${var.postgres_db}"
    MLFLOW_BACKEND_STORE_URI = "postgresql://${var.postgres_user}:${var.postgres_password}@postgres:5432/mlflow"
    PREFECT_DB_URL           = "postgresql+asyncpg://${var.postgres_user}:${var.postgres_password}@postgres:5432/prefect"
  }

  type = "Opaque"
}

# Claude added: LocalStack's S3 endpoint reachable from INSIDE the cluster is
# different from the host-side one (http://127.0.0.1:4566) .dvc/config.local
# uses - pods have their own network namespace and can't reach the WSL host's
# loopback-bound services, only the K3s node's real IP. LocalStack itself now
# runs as a Deployment/Service inside this same cluster (below), and k3s's
# built-in ServiceLB always publishes a LoadBalancer Service on the node's own
# IP - the same address every other Service in this file already resolves to
# - so this value keeps working unchanged even though LocalStack moved
# in-cluster. Still a single-node, local-dev-only value with no portable way
# to auto-discover it generically - override via terraform.tfvars if the
# node's IP ever changes (e.g. after a WSL/Docker restart re-assigns it).
variable "localstack_endpoint" {
  description = "LocalStack S3 endpoint reachable from inside the K3s cluster (node IP, not 127.0.0.1)."
  type        = string
  default     = "http://10.21.36.158:4566"
}

# LocalStack itself, pinned to 4.4.0 (plain community image - no
# LOCALSTACK_AUTH_TOKEN needed, S3 is a free-tier service). Runs the same way
# every other backing service in this file does: a Deployment + LoadBalancer
# Service, image pre-pulled into containerd by the k3s deploy scripts.
resource "kubernetes_deployment" "localstack" {
  metadata {
    name = "localstack"
    labels = {
      app = "localstack"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "localstack"
      }
    }

    template {
      metadata {
        labels = {
          app = "localstack"
        }
      }

      spec {
        container {
          name               = "localstack"
          image              = "localstack/localstack:4.4.0"
          image_pull_policy  = "IfNotPresent"

          port {
            container_port = 4566
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "localstack" {
  metadata {
    name = "localstack"
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "localstack"
    }
    port {
      port        = 4566
      target_port = 4566
    }
  }
}

# Override via terraform.tfvars or TF_VAR_aws_access_key_id / TF_VAR_aws_secret_access_key
# for a real deployment - LocalStack ignores the actual values (any non-empty
# string works), so "test"/"test" are safe, portable defaults for local dev.
variable "aws_access_key_id" {
  description = "AWS/S3 access key - dummy value for LocalStack, real key for actual AWS."
  type        = string
  default     = "test"
}

variable "aws_secret_access_key" {
  description = "AWS/S3 secret key - dummy value for LocalStack, real key for actual AWS."
  type        = string
  default     = "test"
  sensitive   = true
}

variable "aws_default_region" {
  description = "AWS/S3 region."
  type        = string
  default     = "us-east-1"
}

# NEW: MLflow's artifact store (models, not run metadata - that's still
# Postgres via MLFLOW_BACKEND_STORE_URI above) now lives in S3 instead of a
# PersistentVolumeClaim. Both MLflow (writing) and the API
# (mlflow.pyfunc.load_model reading) need these same four values.
resource "kubernetes_secret" "s3_credentials" {
  metadata {
    name = "s3-credentials"
  }

  data = {
    MLFLOW_S3_ENDPOINT_URL = var.localstack_endpoint
    AWS_ACCESS_KEY_ID      = var.aws_access_key_id
    AWS_SECRET_ACCESS_KEY  = var.aws_secret_access_key
    AWS_DEFAULT_REGION     = var.aws_default_region
  }

  type = "Opaque"
}

#Step 2: The PostgreSQL & Redis Backend
# 1. ConfigMap to hold your database structure script
resource "kubernetes_config_map" "postgres_init" {
  metadata {
    name = "postgres-init-config"
  }

  data = {
    # ADDED: Include create-databases.sql so it mounts in the init folder
    # Claude modified these two lines: this file now lives in deploy/terraform/ (was terraform/),
    # and init.sql / create-databases.sql moved to db/, so it's two levels up + db/ instead of one
    "create-databases.sql" = file("${path.module}/../../db/create-databases.sql")
    # END OF CHANGE
    "init.sql" = file("${path.module}/../../db/init.sql")
  }
}

# NEW: Claim 2 Gigabytes of persistent local storage from K3s
resource "kubernetes_persistent_volume_claim" "postgres_data" {
  metadata {
    name = "postgres-data-pvc"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  wait_until_bound = false # <-- Breaks the K3s storage deadlock
}

# 2. PostgreSQL Engine Deployment (Updated with volume mount)
resource "kubernetes_deployment" "postgres" {
  metadata {
    name = "postgres"
    labels = {
      app = "postgres"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:15-alpine"
          image_pull_policy = "IfNotPresent"

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }

          port {
            container_port = 5432
          }

          # Mount the init script
          volume_mount {
            name       = "init-script"
            mount_path = "/docker-entrypoint-initdb.d"
          }

          # NEW: Mount the persistent volume claim to the database storage folder
          volume_mount {
            name       = "database-storage"
            mount_path = "/var/lib/postgresql/data"
          }
        }

        volume {
          name = "init-script"
          config_map {
            name = "postgres-init-config"
          }
        }

        # NEW: Link the volume to the claim we created above
        volume {
          name = "database-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

# 3. PostgreSQL Internal Networking Service
resource "kubernetes_service" "postgres" {
  metadata {
    name = "postgres"
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

# 4. Redis Feature Store Deployment
resource "kubernetes_deployment" "redis" {
  metadata {
    name = "redis"
    labels = {
      app = "redis"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        container {
          name  = "redis"
          image = "redis:7-alpine"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 6379
          }
        }
      }
    }
  }
}

# 5. Redis Internal Networking Service
resource "kubernetes_service" "redis" {
  metadata {
    name = "redis"
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
  }
}

#Step 3: The Orchestration & Tracking Layer (MLflow & Prefect).
# 1. MLflow Storage Claim for tracking logs and model artifacts
resource "kubernetes_persistent_volume_claim" "mlflow_data" {
  metadata {
    name = "mlflow-data-pvc"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  wait_until_bound = false # <-- Breaks the K3s storage deadlock
}

# 2. MLflow Tracking Server Deployment
resource "kubernetes_deployment" "mlflow" {
  # CHANGED: Declare explicit dependency on Postgres before attempting configuration
  depends_on = [
    kubernetes_deployment.postgres
  ]
  # END OF CHANGE

  metadata {
    name = "mlflow"
    labels = {
      app = "mlflow"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "mlflow"
      }
    }

    template {
      metadata {
        labels = {
          app = "mlflow"
        }
      }

      spec {
        container {
          name  = "mlflow"
          # CHANGED: Swap original upstream image with custom local driver image
          image = "rossmann-mlflow:latest"
          # END OF CHANGE
          image_pull_policy = "IfNotPresent"
          
          # Claude changed: the connection string is now read from the Secret
          # via an env var, then referenced in args with Kubernetes' native
          # $(VAR_NAME) command substitution - no plaintext password here.
          env {
            name = "MLFLOW_BACKEND_STORE_URI"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "MLFLOW_BACKEND_STORE_URI"
              }
            }
          }

          # NEW: S3-compatible artifact store credentials (LocalStack for
          # local dev) - MLflow's boto3-based S3ArtifactRepository reads
          # MLFLOW_S3_ENDPOINT_URL/AWS_* directly from the environment.
          env {
            name = "MLFLOW_S3_ENDPOINT_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "MLFLOW_S3_ENDPOINT_URL"
              }
            }
          }
          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "AWS_ACCESS_KEY_ID"
              }
            }
          }
          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "AWS_SECRET_ACCESS_KEY"
              }
            }
          }
          env {
            name = "AWS_DEFAULT_REGION"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "AWS_DEFAULT_REGION"
              }
            }
          }

          args = [
            "mlflow", "server",
            "--host", "0.0.0.0",
            "--port", "5000",
            "--backend-store-uri", "$(MLFLOW_BACKEND_STORE_URI)",
            "--default-artifact-root", "s3://rossmann-mlflow-artifacts/mlflow-artifacts",
            "--allowed-hosts", "*"
          ]

          port {
            container_port = 5000
          }

          # Mount the persistent storage inside the container
          volume_mount {
            name       = "mlflow-storage"
            mount_path = "/mlflow"
          }
        }

        volume {
          name = "mlflow-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mlflow_data.metadata[0].name
          }
        }
      }
    }
  }
}

# 3. MLflow Internal Networking Service
resource "kubernetes_service" "mlflow" {
  metadata {
    name = "mlflow"
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "mlflow"
    }
    port {
      port        = 5000
      target_port = 5000
    }
  }
}

# NEW: Prefect Storage Claim for pipeline run history
resource "kubernetes_persistent_volume_claim" "prefect_data" {
  metadata {
    name = "prefect-data-pvc"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  wait_until_bound = false # <-- Breaks the K3s storage deadlock
}

# 4. Prefect Orchestration Server Deployment
resource "kubernetes_deployment" "prefect" {
  # CHANGED: Declare explicit dependency on Postgres before attempting configuration
  depends_on = [
    kubernetes_deployment.postgres
  ]
  # END OF CHANGE

  metadata {
    name = "prefect"
    labels = {
      app = "prefect"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "prefect"
      }
    }

    template {
      metadata {
        labels = {
          app = "prefect"
        }
      }

      spec {
        container {
          name  = "prefect"
          # CHANGED: Swap original upstream image with custom local driver image
          image = "rossmann-prefect:latest"
          # END OF CHANGE
          image_pull_policy = "IfNotPresent"
          
          args = ["prefect", "server", "start", "--host", "0.0.0.0"]

          env {
            name = "PREFECT_API_DATABASE_CONNECTION_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "PREFECT_DB_URL"
              }
            }
          }

          port {
            container_port = 4200
          }

          # NEW: Mount the storage claim to the default Prefect database location
          volume_mount {
            name       = "prefect-storage"
            mount_path = "/root/.prefect"
          }
        }

        # NEW: Link the volume to K3s local storage
        volume {
          name = "prefect-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prefect_data.metadata[0].name
          }
        }
      }
    }
  }
}

# 5. Prefect Internal Networking Service
resource "kubernetes_service" "prefect" {
  metadata {
    name = "prefect"
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "prefect"
    }
    port {
      port        = 4200
      target_port = 4200
    }
  }
}

#Step 4: The FastAPI Core Application Layer.
# 1. FastAPI Application Deployment
resource "kubernetes_deployment" "api" {
  depends_on = [
    kubernetes_deployment.postgres,
    kubernetes_deployment.redis,
    kubernetes_deployment.mlflow,
    kubernetes_deployment.prefect,
  ]

  metadata {
    name = "rossmann-api"
    labels = {
      app = "rossmann-api"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "rossmann-api"
      }
    }

    template {
      metadata {
        labels = {
          app = "rossmann-api"
        }
      }

      spec {
        container {
          name  = "rossmann-api"
          image = "rossmann-api:latest"
          
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 8000
          }

          # Injected environment configurations matching your project requirements
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "API_DATABASE_URL"
              }
            }
          }
          env {
            name  = "MODEL_URI"
            value = "models:/Rossmann_XGBoost_Model/latest"
          }
          env {
            name  = "MLFLOW_TRACKING_URI"
            value = "http://mlflow:5000"
          }
          env {
            name  = "PREFECT_API_URL"
            value = "http://prefect:4200/api"
          }
          env {
            name  = "WATCHFILES_FORCE_POLLING"
            value = "true"
          }

          # NEW: raw (not pre-composed) Postgres creds - feature_repo/feature_store.yaml's
          # ${POSTGRES_USER}/${POSTGRES_PASSWORD} placeholders get substituted from these
          # by docker/entrypoint.sh at boot (Feast has no native env-var substitution).
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_credentials.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          # NEW: same S3/LocalStack credentials as MLflow - mlflow.pyfunc.load_model()
          # resolves a models:/... URI into a real s3://... artifact path via the
          # tracking server, then downloads it client-side using these.
          env {
            name = "MLFLOW_S3_ENDPOINT_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "MLFLOW_S3_ENDPOINT_URL"
              }
            }
          }
          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "AWS_ACCESS_KEY_ID"
              }
            }
          }
          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "AWS_SECRET_ACCESS_KEY"
              }
            }
          }
          env {
            name = "AWS_DEFAULT_REGION"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.s3_credentials.metadata[0].name
                key  = "AWS_DEFAULT_REGION"
              }
            }
          }

          # Mount the shared MLflow volume so the API can read the model artifacts
          volume_mount {
            name       = "mlflow-storage"
            mount_path = "/mlflow"
          }
        }

        # Link to the exact same PVC used by the MLflow tracking server
        volume {
          name = "mlflow-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mlflow_data.metadata[0].name
          }
        }
      }
    }
  }
}

# 2. External Networking Service (Exposing the API to your local machine)
resource "kubernetes_service" "api" {
  metadata {
    name = "rossmann-api-service"
  }
  spec {
    type = "LoadBalancer"
    
    selector = {
      app = "rossmann-api"
    }
    
    port {
      port        = 8000
      target_port = 8000
    }
  }
}

#Step 5: Ingress + TLS in front of the Kubernetes services.
# NEW: Every Service above stays `type: LoadBalancer` exactly as it was
# (nothing here changes an existing port-forward/URL from the README or the
# deploy scripts) - this section layers a single HTTPS front door on top,
# using K3s' built-in Traefik ingress controller, which needs no extra
# install step on a stock K3s cluster.

# 1. A self-signed certificate. Good enough to get real TLS termination in
# front of the cluster for a local demo; swap for a cert-manager-issued or
# CA-signed certificate for anything beyond that.
resource "tls_private_key" "ingress" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ingress" {
  private_key_pem = tls_private_key.ingress.private_key_pem

  subject {
    common_name  = "rossmann.local"
    organization = "Rossmann MLOps Demo"
  }

  validity_period_hours = 8760 # 1 year
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [
    "rossmann.local",
    "api.rossmann.local",
    "mlflow.rossmann.local",
    "prefect.rossmann.local",
  ]
}

# 2. The cert/key pair as a real Kubernetes TLS Secret, referenced by the
# Ingress below.
resource "kubernetes_secret" "ingress_tls" {
  metadata {
    name = "rossmann-ingress-tls"
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.ingress.cert_pem
    "tls.key" = tls_private_key.ingress.private_key_pem
  }
}

# 3. One Ingress, three name-based virtual hosts - the API, the MLflow UI,
# and the Prefect UI all terminate TLS at the same entry point instead of
# each needing its own externally-exposed port.
resource "kubernetes_ingress_v1" "rossmann" {
  depends_on = [
    kubernetes_service.api,
    kubernetes_service.mlflow,
    kubernetes_service.prefect,
  ]

  metadata {
    name = "rossmann-ingress"
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = ["api.rossmann.local", "mlflow.rossmann.local", "prefect.rossmann.local"]
      secret_name = kubernetes_secret.ingress_tls.metadata[0].name
    }

    rule {
      host = "api.rossmann.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.api.metadata[0].name
              port { number = 8000 }
            }
          }
        }
      }
    }

    rule {
      host = "mlflow.rossmann.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.mlflow.metadata[0].name
              port { number = 5000 }
            }
          }
        }
      }
    }

    rule {
      host = "prefect.rossmann.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.prefect.metadata[0].name
              port { number = 4200 }
            }
          }
        }
      }
    }
  }
}