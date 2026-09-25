# Shared names for the tflab bootstrap scripts.
# Sourced by every 0*-*.sh script in this folder. Not executable on its own.
#
# If you rebuild this lab in a different subscription or repository,
# this is the only file you should need to edit.

GITHUB_REPO="JurgensleRoux/tflab"
LOCATION="southafricanorth"

# Terraform state backend
STATE_RG="rg-tfstate"
STATE_ACCOUNT="sttfstateahdgal"      # globally unique; change if you rebuild
STATE_CONTAINER="tfstate"

# Where the lab resources are built (Terraform reads these as data sources)
LAB_RGS=(rg-tflab-dev rg-tflab-prod)

# The pipeline's identity in Entra ID
APP_DISPLAY_NAME="gh-tflab"

# GitHub environments that gates applies
GH_ENVIRONMENTS=(dev prod)

# Built-in role definition IDs
ACR_PULL_ROLE_ID="7f951dda-4ed3-4680-a7ca-43fe172d538d"
