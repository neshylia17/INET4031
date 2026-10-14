#!/usr/bin/env bash
# Week 5 setup: writes every file from the lab. Run from your repo ROOT.
# It does NOT run tofu, kubectl, or git commit, so your screenshots stay real.
set -euo pipefail

# Part 3: gitignore first
cat >> .gitignore << 'EOF'
week-5/terraform.tfvars
week-5/*.tfstate
week-5/*.tfstate.*
week-5/.terraform/
EOF

mkdir -p week-5
cd week-5

cat > terraform.tfvars.example << 'EOF'
postgres_user     = "replace-me"
postgres_password = "replace-me"
postgres_db       = "replace-me"
flask_secret_key  = "replace-me"
EOF

# Real values, generated for you (edit if you want different names)
PW=$(python3 -c "import secrets; print(secrets.token_hex(16))")
FK=$(python3 -c "import secrets; print(secrets.token_hex(16))")
cat > terraform.tfvars << EOF
postgres_user     = "incident_app"
postgres_password = "$PW"
postgres_db       = "incidents"
flask_secret_key  = "$FK"
EOF
chmod 600 terraform.tfvars

cat > providers.tf << 'EOF'
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
EOF

cat > variables.tf << 'EOF'
variable "postgres_user" {
  type        = string
  description = "Postgres username the app connects as"

  validation {
    condition     = var.postgres_user != "replace-me"
    error_message = "Set postgres_user in terraform.tfvars, it is still the replace-me placeholder."
  }
}

variable "postgres_password" {
  type        = string
  description = "Postgres password for that user"
  sensitive   = true

  validation {
    condition     = var.postgres_password != "replace-me" && length(var.postgres_password) >= 16
    error_message = "Set postgres_password in terraform.tfvars to a real value of at least 16 characters, not the replace-me placeholder."
  }
}

variable "postgres_db" {
  type        = string
  description = "Name of the Postgres database the app uses"

  validation {
    condition     = var.postgres_db != "replace-me"
    error_message = "Set postgres_db in terraform.tfvars, it is still the replace-me placeholder."
  }
}

variable "flask_secret_key" {
  type        = string
  description = "Secret key Flask uses to sign session cookies"
  sensitive   = true

  validation {
    condition     = var.flask_secret_key != "replace-me" && length(var.flask_secret_key) >= 16
    error_message = "Set flask_secret_key in terraform.tfvars to a real value of at least 16 characters, not the replace-me placeholder."
  }
}
EOF

cat > config.tf << 'EOF'
resource "kubernetes_config_map_v1" "app_config" {
  metadata {
    name = "app-config"
  }

  data = {
    POSTGRES_USER = var.postgres_user
    POSTGRES_DB   = var.postgres_db
  }
}

resource "kubernetes_secret_v1" "app_secrets" {
  metadata {
    name = "app-secrets"
  }

  data = {
    POSTGRES_PASSWORD = var.postgres_password
    FLASK_SECRET_KEY  = var.flask_secret_key
  }
}
EOF

cat > db.tf << 'EOF'
resource "kubernetes_persistent_volume_claim_v1" "db_data" {
  metadata {
    name = "db-data"
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  # k3s only creates the volume once a pod uses the claim, so do not wait for it to bind here.
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "db" {
  metadata {
    name   = "db"
    labels = { app = "db" }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "db" }
    }

    template {
      metadata {
        labels = { app = "db" }
      }

      spec {
        container {
          name  = "db"
          image = "postgres:16"

          port {
            container_port = 5432
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app_config.metadata[0].name
            }
          }

          env {
            name = "POSTGRES_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.app_secrets.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          volume_mount {
            name       = "db-data"
            mount_path = "/var/lib/postgresql/data"
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            }

            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 5
          }
        }

        volume {
          name = "db-data"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.db_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "db" {
  metadata {
    name = "db"
  }

  spec {
    selector = { app = "db" }

    port {
      port        = 5432
      target_port = 5432
    }
  }
}
EOF

cat > web.tf << 'EOF'
resource "kubernetes_deployment_v1" "web" {
  metadata {
    name   = "web"
    labels = { app = "web" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "web" }
    }

    template {
      metadata {
        labels = { app = "web" }
      }

      spec {
        container {
          name              = "web"
          image             = "docker.io/library/week-4-web:latest"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 5000
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app_config.metadata[0].name
            }
          }

          env {
            name = "POSTGRES_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.app_secrets.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name = "FLASK_SECRET_KEY"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.app_secrets.metadata[0].name
                key  = "FLASK_SECRET_KEY"
              }
            }
          }

          readiness_probe {
            exec {
              command = ["python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5000')"]
            }

            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }
      }
    }
  }

  # web does not reference anything from the db Deployment, so state the order explicitly.
  depends_on = [kubernetes_deployment_v1.db]
}

resource "kubernetes_service_v1" "web" {
  metadata {
    name = "web"
  }

  spec {
    selector = { app = "web" }

    port {
      port        = 8080
      target_port = 5000
    }
  }
}
EOF

cat > outputs.tf << 'EOF'
output "port_forward_command" {
  description = "Run this in a second terminal to reach the app at http://localhost:8080"
  value       = "kubectl port-forward --address 0.0.0.0 service/${kubernetes_service_v1.web.metadata[0].name} 8080:${kubernetes_service_v1.web.spec[0].port[0].port}"
}
EOF

cat > README.md << 'EOF'
# Week 5, Infrastructure as Code with OpenTofu

## What this does
Defines the Week 4 stack (Flask web app, PostgreSQL, storage, configuration, and secrets) as OpenTofu resources on a local k3s cluster.

## Requirements
- OpenTofu
- A running k3s cluster and `~/.kube/config`
- The `week-4-web:latest` image imported into k3s (see Week 4)
- A `terraform.tfvars` file in `week-5/` (copy `terraform.tfvars.example` and fill in real values)

## Deploy
```
tofu init
tofu plan
tofu apply
```

## Verify
```
kubectl get pods
tofu output -raw port_forward_command
```
Run the command it prints, then visit http://localhost:8080 in a browser.

## Tear down
```
tofu destroy
```
This deletes the database volume along with everything else.

## Known limitation
`terraform.tfstate` holds the database password and the Flask secret key in plain text. It is gitignored, not encrypted.
EOF

echo
echo "Files written in week-5/. Next (run these yourself, screenshot as you go):"
echo "  1. cd .. && git add .gitignore && git commit -m 'chore: ignore week 5 secrets and state before they exist' && git push origin master"
echo "  2. git check-ignore -v week-5/terraform.tfvars        <- screenshot"
echo "  3. Install tofu (Part 2), then cd week-5 && tofu init && tofu fmt && tofu validate"
echo "  4. Continue from Part 5 of the lab"
