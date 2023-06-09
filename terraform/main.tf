terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.53.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "1.5.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

locals {
  la_name = "la${var.unique}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  gh_repo = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-EUS"
  resource_group_name = "DefaultResourceGroup-EUS"
} 

data "azurerm_resource_group" "rg" {
  name = "rg-logicapp-infra-${var.environment}-${var.unique}-${local.loc_for_naming}"
}

data "azurerm_storage_share" "share" {
  name                 = "la-${local.la_name}-content"
  storage_account_name = "sa${local.la_name}"
}

data "azurerm_logic_app_standard" "example" {
  name                = "la-${local.la_name}"
  resource_group_name = data.azurerm_resource_group.rg.name
}

data "azurerm_eventhub_namespace" "ehn" {
  name                = "ehn${local.la_name}${var.environment}"
  resource_group_name = data.azurerm_resource_group.rg.name
}


data "azurerm_eventhub" "eh" {
  name                = "eh${local.la_name}${var.environment}"
  resource_group_name = data.azurerm_resource_group.rg.name
  namespace_name      = data.azurerm_eventhub_namespace.ehn.name
}



data "azapi_resource" "appsettings" {
  type                   = "Microsoft.Web/sites/config@2022-03-01"
  parent_id              = data.azurerm_logic_app_standard.example.id
  name                   = "appsettings"
  response_export_values = ["*"]
}


data "azapi_resource_action" "list" {
  type                   = "Microsoft.Web/sites/config@2022-03-01"
  resource_id            = data.azapi_resource.appsettings.id
  action                 = "list"
  method                 = "POST"
  response_export_values = ["*"]
}

resource "azapi_resource_action" "update" {
  type        = "Microsoft.Web/sites/config@2022-03-01"
  resource_id = data.azapi_resource.appsettings.id
  method      = "PUT"
  body = jsonencode({
    name = "appsettings"
    // use merge function to combine new settings with existing ones
    properties = merge(
      jsondecode(data.azapi_resource_action.list.output).properties,
      {
        "eventHub_fullyQualifiedNamespace" = "ehn${local.la_name}${var.environment}.servicebus.windows.net"
        "eventHub_name" = "eh${local.la_name}${var.environment}"
        "AzureCosmosDB_connectionString" = "@Microsoft.KeyVault(VaultName=kv-${local.la_name};SecretName=cosmosdbconn)"
        "cosmosdb_containerId" = local.la_name 
        "cosmosdb_databaseId" = "sql${local.la_name}" 
      }
    )
  })
  response_export_values = ["*"]
}

output "resourcegrouptags" {
  value = data.azurerm_resource_group.rg.tags
}

resource "azurerm_storage_share_file" "example" {
  name             = "connections.json"
  path             = "site/wwwroot"
  storage_share_id = data.azurerm_storage_share.share.id
  source           = "../workflows/connections.json"
  content_md5      = filemd5("../workflows/connections.json")
}

resource "azurerm_storage_share_directory" "workflows" {
  for_each = fileset("../workflows", "**/workflow.json")
  name             = "site/wwwroot/${split("/", each.value)[0]}"
  storage_account_name = data.azurerm_storage_share.share.storage_account_name
  share_name = data.azurerm_storage_share.share.name
}

resource "azurerm_storage_share_file" "workflows" {
  depends_on = [
    azurerm_storage_share_directory.workflows
  ]
  for_each = fileset("../workflows", "**/workflow.json")
  name             = "workflow.json"
  path             = "site/wwwroot/${split("/", each.value)[0]}"
  storage_share_id = data.azurerm_storage_share.share.id
  source           = "../workflows/${each.value}"
  content_md5      = filemd5("../workflows/${each.value}")
}