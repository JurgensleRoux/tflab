# tflab

A learning repository for Terraform on Azure, driven entirely through GitHub Actions with
OIDC — no service principal secrets, no local applies against shared state.

One module, two environments, two state files, one pipeline, and three gates that stop a
bad change for three different reasons.

---

## Layout

```
.
├── .github/workflows/
│   ├── terraform-plan.yml      # plan both environments on every pull request
│   ├── terraform-apply.yml     # apply dev on merge, then promote to prod
│   ├── terraform-destroy.yml   # manual teardown, one environment at a time
│   ├── scan.yml                # Checkov on every pull request
│   └── app.yml                 # build, push and deploy the container image
├── bootstrap/                  # everything Terraform does NOT own
│   ├── config.sh               # the only file with names and IDs in it
│   ├── 00-state-backend.sh
│   ├── 01-providers.sh
│   ├── 02-federated-credentials.sh
│   ├── 03-rbac-delegation.sh
│   └── 04-github-config.sh
├── policy/checkov/             # rules we wrote ourselves
│   ├── require_cost_centre.yaml
│   └── registry_admin_disabled.yaml
├── envs/
│   ├── dev/main.tf             # backend + provider + one module call
│   └── prod/main.tf            # same, different values
└── modules/platform/
    ├── main.tf
    ├── policy.tf
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
lock. They differ by about seven lines.

| | dev | prod |
|---|---|---|
| Resource group | `rg-tflab-dev` | `rg-tflab-prod` |
| State key | `tflab.dev.tfstate` | `tflab.prod.tfstate` |
| Region | `southafricanorth` | `southafricanorth` |
| `min_replicas` | `0` (scales to zero) | `1` (no cold starts) |
| `log_retention_days` | `30` | `60` |
| `cost_centre` | `lab` | `platform` |
| `enable_container_app` | `true` | `false` — see [Known issues](#known-issues) |
| `enforce_policy` | `true` | `false` (audit mode) |

> **The `key` line is the dangerous one.** Two roots sharing a state key share a state
> file, and the second apply proposes to destroy the first environment's resources.
> `grep -n 'key ' envs/*/main.tf` is the whole check.
>
> Tested deliberately: pointing dev at prod's key produced a plan of
> `8 to add, 6 to destroy`, reported as a **green check**. It also made both jobs in the
> plan matrix fight over one blob, so the state lock announces this mistake on its own.

### Why directories and not workspaces

Workspaces share one backend configuration and the active workspace is invisible in the
code. A wrong `terraform workspace select` looks identical to a right one. Directories put
the difference in a file you can read in a pull request.

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
| Two policy assignments | See [Rules and gates](#rules-and-gates). |

The resource group is **read, not created** — `data "azurerm_resource_group"`. Resource
groups are bootstrap, because the state backend has to exist before Terraform runs at all.

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
so a caller that says nothing inherits the resource group's region. The container app has
no region of its own — it inherits the environment's.

### Inputs

| Variable | Default | Notes |
|---|---|---|
| `workload` | — | validated: 3–10 lowercase letters/digits |
| `environment` | — | validated: must contain `dev` or `prod` |
| `resource_group_name` | — | |
| `location` | `null` | falls back to the resource group's region |
| `enable_container_app` | `true` | false where the Container Apps quota is spent |
| `enforce_policy` | `false` | false assigns policy in audit mode |
| `min_replicas` | | |
| `log_retention_days` | | |
| `cost_centre` | | ends up in every resource's tags |

`Invalid value for variable` at plan time is your own `validation` block working.

### Outputs

`acr_name`, `resource_group_name`, `container_app_name`, `app_url` — and **each root
re-exports all four**. A module's outputs are visible to its caller as
`module.platform.x`; `terraform output` only shows what the *root* declares. Forgetting
that gave the deploy pipeline two empty strings and an unhelpful error.

`container_app_name` and `app_url` use `one(azurerm_container_app.app[*]...)`, which
returns the single element or `null` when the resource is counted out. `app_url` also
wraps the interpolation in `try(...)`, because `"https://${null}"` is a hard error.

### The `moved` blocks

```hcl
moved {
  from = azurerm_container_app_environment.this
  to   = azurerm_container_app_environment.this[0]
}
```

Adding `count` renamed both resources. Without these, Terraform destroys the running app
and environment and rebuilds them. They live in the module so every caller gets them, and
a `moved` block whose source is absent from state does nothing — which is why the same two
blocks are correct for dev (rename) and prod (no-op).

**Do not delete them.** They are load-bearing for any state that predates the `count`
change.

---

## State

Azure Storage account `sttfstateahdgal` in `rg-tfstate`, one container, one blob per
environment, locked by blob lease:

```bash
az storage blob list --account-name sttfstateahdgal --container-name tfstate \
  --auth-mode login --query "[].{name:name, size:properties.contentLength}" -o table
```

Two blobs is correct. Authentication is `use_azuread_auth = true` — no storage account
keys anywhere. The identity needs **Storage Blob Data Contributor** on the account, a
data-plane role that Contributor does not grant, which is why `bootstrap/03` assigns it
explicitly.

---

## Pipelines

Every workflow that touches a state file shares a concurrency group named
`tflab-state-<environment>`, so a plan, an apply and a destroy against the same state queue
rather than collide. Without it, two pull requests planning the same environment produce
`Error acquiring the state lock`.

### `terraform-plan.yml` — on pull request

Matrix over `[dev, prod]` with `fail-fast: false`. Runs `fmt -check -recursive` from the
repository root, then `validate` and `plan` per environment, and posts each plan as a pull
request comment labelled with its environment.

> The matrix names the checks `plan (dev)` and `plan (prod)`. A branch ruleset requiring a
> check called `plan` waits forever for a job that no longer exists under that name.

### `scan.yml` — on pull request

Checkov against the whole repository, pinned to `bridgecrewio/checkov-action@v12`, with
`external_checks_dirs: policy/checkov` so our own rules run alongside the built-ins.
Results upload to GitHub code scanning as SARIF.

Two details that look like boilerplate and are not:

- `permissions: security-events: write` — without it the SARIF upload fails with
  `Resource not accessible by integration`.
- `if: success() || failure()` on the upload step — without it, findings are *not*
  uploaded on the runs where Checkov fails, which is when you want them most.

The job is named `checkov` and is a required check.

### `terraform-apply.yml` — on merge to main, or manual dispatch

`dev` applies first. `prod` has `needs: dev` and its own GitHub environment, so it cannot
run until dev succeeded. `workflow_dispatch` exists so the estate can be rebuilt from
nothing without inventing a commit.

### `terraform-destroy.yml` — manual only

Takes an `environment` choice and a `confirm` input that must **equal the environment
name**. Typing `destroy` proves you meant to destroy something; typing `prod` proves you
meant to destroy that. A mismatch skips the job rather than failing it.

### `app.yml` — the application, not the platform

Takes an `environment` choice and an optional `tag`. Builds the image, pushes it to that
environment's registry, deploys with `az containerapp update`. Names come from
`terraform output` with `terraform_wrapper: false`.

Passing a `tag` skips the build and redeploys an existing image. **That is the rollback.**

The output reads are guarded, because `echo "x=$(cmd)"` writes an empty value and exits
zero when `cmd` fails — `echo` succeeded, after all:

```bash
APP=$(terraform -chdir="envs/$ENVIRONMENT" output -raw container_app_name)
: "${APP:?container_app_name is empty — enable_container_app false, or not re-exported}"
```

`VAR=$(cmd)` carries the command's exit status; `echo "x=$(cmd)"` does not. That one
distinction is why a deploy once asked Azure to update a container app called nothing.

> **Terraform does not own the running image.** The module declares the quickstart image
> and then `lifecycle { ignore_changes = [template[0].container[0].image] }`. Without it,
> every apply would roll the app back to the placeholder and undo the last deploy.

> **Artefacts do not survive teardown.** Destroying regenerates `random_string.suffix`, so
> the registry comes back under a new name and every pushed image is gone. Infrastructure
> rebuilds from code; images do not. A real platform keeps its registry outside the
> per-environment module.

---

## Bootstrap — what Terraform does not own

Anything that must exist before Terraform runs, or that Terraform cannot grant itself,
lives in `bootstrap/` as a script. Not in a wiki, not in prose, not in shell history.

| Script | What it records |
|---|---|
| `config.sh` | Subscription, resource group names, storage account, app registration, GitHub repo. **Every other script sources this.** |
| `00-state-backend.sh` | Resource groups and the state storage account, looped over `LAB_RGS`. |
| `01-providers.sh` | Resource provider registration. |
| `02-federated-credentials.sh` | The OIDC federated credentials — one per subject. |
| `03-rbac-delegation.sh` | The four role assignments below. |
| `04-github-config.sh` | Repository secrets and GitHub environments. |

Every script is idempotent. They use `set -euo pipefail` and `: "${VAR:?message}"` guards,
which catch an *empty* variable as well as an unset one.

> **Editing a bootstrap script is not running it.** A renamed GitHub environment changes
> the OIDC subject; if `02` was edited but not executed, the next run fails with
> `AADSTS700213` and the script on disk looks correct.

### The permissions, and why each exists

| Role | Scope | Why |
|---|---|---|
| Contributor | each lab resource group | build the resources |
| Storage Blob Data Contributor | the state storage account only | read and write state over Entra auth |
| Role Based Access Control Administrator | each lab resource group, **ABAC-conditioned to AcrPull only** | Contributor cannot create role assignments, and the app identity needs AcrPull |
| Resource Policy Contributor | each lab resource group | Contributor cannot create policy assignments either |

The ABAC condition is the interesting one: the pipeline can grant exactly the one role it
needs to grant and cannot grant itself anything. Resource-group scope on the policy role is
also deliberate — custom policy *definitions* require subscription scope, so this repo uses
built-in definitions only, and the pipeline cannot write policy affecting anything outside
its two groups.

### OIDC

Three repository secrets — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` —
mapped to `ARM_*` environment variables in each workflow. No client secret.

```bash
diff <(grep -o 'secrets\.[A-Z_]*' .github/workflows/terraform-apply.yml | sort -u) \
     <(grep -o 'secrets\.[A-Z_]*' .github/workflows/terraform-destroy.yml | sort -u)
```

Prints nothing when the two workflows authenticate the same way. A workflow that
authenticates differently from the one it mirrors only reveals itself the first time you
actually need it — which was, in this repo, the moment of trying to tear down production.

Federated credential subjects must use the **numeric** owner and repository IDs
(`repo:OWNER@ID/REPO@ID:...`), not the names.

---

## Rules and gates

Three things can stop a bad change here, and they catch different classes of mistake. A
rule placed in the wrong one is worse than no rule, because it reports success and enforces
nothing.

| Gate | Where it runs | What it can see | What it cannot |
|---|---|---|---|
| **Checkov** | On the pull request, before anything exists | Resource properties as written, plus conventions we invented | Anything created outside this repository. Values that only exist at deploy time. |
| **Azure Policy** | At the Azure API, on every request | The actual request, whoever made it — pipeline, portal, CLI, script | Anything Azure has no concept of: naming, module structure, state layout |
| **`terraform plan`** | On the pull request, against real state | Drift, destructive changes, wrong state file | Nothing — but it **reports green regardless of content**. A human has to read it. |

### What each one owns

| Mistake | Caught by |
|---|---|
| Registry admin account enabled | Checkov (`CKV_TFLAB_2`) |
| A resource added to the module without tags | Checkov (`CKV_TFLAB_1`) |
| Resource created in a region we don't use | Azure Policy (`allowed-locations`) |
| Resource created without a CostCentre tag | Azure Policy (`require-costcentre`) |
| Someone bypassing the pipeline with `az` | Azure Policy only |
| Wrong backend `key`, destructive drift | `terraform plan` — green check, catastrophic content |
| A control assigned from the state it protects | **Nothing.** See below. |

### The Basic-SKU decision

Eight Checkov findings on the container registry are suppressed inline, next to
`sku = "Basic"`, each with a reason. All eight are Premium-tier features or a paid Defender
plan. This is a cost decision, not a disagreement about security: a customer platform would
run this registry Premium and none of those suppressions would exist.

Three of the eight arrive independently from Azure Policy, via the `SecurityCenterBuiltIn`
("ASC Default") assignment that Defender for Cloud puts on every subscription:

- Azure registry container images should have vulnerabilities resolved
- Container registries should use private link
- Container registries should not allow unrestricted network access

Two rule sets written by different people converged on the same three things, which is
reasonable evidence the suppressions are judgement calls rather than blind spots. They are
left reporting rather than exempted — if they are ever accepted formally, that belongs in a
policy exemption with a category and an expiry, not in silence.

### A control cannot protect the state it lives in

The policy assignments are created by the same Terraform root they constrain. The
deliberate state-key test produced a plan with `8 to add, 6 to destroy`, and **both policy
assignments were in the destroy list**. The guardrails disappear alongside everything else,
at exactly the moment they would matter.

Acceptable here; the estate is disposable. Not acceptable for a customer platform, where
policy should be assigned at subscription or management-group scope by a separate pipeline
with its own state and credentials — so that breaking the workload's state cannot disarm
the control.

### Audit before enforce

Both gates have an observe mode and both were used:

- Checkov: `soft_fail: true` while findings were read and triaged, then removed.
- Azure Policy: `enforce_policy = false`, compliance read, then `true` in **dev only**.

Prod stays in audit mode. Enforcement is promoted deliberately, one environment at a time.

### Verified, not assumed

- `zone_redundancy_enabled` is rejected by the azurerm provider on a Basic registry, even
  though the Microsoft tier table says all tiers support availability zones. Tested
  2026-10-01; the suppression of `CKV_AZURE_233` rests on that test.
- `CKV_TFLAB_1` passes because Checkov resolves `local.tags`. It uses `exists`, so it
  proves the tag key is present, not that the value is meaningful. Its real worth is
  catching a resource added to the module without `tags = local.tags`.
- Checkov's pass/fail/skip counts are deduplicated differently and a module called twice
  inflates them. Read the check IDs, not the totals.

---

## Known issues

**Prod has no container app.** The subscription's Container Apps quota is **one
environment for the whole subscription** — not one per region. Dev holds it. Prod runs with
`enable_container_app = false`, which gives it a registry, workspace, identity and role
assignment, and a green apply.

The error to recognise is `MaxNumberOfGlobalEnvironmentsInSubExceeded`. Its near-twin
`MaxNumberOfRegionalEnvironmentsInSubExceeded` is a per-region cap that another region does
fix — read which one you got before changing anything. When the quota lands, prod gets its
app by flipping one variable to `true`.

**The subscription is on a free trial**, which blocks creating additional subscriptions.
Splitting dev and prod into separate subscriptions — the shape a real per-customer platform
takes, and the clean answer to the quota — needs a pay-as-you-go upgrade first.

---

## Errors and what they mean

| What you see | What it means |
|---|---|
| `MaxNumberOfGlobalEnvironmentsInSubExceeded` | Subscription-wide Container Apps cap, commonly one. **No region change helps.** |
| `MaxNumberOfRegionalEnvironmentsInSubExceeded` | Per-region cap. Another region fixes it — check the global cap first. |
| `RequestDisallowedByAzure` (403) | The subscription may not deploy in that region at all. Probe with a throwaway managed identity *before* changing a `location`. |
| `InvalidResourceLocation` (409) | Azure holds a deleted resource's name in its original region, so the create half of a region change is refused — after the destroy has run. Registries free their name within the hour (`az acr check-name -n NAME`). A Log Analytics workspace is soft-deleted for 14 days: recover it (`workspace create` in its original region) then purge it (`workspace delete --force --yes`). `--force` alone does nothing, because there is no live workspace to act on. |
| `RequestDisallowedByPolicy` | Working as designed. The message names the assignment and definition. Fix the resource, or exempt it deliberately — don't delete the assignment. |
| `AuthorizationFailed` on `policyAssignments/write` | Contributor excludes every `Microsoft.Authorization` write. Needs Resource Policy Contributor — and `bootstrap/03` has to have been *run*. |
| `Error acquiring the state lock` | Two things want the same state file. Usually concurrency; occasionally two roots sharing a `key`. Check the lock's `Path` against the job that reported it. |
| `AADSTS700213` | No federated credential for that subject. Check the numeric IDs, and check the script was run. |
| A plan listing the other environment's resources | Both roots point at the same state `key`. Fix the backend block, `init -reconfigure`. **Never apply it.** |
| `Resource not accessible by integration` | The SARIF upload lacks `security-events: write`. |
| `Module not installed` | A `module` block changed and `terraform init` did not re-run. |
| `Invalid value for variable` | Your own `validation` block, working. |
| `name is not available` (registry) | Registry names are globally unique. The `random_string` must live inside the module. |
| `terraform: no configuration files` | A step ran in the repository root. The root has no `.tf` files. |
| `connection reset` during `terraform init` (WSL) | MTU. Persisted at 1280 via a systemd unit; `ip link show eth0` to check it held. |

---

## Working on this

```bash
git switch main && git pull --prune
git switch -c my-change
# edit
terraform -chdir=envs/dev fmt
terraform -chdir=envs/dev validate
checkov -d . --framework terraform --compact --quiet --skip-path '.terraform' \
  --external-checks-dir policy/checkov
git commit -am "..."
git push -u origin my-change
gh pr create --fill
```

Running Checkov locally before pushing saves a round trip. Pin your local version to the
one the action uses, or findings will differ for reasons unrelated to your change.

Read both plan comments. A change to `envs/prod/main.tf` should appear in prod's plan and
**not** in dev's — if it appears in both, something is shared that shouldn't be.

Direct pushes to `main` are rejected by a branch ruleset. If you have already committed
locally:

```bash
git switch -c my-change
git switch main && git reset --hard origin/main
```

Squash merges mean `git branch -d` will refuse to delete a merged branch, because the
commits on `main` are new ones. `git branch -vv` showing `: gone]` is the real signal that
a branch is merged and cleaned up; `-D` is then safe.

### Teardown

```bash
gh workflow run terraform-destroy.yml -f environment=prod -f confirm=prod
gh workflow run terraform-destroy.yml -f environment=dev  -f confirm=dev
az resource list -g rg-tflab-dev  -o table
az resource list -g rg-tflab-prod -o table
az policy assignment list -g rg-tflab-dev -o table
```

Prod first; dev's Container Apps environment takes several minutes. Log Analytics
workspaces go to **soft-delete**, not away, and reappear for 14 days in
`az monitor log-analytics workspace list-deleted-workspaces`.

Both groups empty and no policy assignments left. An assignment surviving an otherwise
clean teardown is a control nobody owns.

The registry is the only meaningful standing cost, so with both environments destroyed the
estate is close to free.
