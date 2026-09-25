#!/usr/bin/env bash
#
# Configures the GitHub repository side of the pipeline:
#   - AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID as secrets
#   - the dev and prod environments, with a required reviewer on prod only
#
# None of the three IDs is a credential; they are stored as secrets by
# convention and to keep them out of the public diff.
#
# Registry and app names are NOT stored here. The workflows read them from
# Terraform's outputs, so they cannot drift from what was actually built.
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

echo "==> GitHub environments"
MY_ID=$(gh api user --jq .id)
: "${MY_ID:?could not read your GitHub user id}"

for env in "${GH_ENVIRONMENTS[@]}"; do
  if [ "$env" = "prod" ]; then
    # production waits for a human
    payload="{\"reviewers\":[{\"type\":\"User\",\"id\":$MY_ID}]}"
  else
    # dev applies without asking
    payload='{}'
  fi

  echo "    $env"
  printf '%s' "$payload" \
    | gh api -X PUT "repos/$GITHUB_REPO/environments/$env" --input - >/dev/null
done

echo
gh secret list --repo "$GITHUB_REPO"

echo
echo "Not automated here: the branch ruleset on main (require a pull request,"
echo "require the 'plan' status check). Set that in Settings > Rules."
