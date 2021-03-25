
terraform {
  backend "azurerm" {
  }
}
variable "resource_group_name" {
  default = "mhc-rg"
  description = "The name of the resource group"
}

variable "location" {
  type    = string
  default = "uksouth"
}

variable "log_analytics_name" {
  default = "log-analytics-mhc"
  description = "The name of the log analytics workspace"
}

# SSH Public Key for Linux VMs
variable "ssh_public_key" {
  default = "C:/Users/hass/.ssh/mhc/ask-akssshkey.pub"
  description = "This variable defines the SSH Public Key for Linux k8s Worker nodes"  
}

# Datasource to get Latest Azure AKS latest Version
data "azurerm_kubernetes_service_versions" "current" {
  location = var.location
  include_preview = false
}

resource "random_integer" "random_suffix" {
  min = 1000
  max = 9999
}

locals {
  full_rg_name = "ask-${terraform.workspace}-${var.resource_group_name}"
  full_log_analy_name = "ask-${terraform.workspace}-${var.log_analytics_name}"
  full_acr_name = "ask${terraform.workspace}"
}

resource "azurerm_resource_group" "mhc" {
  name     = local.full_rg_name
  location = var.location

  tags = {
    environment = terraform.workspace
  }
}

# Create Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "insights" {
  name                = "${local.full_log_analy_name}-workspace01"
  location            = var.location
  resource_group_name = azurerm_resource_group.mhc.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  depends_on = [local.full_rg_name]

   tags = {
    environment = terraform.workspace
  }
}

# Create Azure AD Group in Active Directory for AKS Admins
resource "azuread_group" "aks_administrators" {
  display_name        = "${local.full_rg_name}-ask-cluster-administrators"
  description = "Azure AKS Kubernetes administrators for the ${local.full_rg_name}-cluster01."
}

# Create Virtual Network
resource "azurerm_virtual_network" "aksvnet" {
  name                = "${local.full_rg_name}-aks-network"
  location            = var.location
  resource_group_name = azurerm_resource_group.mhc.name
  address_space       = ["10.0.0.0/8"]
  tags = {
    environment = terraform.workspace
  }
}

# Create a Subnet for AKS
resource "azurerm_subnet" "aks-default" {
  name                 = "${local.full_rg_name}-aks-default-subnet"
  virtual_network_name = azurerm_virtual_network.aksvnet.name
  resource_group_name  = azurerm_resource_group.mhc.name
  address_prefixes       = ["10.240.0.0/24"]
}
# Provision AKS Cluster
resource "azurerm_kubernetes_cluster" "aks_cluster" {
  name                = "${local.full_rg_name}-cluster01"
  location            = var.location
  resource_group_name = azurerm_resource_group.mhc.name
  dns_prefix          = "${local.full_rg_name}-cluster01"
  kubernetes_version  = data.azurerm_kubernetes_service_versions.current.latest_version
  node_resource_group = "${local.full_rg_name}-nrg"

  default_node_pool {
    name                 = "systempool"
    vm_size              = "Standard_DS2_v2"
    orchestrator_version = data.azurerm_kubernetes_service_versions.current.latest_version
    availability_zones   = [1, 2, 3]
    enable_auto_scaling  = true
    max_count            = 3
    min_count            = 1
    os_disk_size_gb      = 30
    type                 = "VirtualMachineScaleSets"
    vnet_subnet_id        = azurerm_subnet.aks-default.id 
    node_labels = {
      "nodepool-type"    = "system"
      "environment"      = "dev"
      "nodepoolos"       = "linux"
      "app"              = "system-apps" 
    } 
   tags = {
      "nodepool-type"    = "system"
      "environment"      = terraform.workspace
      "nodepoolos"       = "linux"
      "app"              = "system-apps" 
   } 
  }
  # Identity (System Assigned or Service Principal)
  identity {
    type = "SystemAssigned"
  }

# Add On Profiles
  addon_profile {
    azure_policy {enabled =  true}
    oms_agent {
      enabled =  true
      log_analytics_workspace_id = azurerm_log_analytics_workspace.insights.id
    }
  }

# RBAC and Azure AD Integration Block
  role_based_access_control {
    enabled = true
    azure_active_directory {
      managed = true
      admin_group_object_ids = [azuread_group.aks_administrators.id]
    }
  }

# Linux Profile
  linux_profile {
    admin_username = "ubuntu"
    ssh_key {
      key_data = file(var.ssh_public_key)
    }
  }

# Network Profile
  network_profile {
    network_plugin = "azure"
    load_balancer_sku = "Standard"
  }

  }
  
# Create Linux Azure AKS Node Pool
resource "azurerm_kubernetes_cluster_node_pool" "linux101" {
  availability_zones    = [1, 2, 3]
  enable_auto_scaling   = true
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks_cluster.id
  max_count             = 3
  min_count             = 1
  mode                  = "User"
  name                  = "linux101"
  orchestrator_version  = data.azurerm_kubernetes_service_versions.current.latest_version
  os_disk_size_gb       = 30
  os_type               = "Linux" # Default is Linux, we can change to Windows
  vm_size               = "Standard_DS2_v2"
  priority              = "Regular"  # Default is Regular, we can change to Spot with additional settings like eviction_policy, spot_max_price, node_labels and node_taints
  vnet_subnet_id        = azurerm_subnet.aks-default.id 
  node_labels = {
    "nodepool-type" = "user"
    "environment"   = terraform.workspace
    "nodepoolos"    = "linux"
    "app"           = "asp.net"
  }
  tags = {
    "nodepool-type" = "user"
    "environment"   = terraform.workspace
    "nodepoolos"    = "linux"
    "app"           = "asp.net"
  }
}

#Create Azure Container registry
resource "azurerm_container_registry" "acr" {
  name                = "${local.full_acr_name}acr01"
  resource_group_name = azurerm_resource_group.mhc.name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = true

  tags = {
    environment = terraform.workspace
  }
}

# add the role to the identity the kubernetes cluster was assigned
resource "azurerm_role_assignment" "aks_cluster" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks_cluster.kubelet_identity[0].object_id
}
# Create Public IP address
resource "azurerm_public_ip" "MHCIP" {
  name                = "${local.full_rg_name}PubIp1"
  resource_group_name = azurerm_resource_group.mhc.name
  location            = var.location
  allocation_method   = "Static"
  sku		              = "Standard"

  tags = {
    environment = terraform.workspace
  }
}
# Provide admin role to aks cluster admins
resource "azurerm_role_assignment" "aks_cluster_admin_role" {
  scope                = azurerm_kubernetes_cluster.aks_cluster.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_group.aks_administrators.object_id
}

output "public_ip" {
  value       = "${azurerm_public_ip.MHCIP.name.ip_address}"
  description = "Azure Public IP Address"
}
