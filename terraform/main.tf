terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

data "azurerm_resource_group" "core" {
  name = var.core_resource_group
}

data "azurerm_container_app_environment" "env" {
  name                = var.core_env_name
  resource_group_name = data.azurerm_resource_group.core.name
}

data "azurerm_container_registry" "acr" {
  name                = var.core_acr_name
  resource_group_name = data.azurerm_resource_group.core.name
}

data "azurerm_postgresql_flexible_server" "postgres" {
  name                = var.core_postgres_name
  resource_group_name = data.azurerm_resource_group.core.name
}

data "azurerm_user_assigned_identity" "aca_identity" {
  name                = "aca-identity"
  resource_group_name = data.azurerm_resource_group.core.name
}

resource "azurerm_container_app" "moodle_app" {
  name                         = "moodle-app"
  container_app_environment_id = data.azurerm_container_app_environment.env.id
  resource_group_name          = data.azurerm_resource_group.core.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.aca_identity.id]
  }

  registry {
    server   = data.azurerm_container_registry.acr.login_server
    identity = data.azurerm_user_assigned_identity.aca_identity.id
  }

  ingress {
    external_enabled = true
    target_port      = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    container {
      name   = "moodle"
      image  = "${data.azurerm_container_registry.acr.login_server}/moodle:${var.image_tag}"
      cpu    = 2
      memory = "4Gi"

      env {
        name  = "DB_HOST"
        value = data.azurerm_postgresql_flexible_server.postgres.fqdn
      }
      env {
        name  = "DB_TYPE"
        value = "pgsql"
      }
      env {
        name  = "DB_NAME"
        value = var.db_name
      }
      env {
        name  = "DB_USER"
        value = var.db_user
      }
      env {
        name  = "DB_PASS"
        value = var.db_password
      }
      env {
        name  = "MOODLE_URL"
        value = var.moodle_public_url
      }
      env {
        name  = "CODE_CACHE_DIR"
        value = "/tmp/sitecode"
      }
      env {
        name  = "PLUGIN_CACHE_ROOT"
        value = "/tmp/plugincode"
      }
      env {
        name  = "MOODLE_EXTRA_PHP"
        value = <<EOF
$$CFG->sslproxy = true;
$$CFG->tracksessionip = false;
$$CFG->reverseproxy = true;
$$CFG->session_handler_class = '\\core\\session\\database';
$$CFG->session_database_acquire_lock_timeout = 120;
EOF
      }

      volume_mounts {
        name = "moodle-volume"
        path = "/var/www/moodledata"
      }
    }

    volume {
      name         = "moodle-volume"
      storage_name = "moodle-storage"
      storage_type = "AzureFile"
    }

    min_replicas = 1
    max_replicas = 1
  }
}
