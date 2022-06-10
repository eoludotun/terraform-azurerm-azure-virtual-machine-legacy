locals {
  resource_group_name = element(coalescelist(data.azurerm_resource_group.rgrp[*].name, azurerm_resource_group.rg[*].name, [""]), 0)
  resource_prefix     = var.resource_prefix == "" ? local.resource_group_name : var.resource_prefix
  location            = element(coalescelist(data.azurerm_resource_group.rgrp[*].location, azurerm_resource_group.rg[*].location, [""]), 0)
  
  network_interfaces = { 
    for idx, network_interface in var.network_interfaces : network_interface.name => {
    idx : idx,
    network_interface : network_interface,
    }
  }

  routes = { 
    for idx, route in var.routes : route.name => {
    idx : idx,
    route : route,
    }
  }

  vm_data_disks = { for idx, data_disk in var.data_disks : data_disk.name => {
    idx : idx,
    data_disk : data_disk,
    }
  }

  timeout_create  = "45m"
  timeout_update  = "15m"
  timeout_delete  = "15m"
  timeout_read    = "15m"
}

#---------------------------------------------------------------
# Generates SSH2 key Pair for Linux VM's (Dev Environment only)
#---------------------------------------------------------------
resource "tls_private_key" "rsa" {
  count     = var.generate_admin_ssh_key ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

#---------------------------------------------------------
# Resource Group Creation or selection - Default is "true"
#----------------------------------------------------------
data "azurerm_resource_group" "rgrp" {
  count = var.create_resource_group == false ? 1 : 0
  name  = var.resource_group_name
}

resource "azurerm_resource_group" "rg" {
  count    = var.create_resource_group ? 1 : 0
  name     = lower(var.resource_group_name)
  location = var.location
  tags     = merge({ "ResourceName" = format("%s", var.resource_group_name) }, var.tags, )

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }
}

#--------------------------------------
# azurerm monitoring diagnostics 
#--------------------------------------
data "azurerm_log_analytics_workspace" "logws" {
  count               = var.log_analytics_workspace_name != null ? 1 : 0
  name                = var.log_analytics_workspace_name
  resource_group_name = var.log_analytics_workspace_resouce_group_name
}

resource "azurerm_log_analytics_workspace" "logws" {
  count               = var.log_analytics_workspace_name == null ? 1 : 0
  name                = lower("${local.resource_prefix}-logaws")
  resource_group_name = element(coalescelist(data.azurerm_storage_account.storeacc.*.resource_group_name, azurerm_storage_account.storeacc.*.resource_group_name, [""]), 0) 
  location            = local.location
  sku                 = var.log_analytics_workspace_sku
  retention_in_days   = var.log_analytics_logs_retention_in_days
  tags                = merge({ "ResourceName" = lower("${local.resource_prefix}-logaws") }, var.tags, )
}

#----------------------------------------------------------
# Random Resources
#----------------------------------------------------------

resource "random_password" "passwd" {
  count       = (var.os_flavor == "linux" && var.disable_password_authentication == false && var.admin_password == null ? 1 : (var.os_flavor == "windows" && var.admin_password == null ? 1 : 0))
  length      = var.random_password_length
  min_upper   = 4
  min_lower   = 2
  min_numeric = 4
  special     = false

  keepers = {
    admin_password = var.virtual_machine_name
  }
}

#-----------------------------------------------
# Storage Account for Disk Storage and Logs
#-----------------------------------------------
data "azurerm_resource_group" "storeacc_rg" {
  count = var.storage_account_resource_group_name != null ? 1 : 0
  name  = var.storage_account_resource_group_name 
}

data "azurerm_storage_account" "storeacc" {
  count               = var.create_storage_account == false ? 1 : 0
  name                = var.storage_account_name
  resource_group_name = var.storage_account_resource_group_name != null ? var.storage_account_resource_group_name : local.resource_group_name
}

resource "azurerm_storage_account" "storeacc" {
  count                     = var.create_storage_account ? 1 : 0
  name                      = format("%sst%s", lower(replace(local.resource_prefix, "/[[:^alnum:]]/", "")), lower(replace(var.storage_account_name, "/[[:^alnum:]]/", "")))
  resource_group_name       = var.storage_account_resource_group_name != null ? var.storage_account_resource_group_name : local.resource_group_name
  location                  = local.location
  account_kind              = "StorageV2"
  account_tier              = var.storage_account_tier_type
  account_replication_type  = var.storage_account_replication_type
  enable_https_traffic_only = true
  tags                      = merge({ "ResourceName" = format("%sst%s", lower(replace(local.resource_prefix, "/[[:^alnum:]]/", "")), lower(replace(var.storage_account_name, "/[[:^alnum:]]/", ""))) }, var.tags, )

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }

}

#----------------------------------------------------------
# Subnet Resources
#----------------------------------------------------------

data "azurerm_subnet" "snet" {
  for_each             = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.subnet_name != null, false) }
  name                 = each.value.network_interface.subnet_name
  virtual_network_name = var.virtual_network_name
  resource_group_name  = var.virtual_network_resource_group_name == null ? local.resource_group_name : var.virtual_network_resource_group_name
}

#-----------------------------------
# Public IP for Virtual Machine
#-----------------------------------

data "azurerm_public_ip" "pip" {
  for_each                      = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.public_ip.create == false, false) }
  name                          = each.key
  resource_group_name           = local.resource_group_name
}

resource "azurerm_public_ip" "pip" {
  for_each              = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.public_ip.create, false) }
  name                  = lower("${local.resource_prefix}-${var.virtual_machine_name}-pip-vm-${each.key}")
  resource_group_name   = local.resource_group_name
  location              = var.location
  allocation_method     = try(each.value.network_interface.public_ip.allocation_method, "Static")
  sku                   = try(each.value.network_interface.public_ip.sku, "Standard")
  sku_tier              = try(each.value.network_interface.public_ip.sku_tier, "Regional")
  domain_name_label     = try(each.value.network_interface.public_ip.domain_label, null)
  public_ip_prefix_id   = try(each.value.network_interface.public_ip.prefix_id, null)

  tags                  = merge({ "ResourceName" = lower("${local.resource_prefix}-${var.virtual_machine_name}-pip-vm-${each.key}-0${each.value.idx + 1}") }, var.tags, )

  lifecycle {
    ignore_changes = [
      tags,
      ip_tags,
    ]
  }

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }

}

#---------------------------------------
# Network Interface for Virtual Machine
#---------------------------------------

resource "azurerm_network_interface" "nic" {
  for_each                      = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.private_ip != null, false) }
  name                          = each.key
  resource_group_name           = local.resource_group_name
  location                      = var.location
  dns_servers                   = try(each.value.network_interface.dns_servers, null)
  enable_ip_forwarding          = try(each.value.network_interface.enable_ip_forwarding, false)
  enable_accelerated_networking = try(each.value.network_interface.enable_accelerated_networking, false)
  internal_dns_name_label       = try(each.value.network_interface.internal_dns_name_label, null)

  tags                          = merge({ "ResourceName" = lower("${local.resource_prefix}-vm-${var.virtual_machine_name}-nic-${each.key}") }, var.tags, )

  ip_configuration {
    name                          = lower("${local.resource_prefix}-vm-${var.virtual_machine_name}-nic-${each.key}-ipconfig")
    primary                       = try(each.value.network_interface.primary, true)
    subnet_id                     = data.azurerm_subnet.snet[each.key].id
    private_ip_address_allocation = try(each.value.network_interface.private_ip.address_allocation_type, null)
    private_ip_address            = try(each.value.network_interface.private_ip.address_allocation_type == "Static", false) ? try(each.value.network_interface.private_ip.address, null) : null
    public_ip_address_id          = can(each.value.network_interface.public_ip) ? (each.value.network_interface.public_ip.create ? azurerm_public_ip.pip[each.key].id : data.azurerm_public_ip.pip[each.key].id) : null    
  }

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
  
  depends_on = [
    data.azurerm_subnet.snet
  ]

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }

}

#---------------------------------------------------------------
# Network security group for Virtual Machine Network Interface
#---------------------------------------------------------------

data "azurerm_network_security_group" "nsg" {
  for_each              = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.network_security_group_name != null, false) }
  name                  = each.value.network_interface.network_security_group_name
  resource_group_name   = each.value.network_interface.network_security_resource_group_name
}

resource "azurerm_network_security_group" "nsg" {
  for_each            = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.network_security_group_name == null, false) }
  name                = lower("${local.resource_prefix}-nsg-${each.key}")
  resource_group_name = local.resource_group_name
  location            = local.location
  tags                = merge({ "ResourceName" = lower("${local.resource_prefix}-nsg-${each.key}") }, var.tags, )

  dynamic "security_rule" {
    for_each = concat(lookup(each.value.network_interface, "nsg_inbound_rules", []), lookup(each.value.network_interface, "nsg_outbound_rules", []))
    content {
      name                       = security_rule.value[0] == "" ? "Default_Rule" : security_rule.value[0]
      priority                   = security_rule.value[1]
      direction                  = security_rule.value[2] == "" ? "Inbound" : security_rule.value[2]
      access                     = security_rule.value[3] == "" ? "Allow" : security_rule.value[3]
      protocol                   = security_rule.value[4] == "" ? "Tcp" : security_rule.value[4]
      source_port_range          = "*"
      destination_port_range     = security_rule.value[5] == "" ? "*" : security_rule.value[5]
      source_address_prefix      = security_rule.value[6] == "" ? "Internet" : security_rule.value[6]
      destination_address_prefix = security_rule.value[7] == "" ? "VirtualNetwork" : security_rule.value[7] 
      description                = security_rule.value[8] == "" ? "${security_rule.value[2]}_Port_${security_rule.value[5]}" : security_rule.value[8]
    }
  }

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg-assoc-new" {
  for_each                  = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.subnet_name != null, false) && try(v.network_interface.network_security_group_name == null, false) }
  subnet_id                 = data.azurerm_subnet.snet[each.key].id
  network_security_group_id = azurerm_network_security_group.nsg[each.key].id

  depends_on = [
    data.azurerm_subnet.snet
  ]

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg-assoc-existing" {
  for_each                  = { for k, v in local.network_interfaces : k => v if k != null && try(v.network_interface.subnet_name != null, false) && try(v.network_interface.network_security_group_name != null, false) }
  subnet_id                 = data.azurerm_subnet.snet[each.key].id
  network_security_group_id = data.azurerm_network_security_group.nsg[each.key].id

  depends_on = [
    data.azurerm_subnet.snet
  ]

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }
  
}

#---------------------------------------------------------------
# Network security group for Virtual Machine Network Interface
#---------------------------------------------------------------

data "azurerm_route_table" "rtout" {
  count               = var.route_table_name != null ? 1 : 0
  name                = var.route_table_name
  resource_group_name = var.route_table_resource_group_name != null ? var.route_table_resource_group_name : local.resource_group_name
}

resource "azurerm_route" "rt" {
  for_each               = local.routes
  name                   = lower("${local.resource_prefix}-route-${each.key}")
  resource_group_name    = data.azurerm_route_table.rtout.0.resource_group_name
  route_table_name       = data.azurerm_route_table.rtout.0.name
  address_prefix         = lookup(each.value.route, "address_prefix", "0.0.0.0/0")
  next_hop_type          = lookup(each.value.route, "next_hop_type", "VirtualAppliance")
  next_hop_in_ip_address = azurerm_network_interface.nic[each.value.route.nic_name].private_ip_address

  depends_on = [
    azurerm_network_interface.nic
  ]
}

#----------------------------------------------------------------------------------------------------
# Proximity placement group for virtual machines, virtual machine scale sets and availability sets.
#----------------------------------------------------------------------------------------------------
resource "azurerm_proximity_placement_group" "appgrp" {
  count               = var.enable_proximity_placement_group ? 1 : 0
  name                = lower("${local.resource_prefix}-vm-${var.virtual_machine_name}-proxigrp")
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = merge({ "ResourceName" = lower("${local.resource_prefix}-vm-${var.virtual_machine_name}-proxigrp") }, var.tags, )

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

#-----------------------------------------------------
# Manages an Availability Set for Virtual Machines.
#-----------------------------------------------------
resource "azurerm_availability_set" "aset" {
  count                        = var.enable_vm_availability_set ? 1 : 0
  name                         = lower("${local.resource_prefix}-${var.virtual_machine_name}-avail")
  resource_group_name          = local.resource_group_name
  location                     = var.location
  platform_fault_domain_count  = var.platform_fault_domain_count
  platform_update_domain_count = var.platform_update_domain_count
  proximity_placement_group_id = var.enable_proximity_placement_group ? azurerm_proximity_placement_group.appgrp.0.id : null
  managed                      = true
  tags                         = merge({ "ResourceName" = lower("${local.resource_prefix}-${var.virtual_machine_name}-avail") }, var.tags, )

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

#---------------------------------------
# Linux Virutal machine
#---------------------------------------

# resource "azurerm_marketplace_agreement" "vm" {
#   count = var.accept_marketplace_agreement ? 1 : 0

#   plan      = var.custom_image != null ? var.custom_image.sku : var.linux_distribution_list[lower(var.linux_distribution_name)]["sku"]
#   offer   = var.custom_image != null ? var.custom_image.offer : var.linux_distribution_list[lower(var.linux_distribution_name)]["offer"]
#   publisher = var.custom_image != null ? var.custom_image.publisher : var.linux_distribution_list[lower(var.linux_distribution_name)]["publisher"]
# }

resource "azurerm_virtual_machine" "linux_vm" {
  count                           = var.os_flavor == "linux" ? var.instances_count : 0
  name                            = substr(format("%s-vm-%s-%s", lower(replace(local.resource_prefix, "/[[:^alnum:]]/", "")), lower(replace(var.virtual_machine_name, "/[[:^alnum:]]/", "")), count.index + 1), 0, 64)

  resource_group_name             = local.resource_group_name
  location                        = var.location
  network_interface_ids           = values(azurerm_network_interface.nic).*.id
  vm_size                         = var.virtual_machine_size
  availability_set_id             = var.enable_vm_availability_set == true ? element(concat(azurerm_availability_set.aset[*].id, [""]), 0) : null
  primary_network_interface_id    = values(azurerm_network_interface.nic).0.id
  proximity_placement_group_id    = var.enable_proximity_placement_group ? azurerm_proximity_placement_group.appgrp.0.id : null

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  # delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  # delete_data_disks_on_termination = true

  # license_type = null "Windows_Client"/"Windows_Server"

  zones                           = var.vm_availability_zone != null && var.vm_availability_zone != "" ? [var.vm_availability_zone] : null
  tags                            = merge({ "ResourceName" = format("%s-vm-%s-%s", lower(replace(local.resource_prefix, "/[[:^alnum:]]/", "")), lower(replace(var.virtual_machine_name, "/[[:^alnum:]]/", "")), count.index + 1) }, var.tags, )

  os_profile {
    computer_name  = substr(format("%s-vm-%s-%s", lower(replace(local.resource_prefix, "/[[:^alnum:]]/", "")), lower(replace(var.virtual_machine_name, "/[[:^alnum:]]/", "")), count.index + 1), 0, 64)
    admin_username = var.admin_username
    admin_password = var.disable_password_authentication == false && var.admin_password == null ? element(concat(random_password.passwd[*].result, [""]), 0) : var.admin_password    
    custom_data    = var.custom_data != null ? var.custom_data : null
  }

  dynamic "os_profile_linux_config" {
    for_each = var.os_flavor == "linux" ? [1] : [0]

    content {
      disable_password_authentication = var.disable_password_authentication
      ssh_keys {
        key_data  = var.admin_ssh_key_data == null ? tls_private_key.rsa[0].public_key_openssh : file(var.admin_ssh_key_data)
        path      = "/home/{username}/.ssh/authorized_keys."
      }
    }
  }

  # dynamic "os_profile_windows_config" {
  #   for_each = var.os_flavor == "windows" ? [1] : [0]

  #   content {
  #     enable_automatic_upgrades = var.enable_automatic_updates
  #     timezone                  = var.vm_time_zone
  #   }
  # }

  dynamic "plan" {
    for_each = var.accept_marketplace_agreement ? [1] : [0]

    content {
      name      = var.custom_image != null ? var.custom_image.sku : var.linux_distribution_list[lower(var.linux_distribution_name)]["sku"]
      product   = var.custom_image != null ? var.custom_image.offer : var.linux_distribution_list[lower(var.linux_distribution_name)]["offer"]
      publisher = var.custom_image != null ? var.custom_image.publisher : var.linux_distribution_list[lower(var.linux_distribution_name)]["publisher"]
    }
  }

  dynamic "storage_image_reference" {
    for_each = var.source_image_id != null ? [] : [1]

    content {
      id        = var.source_image_id != null ? var.source_image_id : null
      publisher = var.custom_image != null ? var.custom_image.publisher : var.linux_distribution_list[lower(var.linux_distribution_name)]["publisher"]
      offer     = var.custom_image != null ? var.custom_image.offer : var.linux_distribution_list[lower(var.linux_distribution_name)]["offer"]
      sku       = var.custom_image != null ? var.custom_image.sku : var.linux_distribution_list[lower(var.linux_distribution_name)]["sku"]
      version   = var.custom_image != null ? var.custom_image.version : var.linux_distribution_list[lower(var.linux_distribution_name)]["version"]
    }
  }

  storage_os_disk {
    name                      = "${local.resource_prefix}-${var.virtual_machine_name}-osdisk"
    create_option             = "FromImage"
    caching                   = var.os_disk_caching
    disk_size_gb              = var.disk_size_gb
    os_type                   = "Linux"
    write_accelerator_enabled = var.enable_os_disk_write_accelerator
    managed_disk_type         = var.os_disk_storage_account_type
  }

  dynamic "storage_data_disk" {
    for_each = local.vm_data_disks
    
    content {
      name                      = "${local.resource_prefix}-${var.virtual_machine_name}-datadisk-${storage_data_disk.value.idx}"
      caching                   = var.os_disk_caching
      create_option             = "FromImage"
      disk_size_gb              = storage_data_disk.value.data_disk.disk_size_gb
      lun                       = storage_data_disk.value.idx
      write_accelerator_enabled = var.enable_os_disk_write_accelerator
      managed_disk_type         = lookup(storage_data_disk.value.data_disk, "storage_account_type", "StandardSSD_LRS")
    }
  }

  dynamic "boot_diagnostics" {
    for_each = var.enable_boot_diagnostics ? [1] : []
    content {
      enabled     = var.enable_boot_diagnostics
      storage_uri = var.create_storage_account ? azurerm_storage_account.storeacc.0.primary_blob_endpoint : data.azurerm_storage_account.storeacc.0.primary_blob_endpoint
    }
  }

  additional_capabilities {
    ultra_ssd_enabled = var.enable_ultra_ssd_data_disk_storage_support
  }

  dynamic "identity" {
    for_each = var.managed_identity_type != null ? [1] : []
    content {
      type         = var.managed_identity_type
      identity_ids = var.managed_identity_type == "UserAssigned" || var.managed_identity_type == "SystemAssigned, UserAssigned" ? var.managed_identity_ids : null
    }
  }

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }
}

#--------------------------------------------------------------
# Azure Log Analytics Workspace Agent Installation for Linux
#--------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "omsagentlinux" {
  count                      = var.deploy_log_analytics_agent && var.os_flavor == "linux" ? var.instances_count : 0
  name                       = var.instances_count == 1 ? "OmsAgentForLinux" : format("%s%s", "OmsAgentForLinux", count.index + 1)
  virtual_machine_id         = azurerm_virtual_machine.linux_vm[count.index].id
  publisher                  = "Microsoft.EnterpriseCloud.Monitoring"
  type                       = "OmsAgentForLinux"
  type_handler_version       = "1.13"
  auto_upgrade_minor_version = true

  settings = <<SETTINGS
    {
      "workspaceId": "${element(coalescelist(data.azurerm_log_analytics_workspace.logws.*.workspace_id, azurerm_log_analytics_workspace.logws.*.workspace_id, [""]), 0)}"
    }
  SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
    "workspaceKey": "${element(coalescelist(data.azurerm_log_analytics_workspace.logws.*.primary_shared_key, azurerm_log_analytics_workspace.logws.*.primary_shared_key, [""]), 0)}"
    }
  PROTECTED_SETTINGS

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }

}

#--------------------------------------
# monitoring diagnostics 
#--------------------------------------
resource "azurerm_monitor_diagnostic_setting" "nsg" {
  for_each                    = { for k, v in local.network_interfaces : k => v if k != null && var.log_analytics_workspace_name != null }
  name                        = lower("${local.resource_prefix}-${var.virtual_machine_name}-nsg-diag-${ each.value.idx + 1}")
  target_resource_id          = can(azurerm_network_security_group.nsg[each.key].id) ? azurerm_network_security_group.nsg[each.key].id : data.azurerm_network_security_group.nsg[each.key].id
  storage_account_id          = var.log_analytics_workspace_storage_account_id != null ? var.log_analytics_workspace_storage_account_id : null
  log_analytics_workspace_id  = element(coalescelist(data.azurerm_log_analytics_workspace.logws.*.id, azurerm_log_analytics_workspace.logws.*.id, [""]), 0) 

  dynamic "log" {
    for_each = var.nsg_diag_logs
    content {
      category = log.value
      enabled  = true

      retention_policy {
        enabled = false
        days    = 0
      }
    }
  }

  depends_on = [
    azurerm_network_security_group.nsg
  ]

  timeouts {
    create = local.timeout_create
    update = local.timeout_update
    read   = local.timeout_read
    delete = local.timeout_delete
  }
}
