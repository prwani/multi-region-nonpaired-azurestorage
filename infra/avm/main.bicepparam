using './main.bicep'

// Update the storage account names before you deploy. They must be globally unique.
param destinationLocation = 'norwayeast'
param sourceStorageAccountName = 'stobjreplsrc001'
param destinationStorageAccountName = 'stobjrepldst001'
param containerCount = 5
param allowSharedKeyAccess = false
param enableMonitoring = true
param logAnalyticsWorkspaceName = 'law-objrepl-companion'
param tags = {
  environment: 'prod'
  deploymentTrack: 'avm-companion'
  workload: 'storage-object-replication'
}
