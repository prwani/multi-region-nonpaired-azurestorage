targetScope = 'resourceGroup'

metadata name = 'AVM companion track for Azure Storage object replication'
metadata description = 'Deploys the production-oriented foundation for non-paired-region object replication, with optional monitoring, CMK, and storage private endpoints.'

@description('Primary region for the source storage account. Defaults to the resource group location.')
param sourceLocation string = resourceGroup().location

@description('Secondary region for the destination storage account.')
param destinationLocation string

@maxLength(24)
@description('Globally unique name for the source storage account.')
param sourceStorageAccountName string

@maxLength(24)
@description('Globally unique name for the destination storage account.')
param destinationStorageAccountName string

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
])
@description('Storage account SKU for both replication partners.')
param storageSkuName string = 'Standard_LRS'

@minValue(1)
@maxValue(20)
@description('Number of source and destination container pairs to create.')
param containerCount int = 5

@description('Prefix for source containers. Containers are created as <prefix>-01, <prefix>-02, ...')
param sourceContainerPrefix string = 'source'

@description('Prefix for destination containers. Containers are created as <prefix>-01, <prefix>-02, ...')
param destinationContainerPrefix string = 'dest'

@description('Whether Shared Key authentication remains enabled on the storage accounts. Keep this false for a production-style baseline; set true only if downstream tooling still needs account keys or SAS based on account keys.')
param allowSharedKeyAccess bool = false

@description('Send storage account metrics and blob service logs to Log Analytics.')
param enableMonitoring bool = true

@description('Existing Log Analytics workspace resource ID. Leave empty to create a small workspace in this resource group when monitoring is enabled.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Name for the Log Analytics workspace created when logAnalyticsWorkspaceResourceId is empty.')
param logAnalyticsWorkspaceName string = 'law-objrepl-companion'

@description('Enable customer-managed keys for both storage accounts. This companion path assumes the Key Vault and key already exist, which matches most landing-zone and platform-team ownership models.')
param enableCmk bool = false

@description('Existing Key Vault resource ID that holds the customer-managed key. Required when enableCmk is true.')
param keyVaultResourceId string = ''

@description('Existing key name in the Key Vault. Required when enableCmk is true.')
param keyName string = ''

@description('Optional key version. Leave empty to follow the latest key version through Key Vault rotation.')
param keyVersion string = ''

@description('Name of the user-assigned managed identity created for storage encryption when CMK is enabled.')
param customerManagedKeyIdentityName string = 'id-objrepl-storage-cmk'

@description('Enable storage private endpoints. This companion path assumes the target private endpoint subnets and private DNS zone already exist in your landing zone.')
param enablePrivateEndpoints bool = false

@description('Existing subnet resource ID for the source storage account private endpoint. Required when enablePrivateEndpoints is true.')
param sourcePrivateEndpointSubnetResourceId string = ''

@description('Existing subnet resource ID for the destination storage account private endpoint. Required when enablePrivateEndpoints is true.')
param destinationPrivateEndpointSubnetResourceId string = ''

@description('Existing private DNS zone resource ID for privatelink.blob.core.windows.net. Required when enablePrivateEndpoints is true.')
param blobPrivateDnsZoneResourceId string = ''

@description('Tags applied to all companion-track resources created by this template.')
param tags object = {
  deploymentTrack: 'avm-companion'
  workload: 'storage-object-replication'
}

var containerIndexes = range(1, containerCount)
var sourceContainerNames = [for index in containerIndexes: '${sourceContainerPrefix}-${padLeft(string(index), 2, '0')}']
var destinationContainerNames = [for index in containerIndexes: '${destinationContainerPrefix}-${padLeft(string(index), 2, '0')}']
var containerPairs = [for index in range(0, length(sourceContainerNames)): {
  source: sourceContainerNames[index]
  destination: destinationContainerNames[index]
}]

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (enableMonitoring && empty(logAnalyticsWorkspaceResourceId)) {
  name: logAnalyticsWorkspaceName
  location: sourceLocation
  tags: union(tags, {
    role: 'monitoring'
  })
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    retentionInDays: 30
  }
  sku: {
    name: 'PerGB2018'
  }
}

var effectiveLogAnalyticsWorkspaceResourceId = enableMonitoring
  ? (empty(logAnalyticsWorkspaceResourceId) ? logAnalyticsWorkspace.id : logAnalyticsWorkspaceResourceId)
  : ''

resource storageEncryptionIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (enableCmk) {
  name: customerManagedKeyIdentityName
  location: sourceLocation
  tags: union(tags, {
    role: 'storage-encryption-identity'
  })
}

var keyVaultSubscriptionId = !empty(keyVaultResourceId) ? split(keyVaultResourceId, '/')[2] : ''
var keyVaultResourceGroupName = !empty(keyVaultResourceId) ? split(keyVaultResourceId, '/')[4] : ''
var keyVaultName = !empty(keyVaultResourceId) ? last(split(keyVaultResourceId, '/')) : ''
var keyVaultCryptoServiceEncryptionUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'e147488a-f6f5-4113-8e2d-b22465e65bf6'
)

module keyVaultCryptoRoleAssignment 'modules/key-vault-key-role-assignment.bicep' = if (enableCmk) {
  name: 'key-vault-key-role-assignment'
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroupName)
  params: {
    keyName: keyName
    keyVaultName: keyVaultName
    principalId: storageEncryptionIdentity.properties.principalId!
    roleAssignmentName: guid('${keyVaultResourceId}/keys/${keyName}', storageEncryptionIdentity.id, keyVaultCryptoServiceEncryptionUserRoleDefinitionId)
    roleDefinitionId: keyVaultCryptoServiceEncryptionUserRoleDefinitionId
  }
}

var sourceContainers = [for containerName in sourceContainerNames: {
  name: containerName
  publicAccess: 'None'
}]

var destinationContainers = [for containerName in destinationContainerNames: {
  name: containerName
  publicAccess: 'None'
}]

var sourceAccountDiagnosticSettings = enableMonitoring
  ? [
      {
        name: take('${sourceStorageAccountName}-acct-diag', 64)
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
        workspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
      }
    ]
  : []

var destinationAccountDiagnosticSettings = enableMonitoring
  ? [
      {
        name: take('${destinationStorageAccountName}-acct-diag', 64)
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
        workspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
      }
    ]
  : []

var sourceBlobDiagnosticSettings = enableMonitoring
  ? [
      {
        name: take('${sourceStorageAccountName}-blob-diag', 64)
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
        workspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
      }
    ]
  : []

var destinationBlobDiagnosticSettings = enableMonitoring
  ? [
      {
        name: take('${destinationStorageAccountName}-blob-diag', 64)
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
        workspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
      }
    ]
  : []

var sourceBlobServices = union(
  {
    changeFeedEnabled: true
    containerDeleteRetentionPolicyDays: 7
    containerDeleteRetentionPolicyEnabled: true
    containers: sourceContainers
    deleteRetentionPolicyDays: 7
    deleteRetentionPolicyEnabled: true
    isVersioningEnabled: true
  },
  enableMonitoring ? { diagnosticSettings: sourceBlobDiagnosticSettings } : {}
)

var destinationBlobServices = union(
  {
    containerDeleteRetentionPolicyDays: 7
    containerDeleteRetentionPolicyEnabled: true
    containers: destinationContainers
    deleteRetentionPolicyDays: 7
    deleteRetentionPolicyEnabled: true
    isVersioningEnabled: true
  },
  enableMonitoring ? { diagnosticSettings: destinationBlobDiagnosticSettings } : {}
)

var sourcePrivateEndpoints = enablePrivateEndpoints
  ? [
      {
        service: 'blob'
        subnetResourceId: sourcePrivateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: blobPrivateDnsZoneResourceId
            }
          ]
        }
      }
    ]
  : []

var destinationPrivateEndpoints = enablePrivateEndpoints
  ? [
      {
        service: 'blob'
        subnetResourceId: destinationPrivateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: blobPrivateDnsZoneResourceId
            }
          ]
        }
      }
    ]
  : []

var customerManagedKeySettings = enableCmk
  ? union(
      {
        keyName: keyName
        keyVaultResourceId: keyVaultResourceId
        userAssignedIdentityResourceId: storageEncryptionIdentity.id
      },
      empty(keyVersion) ? {} : { keyVersion: keyVersion }
    )
  : {}

module sourceStorage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'source-storage-account'
  params: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    blobServices: sourceBlobServices
    customerManagedKey: enableCmk ? customerManagedKeySettings : null
    diagnosticSettings: enableMonitoring ? sourceAccountDiagnosticSettings : null
    kind: 'StorageV2'
    location: sourceLocation
    managedIdentities: enableCmk
      ? {
          userAssignedResourceIds: [
            storageEncryptionIdentity.id
          ]
        }
      : null
    minimumTlsVersion: 'TLS1_2'
    name: sourceStorageAccountName
    networkAcls: enablePrivateEndpoints
      ? {
          bypass: 'AzureServices'
          defaultAction: 'Deny'
        }
      : null
    privateEndpoints: enablePrivateEndpoints ? sourcePrivateEndpoints : null
    publicNetworkAccess: enablePrivateEndpoints ? 'Enabled' : null
    requireInfrastructureEncryption: true
    skuName: storageSkuName
    supportsHttpsTrafficOnly: true
    tags: union(tags, {
      role: 'source'
    })
  }
  dependsOn: [
    keyVaultCryptoRoleAssignment
  ]
}

module destinationStorage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'destination-storage-account'
  params: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    blobServices: destinationBlobServices
    customerManagedKey: enableCmk ? customerManagedKeySettings : null
    diagnosticSettings: enableMonitoring ? destinationAccountDiagnosticSettings : null
    kind: 'StorageV2'
    location: destinationLocation
    managedIdentities: enableCmk
      ? {
          userAssignedResourceIds: [
            storageEncryptionIdentity.id
          ]
        }
      : null
    minimumTlsVersion: 'TLS1_2'
    name: destinationStorageAccountName
    networkAcls: enablePrivateEndpoints
      ? {
          bypass: 'AzureServices'
          defaultAction: 'Deny'
        }
      : null
    privateEndpoints: enablePrivateEndpoints ? destinationPrivateEndpoints : null
    publicNetworkAccess: enablePrivateEndpoints ? 'Enabled' : null
    requireInfrastructureEncryption: true
    skuName: storageSkuName
    supportsHttpsTrafficOnly: true
    tags: union(tags, {
      role: 'destination'
    })
  }
  dependsOn: [
    keyVaultCryptoRoleAssignment
  ]
}

output sourceStorageAccountName string = sourceStorageAccountName
output sourceStorageAccountResourceId string = sourceStorage.outputs.resourceId
output sourceBlobEndpoint string = sourceStorage.outputs.primaryBlobEndpoint
output destinationStorageAccountName string = destinationStorageAccountName
output destinationStorageAccountResourceId string = destinationStorage.outputs.resourceId
output destinationBlobEndpoint string = destinationStorage.outputs.primaryBlobEndpoint
output containerPairs array = containerPairs
output logAnalyticsWorkspaceId string = effectiveLogAnalyticsWorkspaceResourceId
output customerManagedKeyIdentityResourceId string = enableCmk ? storageEncryptionIdentity.id : ''
output nextStep string = 'Run ./infra/avm/create-object-replication.sh --resource-group ${resourceGroup().name} --deployment-name <deployment-name> [--replication-mode priority] to activate object replication after the infrastructure deploy completes.'
