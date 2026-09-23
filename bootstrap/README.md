# bootstrap

The resources in this folder are **not managed by Terraform**, on purpose. The
pipeline's permissions are scoped to `rg-tflab-dev`, and its state lives in
`rg-tfstate` — so Terraform must not be able to destroy either, and cannot
create the identity that lets the pipeline authenticate in the first place.

These scripts are the record of how those things were made. Run them in order
on a fresh subscription and the pipeline works.

| Script | Creates |
|---|---|
| `config.sh` | Shared names. Sourced by the others; edit this one if you rebuild elsewhere. |
| `00-state-backend.sh` | `rg-tfstate`, the state storage account and container (versioning + 30-day soft delete), your own data-plane access to it, and `rg-tflab-dev`. |
| `01-providers.sh` | Registers the `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.OperationalInsights` and `Microsoft.Storage` resource providers. |
| `02-federated-credentials.sh` | The `gh-tflab` app registration, its service principal, and three federated credentials — pull requests, `main`, and the `production` environment. |
| `03-rbac-delegation.sh` | Contributor on `rg-tflab-dev`, Storage Blob Data Contributor on the state account, and a **conditioned** RBAC Administrator grant that may only hand out `AcrPull`. |
| `04-github-config.sh` | Repository secrets, the `production` environment with a required reviewer, and the `ACR_NAME` variable. |

```bash
cd bootstrap
./00-state-backend.sh
./01-providers.sh
./02-federated-credentials.sh
./03-rbac-delegation.sh
./04-github-config.sh      # re-run after the first terraform apply to set ACR_NAME
```

All of them are safe to run twice: each checks whether the thing already
exists before creating it.

Not automated: the branch ruleset on `main`. Set it in Settings → Rules —
require a pull request, and require the `plan` status check.

## Conventions

Every script starts with `set -euo pipefail` and guards each value it reads
with `: "${VAR:?message}"`. `set -u` catches a variable that was never set;
the `:?` form also catches one that is set but **empty**, which is how a failed
`az` lookup fails. Scripts are separate processes — nothing carries over from
your shell — so each one derives every value it needs.
