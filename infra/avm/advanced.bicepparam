using './main.bicep'

// Replace the placeholder resource IDs and storage account names before deployment.
param destinationLocation = 'norwayeast'
param sourceStorageAccountName = 'stobjreplsrcadv'
param destinationStorageAccountName = 'stobjrepldstadv'
param containerCount = 5
param allowSharedKeyAccess = false
param enableMonitoring = true
param logAnalyticsWorkspaceResourceId = '/subscriptions/<subscription-id>/resourceGroups/<ops-rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'

param enableCmk = true
param keyVaultResourceId = '/subscriptions/<subscription-id>/resourceGroups/<platform-rg>/providers/Microsoft.KeyVault/vaults/<key-vault-name>'
param keyName = 'storage-cmk'
param customerManagedKeyIdentityName = 'id-objrepl-storage-cmk'

param enablePrivateEndpoints = true
param sourcePrivateEndpointSubnetResourceId = '/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<source-vnet>/subnets/<source-pe-subnet>'
param destinationPrivateEndpointSubnetResourceId = '/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/virtualNetworks/<destination-vnet>/subnets/<destination-pe-subnet>'
param blobPrivateDnsZoneResourceId = '/subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'

param tags = {
  environment: 'prod'
  deploymentTrack: 'avm-companion'
  securityZone: 'private'
  workload: 'storage-object-replication'
}
