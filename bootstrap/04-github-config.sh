#!/usr/bin/env bash
#
# Configures the GitHub repository side of the pipeline:
#   - AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID as secrets
#   - the production environment, with you as a required reviewer
#   - ACR_NAME as a repository variable, read from Terraform's output
#
# None of the three IDs is a credential; they are stored as secrets by
# convention and to keep them out of the public diff. ACR_NAME is a variable
# because it is configuration: unmasked in logs, which makes debugging easier.
#
# Run as: any user with admin on the repository.
# Requires: gh, authenticated.
# Safe to run more than once.

set -euo pipefail
source "$(dirname "$0")/config.sh"

APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUB=$(az account show --query id -o tsv)
: "${APP_ID:?app registration $APP_DISPLAY_NAME not found - run 02 first}"
: "${TENANT_ID:?could not read the tenant id}"
: "${SUB:?no subscription selected - run az login}"

echo "==> secrets"
gh secret set AZURE_CLIENT_ID       --repo "$GITHUB_REPO" --body "$APP_ID"
gh secret set AZURE_TENANT_ID       --repo "$GITHUB_REPO" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$GITHUB_REPO" --body "$SUB"

echo "==> $GH_ENVIRONMENT environment with required reviewer"
# Required reviewers need a public repository, or GitHub Enterprise for a
# private one. On a private repo this call will fail; that is a plan limit,
# not a bug in this script.
MY_ID=$(gh api user --jq .id)
gh api -X PUT "repos/$GITHUB_REPO/environments/$GH_ENVIRONMENT" \
  --input - <<JSON >/dev/null
{"reviewers":[{"type":"User","id":$MY_ID}]}
JSON

echo "==> ACR_NAME variable"
ACR_NAME=$(terraform -chdir="$(dirname "$0")/.." output -raw acr_name 2>/dev/null || true)
if [ -n "$ACR_NAME" ]; then
  gh variable set ACR_NAME --repo "$GITHUB_REPO" --body "$ACR_NAME"
  echo "    set to $ACR_NAME"
else
  echo "    skipped - no acr_name output yet. Re-run this script after the"
  echo "    first successful apply, or set it by hand:"
  echo "      gh variable set ACR_NAME --body \"\$(terraform output -raw acr_name)\""
fi

echo
gh secret list --repo "$GITHUB_REPO"
gh variable list --repo "$GITHUB_REPO"

echo
echo "Not automated here: the branch ruleset on main (require a pull request,"
echo "require the 'plan' status check). Set that in Settings > Rules."
