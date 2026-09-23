#!/usr/bin/env bash
#
# Creates the pipeline's identity in Entra ID and the trust between it and
# GitHub Actions:
#   - the gh-tflab app registration and its service principal
#   - three federated credentials, one per OIDC subject GitHub presents:
#       pull requests, pushes to main, and the production environment
#
# No password, secret or certificate is created. That is the point.
#
# Run as: any user who can create app registrations in the tenant.
# Requires: gh, authenticated (gh auth status).
# Safe to run more than once.

set -euo pipefail
source "$(dirname "$0")/config.sh"

# GitHub puts the numeric IDs of the owner and repo in the OIDC subject, so a
# deleted-and-recreated repo of the same name cannot inherit this access.
OWNER_ID=$(gh api "repos/$GITHUB_REPO" --jq .owner.id)
REPO_ID=$(gh api "repos/$GITHUB_REPO" --jq .id)
: "${OWNER_ID:?could not read the repository owner id - is gh authenticated?}"
: "${REPO_ID:?could not read the repository id}"

OWNER="${GITHUB_REPO%%/*}"
REPO="${GITHUB_REPO##*/}"
SUBJECT_PREFIX="repo:${OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}"
echo "subject prefix = $SUBJECT_PREFIX"

echo "==> app registration $APP_DISPLAY_NAME"
APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_DISPLAY_NAME" --query appId -o tsv)
  echo "    created $APP_ID"
else
  echo "    already exists: $APP_ID"
fi
: "${APP_ID:?failed to create or find the app registration}"

echo "==> service principal"
# The app registration is the definition; the service principal is the
# instance in this tenant that actually holds role assignments.
if [ -z "$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)" ]; then
  az ad sp create --id "$APP_ID" -o none
  echo "    created"
else
  echo "    already exists"
fi

add_credential() {
  local name="$1" subject="$2"
  if az ad app federated-credential list --id "$APP_ID" \
       --query "[?name=='$name'].name" -o tsv | grep -q .; then
    echo "==> $name already exists"
    return
  fi
  echo "==> creating $name"
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$name\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$subject\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
}

add_credential "gh-tflab-pr"        "${SUBJECT_PREFIX}:pull_request"
add_credential "gh-tflab-main"      "${SUBJECT_PREFIX}:ref:refs/heads/main"
add_credential "gh-tflab-env-prod"  "${SUBJECT_PREFIX}:environment:${GH_ENVIRONMENT}"

echo
az ad app federated-credential list --id "$APP_ID" \
  --query "[].{name:name, subject:subject}" -o table

echo
echo "APP_ID=$APP_ID   (04-github-config.sh stores this as AZURE_CLIENT_ID)"
