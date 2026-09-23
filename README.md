# tflab

A Terraform lab that builds Azure infrastructure and ships a container to it, entirely through GitHub Actions. Every infrastructure change is planned on a pull request, reviewed, and applied on merge after an approval. Every application release is an image tagged with the commit that produced it. Nothing in the chain stores an Azure password, key or certificate — the pipeline authenticates with OIDC workload identity federation, and the app pulls its image with a managed identity.

## What this repository builds

Everything lands in the `rg-tflab-dev` resource group (South Africa North), tagged from `local.common_tags` in `main.tf`.

| Resource | Name | Purpose |
|---|---|---|
| Container registry | `crtflab<suffix>` | Holds application images. Admin user **disabled**. |
| Container Apps environment | `cae-tflab-dev` | Runtime for the app; logs go to the workspace below. |
| Container app | `ca-tflab-app` | The running application, public HTTPS ingress, scales to zero. |
| User-assigned identity | `id-tflab-app` | Worn by the container app. Holds **AcrPull on the registry only**. |
| Log Analytics workspace | `log-tflab-dev` | Container Apps logs, 30-day retention. |
| Storage account | `sttflab<suffix>` | Left from an earlier exercise; no application uses it. |
| Random string | `random_string.suffix` | Six characters, makes the globally-unique names unique. |

`terraform output app_url` prints the application's address.

## What this repository does **not** manage

These were created by hand and are deliberately outside Terraform. The pipeline's permissions are scoped to `rg-tflab-dev`, so Terraform must not be able to destroy the things that grant it those permissions or hold its state. **Do not add them to the configuration.**

| Resource | Created by |
|---|---|
| `rg-tfstate`, storage account `sttfstateahdgal`, container `tfstate` (versioning + 30-day soft delete) | `bootstrap/00-state-backend.sh` |
| Resource group `rg-tflab-dev`, tagged `ManagedBy=bootstrap` | `bootstrap/00-state-backend.sh` |
| Registered resource providers: `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.OperationalInsights`, `Microsoft.Storage` | `bootstrap/01-providers.sh` |
| Entra app registration `gh-tflab`, its service principal, and three federated credentials — `gh-tflab-pr`, `gh-tflab-main`, `gh-tflab-env-prod` | `bootstrap/02-federated-credentials.sh` |
| Role assignments for `gh-tflab`: **Contributor** on `rg-tflab-dev`, **Storage Blob Data Contributor** on `sttfstateahdgal`, and **Role Based Access Control Administrator** on `rg-tflab-dev` *conditioned so it can only grant or revoke AcrPull* | `bootstrap/03-rbac-delegation.sh` |
| Repository secrets, the `production` environment with a required reviewer, the `ACR_NAME` variable | `bootstrap/04-github-config.sh` |
| The branch ruleset on `main` | By hand, in Settings → Rules |

See `bootstrap/README.md` for the order to run them in. `terraform destroy` leaves all of the above standing.

Why the conditioned RBAC grant exists: Terraform must assign AcrPull to `id-tflab-app`, and Contributor cannot create role assignments. The condition means the pipeline can grant that one role and nothing else — not Owner, not Contributor, not to itself.

## Running a plan locally

You need Terraform 1.16.1, the Azure CLI, and **Storage Blob Data Contributor** on `sttfstateahdgal`. Owner of the subscription is not enough: reading the state blob is a data-plane permission.

```bash
az login
az account show            # confirm the right subscription
terraform init
terraform plan
```

Locally Terraform uses your own `az login`; in the pipeline it uses OIDC. The same code covers both — the workflows set `ARM_USE_OIDC`, and nothing sets it on your machine.

Plan locally as often as you like. **Apply through the pipeline.** A local apply skips review and leaves no record of who changed what.

## What happens when you open a pull request

1. **Terraform Plan** (`.github/workflows/terraform-plan.yml`) runs `fmt -check`, `init`, `validate` and `plan`, and posts the plan as a comment — including when the plan fails, so the error is visible without opening logs.
2. **Infracost** (a GitHub App, not a workflow) comments the cost change and any policy findings. Advisory; it does not block the merge.
3. Read the plan comment before merging. Check the summary line first: a non-zero **destroy** count, or any `-/+`, deserves a full read.

On merge, **Terraform Apply** (`terraform-apply.yml`) runs against `main` in the `production` environment, so it **waits for a reviewer to approve it** before anything changes in Azure. One apply runs at a time; the rest queue.

**Terraform Destroy** (`terraform-destroy.yml`) is manual only. Run it from the Actions tab, or:

```bash
gh workflow run terraform-destroy.yml -f confirm=destroy
```

It refuses unless the confirmation input is exactly `destroy`, and it still waits for approval.

## Releasing the application

`.github/workflows/app.yml` runs when anything under `app/` changes on `main`.

1. **build** — logs in to the registry and pushes `tflab-app:<commit-sha>`. Runs automatically.
2. **deploy** — `az containerapp update --image …`, in the `production` environment, so it **waits for approval**.

Images are tagged with the full commit SHA, never `latest`, so what is running is always traceable to one commit. The page the app serves prints its own build SHA.

**To roll back**, deploy an older image. No rebuild is involved:

```bash
git log --format='%H %s' -10
gh workflow run app.yml -f tag=<full-40-character-sha>
```

Approve it, and the previous version is live in about a minute.

### Terraform does not own the running image

`azurerm_container_app.app` has:

```hcl
lifecycle {
  ignore_changes = [template[0].container[0].image]
}
```

Terraform creates the app with a placeholder image and never touches that field again. Without this, a Terraform apply would revert whatever the app pipeline last deployed — quietly, with a plan summary reading `1 to change`.

**Terraform owns the platform. The app pipeline owns what runs on it.** If you ever want Terraform to own the image instead, remove the block *and* change `app.yml` to pass the tag to Terraform. Do not do half of it.

## If something fails

Owner: **Jurgens le Roux** ([@JurgensleRoux](https://github.com/JurgensleRoux)). Open an issue with a link to the failed run.

First, read the failed step:

```bash
gh run list --limit 5
gh run view <run-id> --log-failed
```

If `--log-failed` prints nothing, no step ran — the workflow file itself was rejected. Look at the run's **annotations** instead (`gh run view <run-id>`).

| Error | Cause |
|---|---|
| `AADSTS700213` | The OIDC subject GitHub sent matches no federated credential. The message quotes the subject; compare it with the three in Entra. Declaring an `environment` changes the subject. |
| An `ARM_*` variable blank in the log | A workflow references a secret or variable name that doesn't exist. Set values show as `***`; blank means not found. Compare against `gh secret list` and `gh variable list`. |
| `403` on the state blob | `gh-tflab` is missing Storage Blob Data Contributor on `sttfstateahdgal`. |
| `state blob is already locked` | Another run holds the lease, or one died holding it. Wait. Only `terraform force-unlock` when certain nothing else is running. |
| `ResourceGroupNotFound` | `rg-tflab-dev` was deleted. Re-run `bootstrap/00-state-backend.sh`; don't add it to Terraform. |
| `MissingSubscriptionRegistration` | A resource provider isn't registered. Re-run `bootstrap/01-providers.sh`. |
| `AuthorizationFailed` on `roleAssignments/write` | Either the conditioned RBAC Administrator grant is missing, or Terraform is trying to assign a role other than AcrPull — in which case the condition is correctly refusing. |
| `unauthorized: authentication required` on push | `az acr login` didn't run, or `vars.ACR_NAME` is blank. |
| Revision fails, image pull unauthorized | `id-tflab-app` lacks AcrPull, or the `registry` block doesn't name it. A new assignment can take a few minutes to take effect. |

A failed apply can leave Azure partly changed. Run a fresh plan before retrying, and read what it proposes.

## Repository layout

```
app/                     the container image (Dockerfile)
bootstrap/               what Terraform cannot create for itself
.github/workflows/       plan, apply, destroy, app release
main.tf                  resource group data source, tags, storage account
platform.tf              registry, identity, Container Apps environment and app
backend.tf               remote state configuration
```

`.github/workflows/hello.yml` is a scratch workflow from setting Actions up. Safe to delete.
