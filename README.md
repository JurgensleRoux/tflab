# tflab

A learning repository for Terraform on Azure, driven entirely through GitHub Actions with
OIDC — no service principal secrets, no local applies against shared state.

One module, two environments, two state files, one pipeline.

---

## Layout

```
.
├── .github/workflows/
│   ├── terraform-plan.yml      # plan both environments on every pull request
│   ├── terraform-apply.yml     # apply dev on merge, then promote to prod
│   ├── terraform-destroy.yml   # manual teardown  ⚠ see "Known issues"
│   └── app.yml                 # build, push and deploy the container image
├── bootstrap/                  # everything Terraform does NOT own (see bootstrap/README.md)
│   ├── config.sh               # the only file with names and IDs in it
│   ├── 00-state-backend.sh
│   ├── 01-providers.sh
│   ├── 02-federated-credentials.sh
│   ├── 03-rbac-delegation.sh
│   └── 04-github-config.sh
├── envs/
│   ├── dev/main.tf             # backend + provider + one module call
│   └── prod/main.tf            # same, different values
└── modules/platform/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

There are **no `.tf` files in the repository root**. Every Terraform command needs a
directory:

```bash
terraform -chdir=envs/dev plan
```

A workflow step that forgets `working-directory` fails with
`terraform: no configuration files` — that is what it means.

---

## The two environments

Each directory under `envs/` is a **root**: its own backend, its own state file, its own
lock. They differ by about six lines.

| | dev | prod |
|---|---|---|
| Resource group | `rg-tflab-dev` | `rg-tflab-prod` |
| State key | `tflab.dev.tfstate` | `tflab.prod.tfstate` |
| Region | `southafricanorth` | `southafricanorth` |
| `min_replicas` | `0` (scales to zero) | `1` (no cold starts) |
| `log_retention_days` | `30` | `60` |
| `cost_centre` | `lab` | `platform` |
| `enable_container_app` | `true` | `false` — see [Known issues](#known-issues) |

> **The `key` line is the dangerous one.** Two roots sharing a state key share a state
> file, and the second apply proposes to destroy the first environment's resources. If a
> plan ever lists the other environment's resources, check `key` before anything else.
> `grep -n 'key ' envs/*/main.tf` is the whole check.

### Why directories and not workspaces

Workspaces share one backend configuration and one set of provider settings, and the
active workspace is invisible in the code. A wrong `terraform workspace select` looks
identical to a right one. Directories put the difference in a file you can read in a pull
request.

---

## The module

`modules/platform` builds one environment's worth of platform:

| Resource | Notes |
|---|---|
| `random_string.suffix` | Lives **inside** the module, so each caller gets its own — registry names are globally unique. |
| `azurerm_container_registry` | `cr<workload><environment><suffix>`, Basic, admin disabled. |
| `azurerm_log_analytics_workspace` | `log-<workload>-<environment>`. |
| `azurerm_user_assigned_identity` | The identity the container app pulls images with. |
| `azurerm_role_assignment` | `AcrPull` for that identity on that registry. |
| `azurerm_container_app_environment` | `count = var.enable_container_app ? 1 : 0` |
| `azurerm_container_app` | Same `count`. |

The resource group is **read, not created** — `data "azurerm_resource_group"`. Resource
groups are bootstrap, because the state backend has to live somewhere before Terraform
runs at all.

### Names and region are decided once

```hcl
locals {
  name     = "${var.workload}-${var.environment}"
  suffix   = random_string.suffix.result
  location = coalesce(var.location, data.azurerm_resource_group.this.location)
  tags     = { Service = var.workload, Environment = var.environment, ... }
}
```

Every resource takes `local.location` and `local.tags`. `var.location` defaults to `null`,
so a caller that says nothing inherits the resource group's region; a caller that needs a
specific region says so. The container app has no region of its own — it inherits the
environment's.

### Inputs

| Variable | Default | Validated |
|---|---|---|
| `workload` | — | 3–10 lowercase letters/digits (it ends up in a globally unique registry name) |
| `environment` | — | must contain `dev` or `prod` |
| `resource_group_name` | — | |
| `location` | `null` | falls back to the resource group's region |
| `enable_container_app` | `true` | |
| `min_replicas` | | |
| `log_retention_days` | | |
| `cost_centre` | | |

`Invalid value for variable` at plan time is your own `validation` block working. Read the
message — you wrote it.

### Outputs

`acr_name`, `resource_group_name`, `container_app_name`, `app_url`.

The last two use `one(azurerm_container_app.app[*].name)` because the resource is counted.
`one()` returns the single element, or `null` when the list is empty — so an environment
with no app returns `null` instead of crashing on `[0]`. `app_url` additionally wraps the
interpolation in `try(...)`, because `"https://${null}"` is a hard error.

### The `moved` blocks

```hcl
moved {
  from = azurerm_container_app_environment.this
  to   = azurerm_container_app_environment.this[0]
}
```

Adding `count` renamed both resources. Without these, Terraform would destroy dev's running
app and environment and build them again. They live in the module so every caller gets
them, and a `moved` block whose source is absent from state does nothing — which is why the
same two blocks are correct for dev (rename) and prod (no-op).

**Do not delete them.** They are load-bearing for any state that predates the `count`
change.

---

## State

Azure Storage, one container, one blob per environment, locked by blob lease:

```bash
az storage blob list --account-name <state-account> --container-name tfstate \
  --auth-mode login --query "[].{name:name, size:properties.contentLength}" -o table
```

Two blobs is correct. The account name and container are recorded in `bootstrap/config.sh`.

Authentication is `use_azuread_auth = true` — no storage account keys anywhere. The identity
needs **Storage Blob Data Contributor** on the account. That is a data-plane role:
Contributor on the subscription does *not* grant it, which is why `bootstrap/03` assigns it
explicitly.

---

## Pipelines

### `terraform-plan.yml` — on pull request

Matrix over `[dev, prod]` with `fail-fast: false`, so prod's plan still runs when dev's
fails. Runs `fmt -check -recursive` from the repository root, then `validate` and `plan` per
environment, and posts each plan as a pull request comment labelled with its environment.

> The matrix names the checks `plan (dev)` and `plan (prod)`. A branch ruleset requiring a
> check called `plan` will wait forever for a job that no longer exists under that name.

### `terraform-apply.yml` — on merge to main

`dev` applies first. `prod` has `needs: dev` and its own GitHub environment, so it cannot
run until dev succeeded. Separate `concurrency` groups per environment, so a dev apply and a
prod apply never queue behind each other unnecessarily.

### `app.yml` — the application, not the platform

Takes an `environment` choice input and an optional `tag`. Builds the image, pushes it to
that environment's registry, and deploys with `az containerapp update`. Registry and app
names come from `terraform output` with `terraform_wrapper: false` — the wrapper adds
formatting that breaks `$GITHUB_OUTPUT`.

Passing a `tag` skips the build and redeploys an existing image. **That is the rollback**:
find the previous commit SHA, dispatch with it, done.

> **Terraform does not own the running image.** The module declares the quickstart image and
> then `lifecycle { ignore_changes = [template[0].container[0].image] }`. Without that, every
> `terraform apply` would roll the app back to the placeholder and undo the last deploy.
> Remove the `ignore_changes` block and the next plan shows you exactly that — it is worth
> seeing once.

With `enable_container_app = false`, an environment has no app to deploy to and
`terraform output container_app_name` returns `null`. Guard it so the failure explains
itself:

```bash
: "${APP:?no container app in this environment — enable_container_app is false}"
```

### Cost

Infracost runs as a GitHub App on pull requests rather than as workflow steps — no API key
in repository secrets, and the comment appears alongside the plan comments.

---

## Bootstrap — what Terraform does not own

Anything that must exist before Terraform can run, or that Terraform cannot grant itself,
lives in `bootstrap/` as a script. Not in a wiki, not in this file's prose, not in someone's
shell history.

| Script | What it records |
|---|---|
| `config.sh` | Subscription, resource group names, storage account, app registration, GitHub repo. **Every other script sources this.** |
| `00-state-backend.sh` | Resource groups and the state storage account, looped over `LAB_RGS`. |
| `01-providers.sh` | Resource provider registration. |
| `02-federated-credentials.sh` | The OIDC federated credentials — one per subject. |
| `03-rbac-delegation.sh` | Contributor per resource group, Storage Blob Data Contributor on the state account, and the constrained AcrPull delegation. |
| `04-github-config.sh` | Repository secrets and GitHub environments. |

Every script is idempotent and safe to re-run. They use `set -euo pipefail` and
`: "${VAR:?message}"` guards, which catch an *empty* variable as well as an unset one — an
empty `$SUB` produces `Invalid scope` fifty lines later, and the guard produces a clear
error immediately.

> **Editing a bootstrap script is not running it.** Renaming a GitHub environment changes
> the OIDC subject; if `02-federated-credentials.sh` was edited but not executed, the next
> run fails with `AADSTS700213` and the script on disk looks correct.

### OIDC

Three repository secrets — `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`. No
client secret. Check what the workflows actually reference:

```bash
grep -ho 'ARM_[A-Z_]*' .github/workflows/*.yml | sort | uniq -c
```

Three names is correct. `app.yml` uses `azure/login` rather than the Terraform provider's
environment variables, so it does not add a fourth.

Federated credential subjects must use the **numeric** owner and repository IDs
(`repo:OWNER@ID/REPO@ID:...`), not the names. Names in the subject produce `AADSTS700213`
with no hint as to why.

### The constrained role delegation

The pipeline creates a role assignment (`AcrPull` for the app identity), and **Contributor
cannot create role assignments**. Rather than granting Owner, `03-rbac-delegation.sh`
assigns **Role Based Access Control Administrator** with an ABAC condition restricting it to
assigning `AcrPull` and nothing else.

That is the whole idea: the pipeline can grant exactly the one role it needs to grant, and
cannot grant itself anything.

---

## Known issues

**Prod has no container app.** The subscription's Container Apps quota is **one environment
for the whole subscription** — not one per region. Dev holds it. Prod therefore runs with
`enable_container_app = false`, which gives it a registry, a workspace, an identity and the
AcrPull assignment, and a green apply.

The error to recognise is `MaxNumberOfGlobalEnvironmentsInSubExceeded`. Its near-twin
`MaxNumberOfRegionalEnvironmentsInSubExceeded` is a *per-region* cap that another region
does fix — read which one you got before changing anything.

When the quota request is approved, prod gets its app by flipping that one variable to
`true`. Nothing else changes.

**`terraform-destroy.yml` references `environment: production`**, which no longer exists —
the GitHub environments are `dev` and `prod`. It is `workflow_dispatch` only, so it cannot
break a normal run, but it needs the same treatment `app.yml` got (an `environment` choice
input and `working-directory: envs/${{ inputs.environment }}`) before teardown will work.

---

## Errors and what they mean

| What you see | What it means |
|---|---|
| `MaxNumberOfGlobalEnvironmentsInSubExceeded` | Subscription-wide Container Apps cap, commonly one. **No region change helps.** Raise the quota, or run with `enable_container_app = false`. |
| `MaxNumberOfRegionalEnvironmentsInSubExceeded` | Per-region cap. Another region fixes it — but check the global cap first. |
| `RequestDisallowedByAzure` (403) | The subscription may not deploy in that region at all. Probe with a throwaway managed identity *before* changing a `location`. |
| `InvalidResourceLocation` (409) | Azure holds a deleted resource's name in its original region, so the create half of a region change is refused — after the destroy has already run. Registries usually free their name within the hour (`az acr check-name -n NAME`). A Log Analytics workspace is soft-deleted for 14 days: recover it (`workspace create` in its original region) then purge it (`workspace delete --force --yes`). `--force` alone does nothing, because there is no live workspace to act on. |
| `AADSTS700213` | No federated credential for that subject. Check the numeric IDs, and check the script was *run*. |
| A plan listing the other environment's resources | Both roots point at the same state `key`. Fix the backend block, `init -reconfigure`. **Never apply it.** |
| `Module not installed` | A `module` block changed and `terraform init` did not re-run. Modules are fetched at init, like providers. |
| `Invalid value for variable` | Your own `validation` block, working. |
| `name is not available` (registry) | Registry names are globally unique. The `random_string` must live inside the module. |
| `terraform: no configuration files` | A step ran in the repository root. The root has no `.tf` files. |
| `connection reset` during `terraform init` (WSL) | MTU. Persisted at 1280 via a systemd unit; it reverts on restart otherwise. |

---

## Working on this

```bash
git switch main && git pull --prune
git switch -c my-change
# edit
terraform -chdir=envs/dev fmt
terraform -chdir=envs/dev validate
git commit -am "..."
git push -u origin my-change
gh pr create --fill
```

Read both plan comments on the pull request. A change to `envs/prod/main.tf` should appear
in prod's plan and **not** in dev's — if it appears in both, something is shared that
shouldn't be.

Direct pushes to `main` are rejected by a branch ruleset. If you have already committed
locally, move the commit to a branch rather than trying to force it:

```bash
git switch -c my-change
git switch main && git reset --hard origin/main
```

### Teardown

Destroy prod first, then dev. The Container Apps environment takes several minutes.
Log Analytics workspaces go to **soft-delete**, not away — they will show in
`az monitor log-analytics workspace list-deleted-workspaces` for 14 days, and a later
rebuild in the same region recovers them rather than colliding.

The registry is the only meaningful standing cost, so with both environments destroyed the
estate is close to free.
