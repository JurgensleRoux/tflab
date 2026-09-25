#!/usr/bin/env bash
#
# Creates the resources that Terraform cannot create for itself:
#   - rg-tfstate, the storage account and container holding Terraform state
#   - blob versioning and 30-day soft delete on that account
#   - Storage Blob Data Contributor on it for whoever runs this
#   - rg-tflab-dev, the resource group Terraform builds into
#
# Run as: Owner (or equivalent) on the subscription.
# Run when: setting this lab up for the first time, or rebuilding it.
# Safe to run more than once.

set -euo pipefail
source "$(dirname "$0")/config.sh"

SUB=$(az account show --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
: "${SUB:?no subscription selected - run az login}"
: "${ME:?could not identify the signed-in user}"
echo "subscription=$SUB  me=$ME"

echo "==> resource group $STATE_RG"
az group create --name "$STATE_RG" --location "$LOCATION" \
  --tags Service=tflab Environment=Dev ManagedBy=bootstrap -o none

echo "==> storage account $STATE_ACCOUNT"
if az storage account show -n "$STATE_ACCOUNT" -g "$STATE_RG" -o none 2>/dev/null; then
  echo "    already exists"
else
  az storage account create \
    --name "$STATE_ACCOUNT" \
    --resource-group "$STATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --tags Service=tflab Environment=Dev ManagedBy=bootstrap -o none
fi

echo "==> versioning and soft delete on $STATE_ACCOUNT"
az storage account blob-service-properties update \
  --account-name "$STATE_ACCOUNT" \
  --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 -o none

SA_ID=$(az storage account show -n "$STATE_ACCOUNT" -g "$STATE_RG" --query id -o tsv)

echo "==> Storage Blob Data Contributor for you on $STATE_ACCOUNT"
# Owner on the subscription does NOT grant data-plane access to blobs.
if az role assignment list --assignee "$ME" --scope "$SA_ID" \
     --role "Storage Blob Data Contributor" --query "[].id" -o tsv | grep -q .; then
  echo "    already assigned"
else
  az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee-object-id "$ME" --assignee-principal-type User \
    --scope "$SA_ID" -o none
  echo "    assigned - role assignments can take a minute to take effect"
fi

echo "==> container $STATE_CONTAINER"
until az storage container create \
        --name "$STATE_CONTAINER" \
        --account-name "$STATE_ACCOUNT" \
        --auth-mode login -o none 2>/dev/null; do
  echo "    waiting for the role assignment to propagate..."
  sleep 15
done

echo "==> lab resource groups"
# Deliberately NOT managed by Terraform: the pipeline's permissions are scoped
# to these groups, so Terraform must not be able to destroy them.
for rg in "${LAB_RGS[@]}"; do
  env="${rg##*-}"          # rg-tflab-dev -> dev
  az group create --name "$rg" --location "$LOCATION" \
    --tags Service=tflab Environment="$env" ManagedBy=bootstrap -o none
  echo "    $rg ($env)"
done

echo
echo "Done. backend.tf should say:"
echo "  resource_group_name  = \"$STATE_RG\""
echo "  storage_account_name = \"$STATE_ACCOUNT\""
echo "  container_name       = \"$STATE_CONTAINER\""
