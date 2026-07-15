#Step 1: The Core Provider Configuration
terraform {
  required_version = ">= 1.0.0"
  
  # 1. Declare that we need the Kubernetes engine manager
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24.0" 
    }
  }
}

# 2. Point Terraform directly to your K3s cluster credentials
provider "kubernetes" {
  config_path = "${path.module}/k3s.yaml"
}

#Step 2: The PostgreSQL & Redis Backend
# 1. ConfigMap to hold your database structure script
resource "kubernetes_config_map" "postgres_init" {
  metadata {
    name = "postgres-init-config"
  }

  data = {
    # ADDED: Include create-databases.sql so it mounts in the init folder
    "create-databases.sql" = file("${path.module}/../create-databases.sql")
    # END OF CHANGE
    "init.sql" = file("${path.module}/../init.sql")
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
            name  = "POSTGRES_USER"
            value = "user"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = "Password"
          }
          env {
            name  = "POSTGRES_DB"
            value = "rossmann"
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
          
          args = [
            "mlflow", "server",
            "--host", "0.0.0.0",
            "--port", "5000",
            # CHANGED: Point backend-store-uri to the 'mlflow' database instead of 'rossmann'
            "--backend-store-uri", "postgresql://user:Password@postgres:5432/mlflow",
            # END OF CHANGE
            "--default-artifact-root", "/mlflow/artifacts",
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
            name  = "PREFECT_API_DATABASE_CONNECTION_URL"
            # CHANGED: Point the connection URL to the 'prefect' database instead of 'rossmann'
            value = "postgresql+asyncpg://user:Password@postgres:5432/prefect"
            # END OF CHANGE
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
            name  = "DATABASE_URL"
            value = "postgresql://user:Password@postgres:5432/rossmann"
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