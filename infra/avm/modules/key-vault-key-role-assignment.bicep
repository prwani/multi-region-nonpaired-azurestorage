targetScope = 'resourceGroup'

@description('Existing Key Vault name.')
param keyVaultName string

@description('Existing key name inside the Key Vault.')
param keyName string

@description('Principal ID that should receive access to the key.')
param principalId string

@description('Role definition ID to assign.')
param roleDefinitionId string

@description('Deterministic GUID string used for the role assignment name.')
param roleAssignmentName string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource keyVaultKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' existing = {
  parent: keyVault
  name: keyName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleAssignmentName
  scope: keyVaultKey
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}

output roleAssignmentId string = roleAssignment.id
