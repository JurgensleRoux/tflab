#!/usr/bin/env bash
#
# Registers the Azure resource providers this lab needs.
# Registration is subscription-wide and cannot be done by the pipeline
# identity, which is scoped to a single resource group.
#
# Run as: any rights on the subscription.
# Run when: setting up a new subscription.
# Safe to run more than once.

set -euo pipefail
source "$(dirname "$0")/config.sh"

SUB=$(az account show --query id -o tsv)
: "${SUB:?no subscription selected - run az login}"
echo "subscription=$SUB"

NAMESPACES=(
  Microsoft.App                  # Container Apps
  Microsoft.ContainerRegistry    # ACR
  Microsoft.OperationalInsights  # Log Analytics
  Microsoft.Storage              # state backend + lab storage
)

for ns in "${NAMESPACES[@]}"; do
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv)
  if [ "$state" = "Registered" ]; then
    echo "==> $ns already registered"
  else
    echo "==> registering $ns (this can take a few minutes)"
    az provider register --namespace "$ns" --wait
  fi
done

echo
az provider list \
  --query "[?contains(['Microsoft.App','Microsoft.ContainerRegistry','Microsoft.OperationalInsights','Microsoft.Storage'], namespace)].{namespace:namespace, state:registrationState}" \
  -o table
