# Azurerm provider configuration
provider "azurerm" {
  features {}
}

data "azurerm_network_security_group" "example" {
  name                = "nsg_mgnt_subnet_in"
  resource_group_name = "shared-eus2-001-rg"
}

data "azurerm_log_analytics_workspace" "example" {
  name                = "shared-eus2-001-law"
  resource_group_name = "shared-eus2-001-rg"
}

module "virtual-machine" {
  source  = "ravensorb/azure-virtual-machine/azurerm"
  version = "1.0.0"

  # A prefix to use for all resouyrces created (if left blank, the resource group name will be used)
  resource_prefix     = "shared-eus2-001"

  # Resource Group, location, VNet and Subnet details
  resource_group_name  = "shared-eus2-001-rg"
  location             = "eastus2"
  virtual_network_name = "hub-eus2-001-vnet"
  subnet_name          = "snet-management"
  virtual_machine_name = "vm-linux"

  # This module support multiple Pre-Defined Linux and Windows Distributions.
  # Check the README.md file for more pre-defined images for Ubuntu, Centos, RedHat.
  # Please make sure to use gen2 images supported VM sizes if you use gen2 distributions
  # Specify `disable_password_authentication = false` to create random admin password
  # Specify a valid password with `admin_password` argument to use your own password 
  # To generate SSH key pair, specify `generate_admin_ssh_key = true`
  # To use existing key pair, specify `admin_ssh_key_data` to a valid SSH public key path.  
  os_flavor               = "linux"
  linux_distribution_name = "ubuntu2004"
  virtual_machine_size    = "Standard_B2s"
  generate_admin_ssh_key  = true
  instances_count         = 2

  # Proxymity placement group, Availability Set and adding Public IP to VM's are optional.
  # remove these argument from module if you dont want to use it.  
  enable_proximity_placement_group = true
  enable_vm_availability_set       = true
  enable_public_ip_address         = true

  # Network Seurity group port allow definitions for each Virtual Machine
  # NSG association to be added automatically for all network interfaces.
  # Remove this NSG rules block, if `existing_network_security_group_id` is specified
  existing_network_security_group_id = data.azurerm_network_security_group.example.id

  # Boot diagnostics to troubleshoot virtual machines, by default uses managed 
  # To use custom storage account, specify `storage_account_name` with a valid name
  # Passing a `null` value will utilize a Managed Storage Account to store Boot Diagnostics
  enable_boot_diagnostics = true

  # Attach a managed data disk to a Windows/Linux VM's. Possible Storage account type are: 
  # `Standard_LRS`, `StandardSSD_ZRS`, `Premium_LRS`, `Premium_ZRS`, `StandardSSD_LRS`
  # or `UltraSSD_LRS` (UltraSSD_LRS only available in a region that support availability zones)
  # Initialize a new data disk - you need to connect to the VM and run diskmanagemnet or fdisk
  data_disks = [
    {
      name                 = "disk1"
      disk_size_gb         = 100
      storage_account_type = "StandardSSD_LRS"
    },
    {
      name                 = "disk2"
      disk_size_gb         = 200
      storage_account_type = "Standard_LRS"
    }
  ]

  # (Optional) To enable Azure Monitoring and install log analytics agents
  # (Optional) Specify `storage_account_name` to save monitoring logs to storage.   
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.example.id

  # Deploy log analytics agents to virtual machine. 
  # Log analytics workspace customer id and primary shared key required.
  deploy_log_analytics_agent                 = true
  log_analytics_customer_id                  = data.azurerm_log_analytics_workspace.example.workspace_id
  log_analytics_workspace_primary_shared_key = data.azurerm_log_analytics_workspace.example.primary_shared_key

  # Adding additional TAG's to your Azure resources
  tags = {
    CreatedBy   = "Shawn Anderson"
    CreatedOn   = "2022/05/20"
    CostCenter  = "IT"
    Environment = "PROD"
    Critical    = "YES"
    Location    = "eastus2"
    Solution    = "filesync"
    ServiceClass = "Gold"
  }
}