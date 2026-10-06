# SAAS - HENRY FORD (gitops)

The **desired state** of every workload on the `mackllc` EKS cluster. Argo CD watches this repo and makes the cluster match it. Nobody runs `kubectl apply` or `helm install` for apps. Everything changes through a commit here.

Companion repos: [infra](https://github.com/Alexatlanta1981/infra) (Terraform, cluster, Argo CD install), [backend](https://github.com/Alexatlanta1981/backend) (8 services, CI), [frontend](https://github.com/Alexatlanta1981/frontend) (`mackllc-ui`, CI).

## Architecture

```
 backend / frontend repo                       gitops repo (this)                    EKS cluster
┌───────────────────────┐   1. build, test,   ┌────────────────────────┐          ┌───────────────────┐
│ ci-<service>.yml      │      scan, push     │ envs/dev/values-X.yaml │ 3. Argo  │ namespace dev     │
│  Maven/Node, Sonar,   │──► ECR (sha-abc123) │   image.tag: sha-abc123│◄─ CD ────│  Deployment,      │
│  Trivy, Cosign sign   │                     │ helm-charts/ (1 chart) │  polls   │  Service, SA, ... │
└──────────┬────────────┘   2. bot commits    │ argocd/ (Projects,Apps)│  & syncs │ namespaces qa,prod│
           └──────────────► new tag ─────────►│ k8s/ db-init/          │          └───────────────────┘
              (GitHub App token)              └────────────────────────┘
```

1. A push to a service repo builds the image, scans it, pushes it to ECR as `sha-<7 chars>`, and signs it with Cosign (keyless).
2. The pipeline commits the new tag into `envs/dev/values-<service>.yaml` here, using a short-lived GitHub App token.
3. Argo CD sees the commit, renders the chart with that values file, and syncs the `dev` namespace.
4. Promotion to `qa` and `prod` is a manual workflow in the service repo (`promote-qa.yml`, `promote-prod.yml`). It opens a **pull request** here that copies the image tag from the previous environment.

## Layout

| Path | What it holds |
|---|---|
| `helm-charts/` | One shared chart (`mackllc-service`) for every service: Deployment, Service, ConfigMap, ServiceAccount, HPA, Ingress. Hardened defaults (non-root, read-only root FS, dropped capabilities). |
| `envs/<env>/values-<service>.yaml` | Per-service, per-environment overrides: image repo and tag, ports, probes, config, IRSA role ARN, secret references. |
| `argocd/projects/` | The `mackllc` AppProject. It limits sources to this repo and destinations to `dev`, `qa` and `prod`. |
| `argocd/apps/<env>/` | One Argo CD `Application` per service per environment. Each points at `helm-charts` plus its values file. |
| `argocd/install/` | Argo CD namespace and ingress. |
| `k8s/` | Namespaces and raw manifests used before the chart (`mackllc-ui`). |
| `db-init/01-schemas.sql` | Creates one Postgres schema per service. |

Services: api-gateway, auth-service, catalog-service, inventory-service, manufacturing-service, notification-service, supplier-service, qc-service, mackllc-ui.

## Running it

Prerequisites: the infra repo has been applied (cluster, ECR, IRSA roles, Secrets Manager) and Argo CD is installed (`scripts/01_install_prerequisites.py` in infra).

```bash
# one time: register the project and apps (Argo CD does the rest)
kubectl apply -f argocd/projects/mackllc-project.yaml
kubectl apply -f argocd/apps/dev/

# check state
kubectl -n argocd get applications
kubectl -n dev get pods

# render a service locally before committing
helm template auth-service helm-charts -f envs/dev/values-auth-service.yaml
```

Deploy a change: edit the values file (or chart), open a PR, merge. Argo CD syncs within a few minutes. Roll back with `git revert`.

Argo CD needs read access to this repo. That is a GitHub App installed on `gitops` (see `infra/docs/DEPLOY-RUNBOOK.md`, section 6).

## Why it is designed this way

- **Git is the source of truth.** Every change is reviewed, attributable and revertable. The cluster can be rebuilt from this repo, which is exactly what the infra destroy and apply cycle relies on.
- **Separate repo from the code.** A config change does not trigger a build, and CI write access is limited to this one repo.
- **Pull, not push.** CI never holds cluster credentials. Argo CD runs inside the cluster and pulls, so the only thing CI can do is propose a commit.
- **One chart, many values files.** Nine services share one tested template, so a fix to probes or security settings lands everywhere. Differences live in small values files.
- **Immutable tags (`sha-<commit>`).** The tag identifies exactly which code is running, and promotion copies the same tag, so QA and prod run the bits that passed dev.
- **Dev is automatic, QA and prod are gated.** Dev auto-syncs for speed. Promotion is a PR, so a human approves what reaches QA and prod.
- **IRSA, no stored AWS keys.** Each service has its own IAM role through its service account annotation (`eks.amazonaws.com/role-arn`).
- **Secrets are not in git.** Values files reference Kubernetes secrets (`db-credentials`, `jwt-secret`), which are created from AWS Secrets Manager.
- **Schema per service.** One database instance, with data separated per service and per grant.
- **Short-lived GitHub App tokens** replace personal access tokens for CI writes.

## Known gaps

- Dev apps have `selfHeal` turned off (commented out), so manual drift in `dev` is not reverted. QA has it on.
- Argo CD has no SSO yet, and the local admin user is still enabled.
- The Argo CD ingress has no ALB address yet.
