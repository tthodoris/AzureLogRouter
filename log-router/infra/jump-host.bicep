targetScope = 'resourceGroup'

param location string
param namePrefix string
param routerVnetName string
param existingJumpHostSubnetId string = ''
param jumpHostSubnetCidr string = '10.250.0.64/27'
param rdpSourceIp string
@minLength(1)
@maxLength(20)
param adminUsername string = 'routeradmin'
@secure()
param adminPassword string

var vmName = '${namePrefix}-jump'

resource routerNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: routerVnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (empty(existingJumpHostSubnetId)) {
  parent: routerNetwork
  name: 'jump-host'
  properties: {
    addressPrefix: jumpHostSubnetCidr
    defaultOutboundAccess: false
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${vmName}-ip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowOperatorRdp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '${rdpSourceIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    networkSecurityGroup: { id: nsg.id }
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: empty(existingJumpHostSubnetId) ? subnet!.id : existingJumpHostSubnetId }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v5' }
    osProfile: {
      computerName: 'router-jump'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByPlatform' }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
  }
}

output publicIpAddress string = publicIp.properties.ipAddress
output administrator string = adminUsername
