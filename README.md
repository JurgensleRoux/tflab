# tflab

A small Terraform lab that builds Azure infrastructure through a GitHub Actions pipeline. Every change is planned on a pull request, reviewed, and applied on merge. The pipeline authenticates to Azure with OIDC workload identity federation, so no Azure password, key or certificate is stored anywhere.

## What this repository builds

In the `rg-tflab-dev` resource group (South Africa North) it creates:

- a Standard LRS storage account named `sttflab` plus a random six-character suffix
- the `random_string` that produces that suffix

Every resource gets the tags defined in `local.common_tags` in `main.tf` (`Service`, `Environment`, `ManagedBy`, `CostCentre`).

### What this repository does not manage

Some things were created by hand, once, and are deliberately left outside Terraform. The pipeline depends on them, so it must never be able to delete them. **Do not add them to this configuration.**

| Resource | Purpose |
|---|---|
| Resource group `rg-tflab-dev` | Where the lab resources are built. Read by Terraform as a `data` source. Tagged `ManagedBy=bootstrap`. |
| Resource group `rg-tfstate`, storage account `sttfstateahdgal`, container `tfstate` | Holds the Terraform state (`tflab.dev.tfstate`). Versioning and 30-day soft delete are enabled. |
| Entra app registration `gh-tflab` | The identity the pipeline uses. It has two federated credentials: `gh-tflab-pr` (pull requests) and `gh-tflab-env-prod` (the `production` environment). |
| Role assignments for `gh-tflab` | **Contributor** on `rg-tflab-dev` only, and **Storage Blob Data Contributor** on `sttfstateahdgal` only. |

`terraform destroy` removes the lab resources and leaves all of the above in place.

## Running a plan locally

You need Terraform 1.16.1, the Azure CLI, and the **Storage Blob Data Contributor** role on `sttfstateahdgal`. Being Owner of the subscription is not enough, because reading the state blob is a data-plane permission.

```bash
az login
az account show            # confirm you're in the right subscription
terraform init
terraform plan
```

Locally, Terraform uses your own `az login` session. In the pipeline it uses OIDC. The same code handles both; nothing needs changing.

Plan locally as often as you like. **Apply through the pipeline, not from your laptop.** A local apply skips review and leaves no record of who changed what.

## What happens when you open a pull request

1. **Terraform Plan** (`.github/workflows/terraform-plan.yml`) runs `fmt -check`, `init`, `validate` and `plan`, then posts the plan as a comment on the pull request. It comments even when the plan fails, so the error is visible without opening the logs.
2. **Infracost** (a GitHub App, not a workflow) posts the monthly cost change and any policy findings. It's advisory: read it, but it doesn't block the merge.
3. Read the plan comment before merging. Check the summary line first. A non-zero **destroy** count, or any `-/+` (destroy and recreate), deserves a full read and a second opinion.

When the pull request is merged, **Terraform Apply** (`.github/workflows/terraform-apply.yml`) runs against `main`. It uses the `production` environment, so it **waits for a required reviewer to approve it** in the Actions tab before anything changes in Azure. Only one apply runs at a time; later ones queue.

## If the apply fails

Owner: **Jurgens le Roux** ([@JurgensleRoux](https://github.com/JurgensleRoux)). Open an issue on this repository with a link to the failed run.

Before you do, read the failed step:

```bash
gh run list --limit 5
gh run view <run-id> --log-failed
```

The failures seen so far, and what they mean:

| Error | Cause |
|---|---|
| `AADSTS700213` | The OIDC subject GitHub sent doesn't match a federated credential. The error message quotes the subject it sent; compare it with `gh-tflab-pr` / `gh-tflab-env-prod`. |
| An `ARM_*` variable blank in the log | A workflow references a secret name that doesn't exist. Set secrets show as `***`; blank means not found. Compare with `gh secret list`. |
| `403` reading the state blob | `gh-tflab` is missing Storage Blob Data Contributor on `sttfstateahdgal`. |
| `state blob is already locked` | Another apply is running, or one died holding the lock. Wait. Only run `terraform force-unlock` when you are certain nothing else is running. |
| `ResourceGroupNotFound` | `rg-tflab-dev` has been deleted. Recreate it by hand (see the table above); don't add it to Terraform. |

A failed apply can leave Azure partly changed. Run a fresh plan before retrying, and read what it now proposes.
