#!/usr/bin/env bash
#
# Gives the pipeline identity exactly the permissions it needs, and no more:
#   - Contributor on each lab resource group (see LAB_RGS in config.sh)
#   - Storage Blob Data Contributor on the state account only
#   - Role Based Access Control Administrator on each lab resource group,
#     CONDITIONED so it may only grant or revoke AcrPull - nothing else
#
# The last one exists because Contributor cannot create role assignments, and
# Terraform needs to grant AcrPull to the Container App's managed identity.
# Without the condition, the pipeline could grant itself Owner of the group.
#
# Run as: Owner or User Access Administrator on the subscription.
# Run after: 02-federated-credentials.sh
# Safe to run more than once.

set -euo pipefail
source "$(dirname "$0")/config.sh"

SUB=$(az account show --query id -o tsv)
APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv)
: "${APP_ID:?app registration $APP_DISPLAY_NAME not found - run 02 first}"
SP=$(az ad sp show --id "$APP_ID" --query id -o tsv)
: "${SUB:?no subscription selected - run az login}"
: "${SP:?no service principal for $APP_DISPLAY_NAME - run 02 first}"

SA_ID=$(az storage account show -n "$STATE_ACCOUNT" -g "$STATE_RG" --query id -o tsv)
: "${SA_ID:?state storage account not found - run 00 first}"

echo "app=$APP_ID  sp=$SP"

assign() {
  local role="$1" scope="$2"
  if az role assignment list --assignee "$SP" --scope "$scope" \
       --role "$role" --query "[].id" -o tsv | grep -q .; then
    echo "==> '$role' already assigned at $scope"
  else
    echo "==> assigning '$role' at $scope"
    az role assignment create \
      --role "$role" \
      --assignee-object-id "$SP" --assignee-principal-type ServicePrincipal \
      --scope "$scope" -o none
  fi
}

# Two rules: it may only WRITE a role assignment whose role is AcrPull, and
# may only DELETE one whose role is AcrPull (so terraform destroy can clean up).
CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ACR_PULL_ROLE_ID}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ACR_PULL_ROLE_ID}}))"

assign_acrpull_admin() {
  local scope="$1"
  if az role assignment list --assignee "$SP" --scope "$scope" \
       --role "Role Based Access Control Administrator" --query "[].id" -o tsv | grep -q .; then
    echo "==> conditional RBAC Administrator already assigned at $scope"
  else
    echo "==> assigning conditional RBAC Administrator (AcrPull only) at $scope"
    az role assignment create \
      --role "Role Based Access Control Administrator" \
      --assignee-object-id "$SP" --assignee-principal-type ServicePrincipal \
      --scope "$scope" \
      --condition "$CONDITION" \
      --condition-version "2.0" -o none
  fi
}

# The state account is shared by both environments
assign "Storage Blob Data Contributor" "$SA_ID"

for rg in "${LAB_RGS[@]}"; do
  RG_ID="/subscriptions/$SUB/resourceGroups/$rg"
  assign "Contributor" "$RG_ID"
  assign_acrpull_admin "$RG_ID"
done

echo
az role assignment list --assignee "$SP" --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table