terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {}

# ─────────────────────────────────────────
# Variables
# ─────────────────────────────────────────
variable "subscription_id" {
  description = "Your Azure subscription ID"
  type        = string
}

variable "location" {
  default = "westeurope"
}

variable "prefix" {
  default = "triage"
}

variable "image_tag" {
  description = "Container image tag to deploy"
  default     = "latest"
}

# ─────────────────────────────────────────
# Resource Group
# ─────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.prefix}-demo"
  location = var.location
  tags = {
    session = "BRK221"
    event   = "MSBuildLocalhost2026"
  }
}

# ─────────────────────────────────────────
# Container Registry
# ─────────────────────────────────────────
resource "azurerm_container_registry" "acr" {
  name                = "acr${var.prefix}${substr(md5(azurerm_resource_group.rg.id), 0, 6)}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# ─────────────────────────────────────────
# Log Analytics + Application Insights
# ─────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${var.prefix}-demo"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "ai" {
  name                = "ai-${var.prefix}-demo"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}

# ─────────────────────────────────────────
# Azure AI Foundry (OpenAI)
# ─────────────────────────────────────────
resource "azurerm_cognitive_account" "openai" {
  name                = "oai-${var.prefix}-demo"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "eastus" # GPT-4.1 mini widely available here
  kind                = "OpenAI"
  sku_name            = "S0"

  custom_subdomain_name = "oai-${var.prefix}-demo"
}

resource "azurerm_cognitive_deployment" "gpt4o_mini" {
  name                 = "GPT-4.1-mini"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "GPT-4.1-mini"
    version = "2024-07-18"
  }

  sku {
    name     = "Standard"
    capacity = 30 # 30K TPM — enough for demo, prevents runaway costs
  }
}

# ─────────────────────────────────────────
# ACA Environment
# ─────────────────────────────────────────
resource "azurerm_container_app_environment" "env" {
  name                       = "cae-${var.prefix}-demo"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

# ─────────────────────────────────────────
# ACA Managed OpenTelemetry (Application Insights)
# ─────────────────────────────────────────
resource "azapi_update_resource" "otel_config" {
  type        = "Microsoft.App/managedEnvironments@2024-03-01"
  resource_id = azurerm_container_app_environment.env.id

  body = {
    properties = {
      openTelemetryConfiguration = {
        tracesConfiguration = {
          destinations = ["appInsights"]
        }
        logsConfiguration = {
          destinations = ["appInsights"]
        }
      }
      appInsightsConfiguration = {
        connectionString = azurerm_application_insights.ai.connection_string
      }
    }
  }
}

# ─────────────────────────────────────────
# Container App
# ─────────────────────────────────────────
resource "azurerm_container_app" "app" {
  name                         = "ca-${var.prefix}-demo"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "openai-api-key"
    value = azurerm_cognitive_account.openai.primary_access_key
  }

  template {
    min_replicas = 0
    max_replicas = 10

    container {
      name   = "triage-agent"
      image  = "${azurerm_container_registry.acr.login_server}/email-triage-agent:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "AZURE_OPENAI_API_KEY"
        secret_name = "openai-api-key"
      }

      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = azurerm_cognitive_account.openai.endpoint
      }

      env {
        name  = "AZURE_OPENAI_DEPLOYMENT"
        value = azurerm_cognitive_deployment.gpt4o_mini.name
      }

      liveness_probe {
        path      = "/health"
        port      = 8000
        transport = "HTTP"
      }
    }

    # KEDA HTTP scale rule — scale out under load, scale to zero when idle
    http_scale_rule {
      name                = "http-scaler"
      concurrent_requests = "10"
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [azapi_update_resource.otel_config]
}

# ─────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────
output "app_url" {
  value       = "https://${azurerm_container_app.app.ingress[0].fqdn}"
  description = "Live URL of the Smart Inbox Triage Agent"
}

output "app_insights_url" {
  value       = "https://portal.azure.com/#resource${azurerm_application_insights.ai.id}/overview"
  description = "Application Insights dashboard"
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server for docker push"
}

output "openai_endpoint" {
  value       = azurerm_cognitive_account.openai.endpoint
  description = "Azure OpenAI endpoint"
}
