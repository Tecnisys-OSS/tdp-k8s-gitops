# TDP GitOps

ArgoCD manifests repository for deploying Tecnisys Data Platform (TDP) components to Kubernetes, using the **App of Apps** pattern.

## Overview

This repository drives the deployment of TDP (Tecnisys Data Platform) components — Ozone, Trino, Spark, Airflow, Kafka, Superset, and others — onto Kubernetes clusters using ArgoCD's App-of-Apps pattern. Application manifests are kept as envsubst templates under `available/`, rendered per environment into `current/` (the source of truth ArgoCD watches), and reference versioned Helm charts hosted on Tecnisys' OCI registry. A single `deploy.sh` script handles the ArgoCD bootstrap, template rendering, and both GitOps (git-driven) and direct (`kubectl apply`) deployment modes.

### How it works

```
deploy.sh                 your git repo             ArgoCD
─────────                 ─────────────             ──────
available/ ─┐  render     current/        watch     App of Apps (in ARGOCD_NAMESPACE)
common/   ──┴──────────►  ├─ common/   ◄──────────     │ creates one Application per component
                          ├─ tdp-ozone/                ▼
                          └─ tdp-trino/  ◄──────────  Applications (in TDP_PROJECT_NAMESPACE)
                                         values        │ Helm chart from registry.tecnisys.com.br
                                                       ▼
                                                     Workloads (in TDP_NAMESPACE)
```

- `available/` and `common/` contain the **templates** (with `${VAR}`) — **never** applied directly.
- `deploy.sh -p` renders `common/` (and the components you name) → `current/`, substituting variables.
- `current/` is **committed to git** and watched by the App of Apps. Each Application installs its chart from the registry, with the values files from `current/<component>/`.
- The rendered Secrets (`current/common/*-secret.yaml`) hold your git and registry credentials: they are git-ignored, excluded from the App of Apps and applied by `deploy.sh` only. **Never commit them.**
- Charts and images come from **`registry.tecnisys.com.br` only**: `community/*` is public, `tdp/*` needs the `tdp-registry` pull secret that `deploy.sh` creates.

### Structure

```
tdp-gitops/
├── common/           # Bootstrap templates: AppProject, App of Apps, repository and pull Secrets
├── available/        # One folder per TDP component:
│   ├── tdp-airflow/      #   tdp-airflow.yaml          the ArgoCD Application
│   │                     #   values.yaml               chart defaults
│   │                     #   values-gitops.yaml        GitOps defaults (optional overlay)
│   │                     #   values-integration.yaml   wiring to other components (optional overlay)
│   │                     #   values-ozone-security.yaml Ozone security (only with TDP_OZONE_SECURITY=true)
│   ├── tdp-clickhouse/
│   ├── …
│   └── tdp-trino/
├── current/          # Rendered by deploy.sh — committed to git,
│                     # except current/common/*-secret.yaml (git-ignored)
├── variables.env     # Reference variables (do not edit, copy to variables.env.local)
├── deploy.sh         # Render and deploy script
├── enable-ozone-security.sh  # Turns Ozone security on (see Ozone security)
└── README.md
```

---

## Prerequisites

| Item | Requirement |
| --- | --- |
| Cluster | Kubernetes 1.32+, OpenShift 4.19+ or Rancher 2.10.x+ |
| Workstation | `kubectl` configured for the cluster, `helm` 3, `envsubst` (`gettext` package), `git` |
| Registry account | A user or robot account on `registry.tecnisys.com.br`, used for the charts and for the private images |
| Git server | An empty repository that ArgoCD can reach, and a token for it |
| Cluster classes | An IngressClass and a StorageClass, or cluster defaults for both |
| TDP license | Two files from Tecnisys: the trusted public keys (`keys.json`) and the signed lease (`lease.json`). ArgoCD and every TDP component refuse to install without a VALID license; `deploy.sh --install` installs it first (see Step 3) |
| Installed by the cluster administrator | `tdp-operator` (Kafka and ClickHouse operators), via `helm install`, outside this GitOps flow. Like every TDP chart, it needs the license installed first |

---

## Installation

### Step 1 — Create your GitOps repository

This repository (**Tecnisys-OSS/tdp-k8s-gitops**) is the distribution source — kept in sync with each TDP release, and overwritten on every release sync. Use it as the starting point for **your own** repository, the one ArgoCD will watch:

```bash
# Get the kit
git clone https://github.com/Tecnisys-OSS/tdp-k8s-gitops.git my-tdp-gitops
cd my-tdp-gitops

# Point it at your own, empty repository and publish it
git remote set-url origin https://git.example.com/<org>/my-tdp-gitops.git
git push -u origin main
```

The App of Apps follows the **`main`** branch.

### Step 2 — Configure `variables.env.local`

```bash
cp variables.env variables.env.local
```

`variables.env.local` is git-ignored. It is sourced by bash, so **single-quote any value containing `$`**, such as a Harbor robot account (`TECNISYS_HELM_REGISTRY_USER='robot$tdp+pull'`).

| Variable | Example | Used for |
| --- | --- | --- |
| `ARGOCD_NAMESPACE` | `tdp-system` | Where ArgoCD is installed (and the App of Apps lives) |
| `TDP_NAMESPACE` | `tdp` | Where the component pods run, and the `tdp-registry` pull secret |
| `TDP_PROJECT_NAMESPACE` | `tdp` | Where the component Applications live |
| `TDP_APPLICATIONS` | `argo-gitops-tdp` | Name of the App of Apps |
| `GIT_REPO_URL`, `GIT_REPO_USER`, `GIT_REPO_TOKEN_OR_PASS` | your repository | The repository ArgoCD watches |
| `HELM_CHART_REPO_URL`, `HELM_CHART_VERSION` | `registry.tecnisys.com.br/tdp/charts`, `3.0.2` | Where the charts come from |
| `KUBERNETES_SERVER` | `https://kubernetes.default.svc` | Destination cluster (in-cluster by default) |
| `TECNISYS_HELM_REGISTRY_USER`, `TECNISYS_HELM_REGISTRY_TOKEN` | `'robot$tdp+pull'` | Chart pulls (ArgoCD) and image pulls (`tdp-registry` secret) |
| `TDP_DOMAIN` | `example.com` | Ingress/Gateway API hosts: `airflow.example.com`, … (default `tdp.local`; `-d` overrides it) |
| `TDP_INGRESS_CLASS`, `TDP_STORAGE_CLASS` | `nginx`, `local-path` | Written into every `values-gitops.yaml`; empty = chart default and the cluster's default class |
| `TDP_EXPOSE` | `ingress` | How components with a web endpoint are exposed: `ingress`, `gatewayapi` or `none` (default; `-e` overrides it) |
| `TDP_GATEWAY_NAME`, `TDP_GATEWAY_NAMESPACE` | `tdp-gateway`, `gateway-system` | With `gatewayapi`: the existing Gateway the HTTPRoutes attach to (required) |
| `TDP_OPENMETADATA_DATABASE` | `postgresql` | OpenMetadata's metadata database: `mysql` (bundled, default) or `postgresql` (the kit's `tdp-postgresql`, deployed first). Sets `global.TDP-Settings.database` in its `values-gitops.yaml` |
| `TDP_LICENSE_PUBLIC_KEYS_FILE`, `TDP_LICENSE_FILE` | `license/keys.json`, `license/lease.json` | The license files from Tecnisys, relative to the variables file. `license/` is git-ignored. The lease can also be the `tecnisys-license-lease` Secret manifest |
| `TDP_LICENSE_NAMESPACE` | `tdp-system` | Where `tdp-license-operator` and the `PlatformLicense` live (default `tdp-system`) |
| `TDP_LICENSE_POLICY_NAMESPACES` | `tdp,tdp-data` | Namespaces whose licensed workloads the license governs, comma-separated (empty = `TDP_NAMESPACE`) |
| `TDP_DEFAULT_PASSWORD` | `'ChangeMe!T3c'` | Fallback for every empty `TDP_*_PASSWORD` below |
| `TDP_<COMPONENT>_..._PASSWORD` | empty | UI admin logins (Airflow, CloudBeaver, Jupyter, Kafka UI, Ranger, Superset) and the database users set in values (Airflow, Hive and Superset built-in PostgreSQL, Ranger, the ClickHouse `trino`/`superset` users); the list is in `variables.env` |
| `TDP_SUPERSET_SECRET_KEY` | empty | Superset `SECRET_KEY` (signs sessions, encrypts the connection passwords Superset stores). Empty: `deploy.sh` keeps the key already in `current/tdp-superset/`, or generates one on the first render; copy it to your variables file to pin it |
| `TDP_OZONE_SECURITY` | `false` | Ozone security (Kerberos and real S3 authentication). Set by `enable-ozone-security.sh`; see [Ozone security](#ozone-security) |
| `TDP_OZONE_KDC_MASTER_PASSWORD` | empty | Ozone KDC master password, used once to create the KDC database. Empty: `deploy.sh` keeps the one already in `current/tdp-ozone/`, or generates one |

The passwords only reach the component files (`deploy.sh` checks them when you render a component): at least 8 characters from `A-Z a-z 0-9 ! . _ ~ -`, because they are written unescaped into YAML, XML, shell, SQL and database URIs. A shared credential uses one variable on both sides, e.g. `TDP_CLICKHOUSE_TRINO_PASSWORD` sets the ClickHouse `trino` user and the Trino `clickhouse` catalog. They apply when a user is first created; changing one later does not change an existing user's password, and existing `current/<component>/values*.yaml` files are only re-rendered with `--force`. OpenMetadata's admin (`admin@open-metadata.org` / `admin`) is created by OpenMetadata itself and is not covered.

### Step 3 — Install the CRDs, the license and ArgoCD

Put the two license files from Tecnisys where `TDP_LICENSE_PUBLIC_KEYS_FILE` and `TDP_LICENSE_FILE` point (by default `license/keys.json` and `license/lease.json`, next to the variables file), then:

```bash
./deploy.sh --install -v variables.env.local
```

What runs, in order:

1. `helm registry login` — authenticates to the OCI registry.
2. `helm upgrade --install tdp-crds` — the cluster CRDs; skipped when both the ArgoCD and the license CRDs already exist.
3. The license, in `TDP_LICENSE_NAMESPACE`: the `tdp-registry` pull secret, `helm upgrade --install tdp-license` (tdp-license-operator and its admission webhook, trusting the public keys), the `tecnisys-license-lease` Secret, and a whole-platform `LicensePolicy` + `PlatformLicense` pair. It then waits for the operator to verify the lease and **stops if the license is not VALID**.
4. `helm upgrade --install tdp-argo` — ArgoCD in `ARGOCD_NAMESPACE`, with `application.namespaces: "*"` so it can manage Applications in any namespace, and the UI exposed at `argo.${TDP_DOMAIN}` per `TDP_EXPOSE` (see Step 4); waits for the server and the application controller.
5. `envsubst` on `common/` → `current/common/`. Components are rendered separately, in Step 6.
6. `kubectl apply` of `current/common/` (creating `TDP_NAMESPACE` if needed):
   - `argo-gitops-appproject.yaml` — the TDP AppProject
   - `tdp-devops-repo-secret.yaml` — git credential for ArgoCD
   - `tdp-registry-secret.yaml` — Helm OCI registry credential for ArgoCD
   - `tdp-image-pull-secret.yaml` — the `tdp-registry` image pull secret in `TDP_NAMESPACE`. An existing `tdp-registry` is kept unless you pass `--force`.
   - `argo-gitops-app-of-apps.yaml` — the App of Apps

#### The license gate

Every TDP chart (`tdp-argo`, `tdp-operator` and each component in `available/`) refuses to install unless `tdp-license-operator` is running and a `PlatformLicense` covering it is VALID (or WARNING) and was verified by the operator in the last 10 minutes:

- `helm install`/`upgrade` (as `--install` does for `tdp-argo`) fails before creating anything, with a `[<chart>] license check failed: …` message.
- ArgoCD cannot run that check while rendering, so each chart also renders a `<release>-license-check` PreSync hook Job that runs it. Without a valid license the hook fails and ArgoCD applies nothing from that Application; once the license is VALID again, the next sync goes through.

> **Using an ArgoCD you installed yourself?** Skip `--install`: run `./deploy.sh --license -v variables.env.local` to install the license, then `./deploy.sh -c -v variables.env.local`. Make sure that ArgoCD manages Applications in `TDP_PROJECT_NAMESPACE`:
>
> ```bash
> kubectl patch configmap argocd-cm -n <argocd-namespace> --type merge \
>   -p '{"data":{"application.namespaces":"<TDP_PROJECT_NAMESPACE>"}}'
> kubectl rollout restart deployment argocd-server -n <argocd-namespace>
> kubectl rollout restart statefulset argocd-application-controller -n <argocd-namespace>
> ```

#### Worker-node limit

A license can also limit how many Kubernetes nodes may run TDP. The operator counts the nodes running pods labeled `tecnisys.com/licensed=true` in the `TDP_LICENSE_POLICY_NAMESPACES`. When there are more than the license allows for over 15 minutes, it reports `UNDER_LICENSED`: `kubectl get platformlicense -A` shows `NODES`, `MAX` and `CAPACITY`, and an `UnderLicensed` event and the `tecnisys_license_under_licensed` metric are raised. This is an alert only: nothing is stopped or refused. On a cluster upgraded from an older kit, `deploy.sh` warns when the `PlatformLicense` CRD is too old to report it, and prints the commands to update it.

### Step 4 — Expose the ArgoCD UI

`--install` exposes the ArgoCD UI the same way as the components, so no `helm upgrade` is needed afterwards:

| `TDP_EXPOSE` / `-e` | What `tdp-argo` gets |
| ------------------- | -------------------- |
| `ingress` | An Ingress for `argo.${TDP_DOMAIN}`, with `TDP_INGRESS_CLASS` (the chart default, `nginx`, when empty) |
| `gatewayapi` | An HTTPRoute for `argo.${TDP_DOMAIN}` on `TDP_GATEWAY_NAME` in `TDP_GATEWAY_NAMESPACE` (`TDP_NAMESPACE` when empty). The route lives in `ARGOCD_NAMESPACE`, so the Gateway listener must allow routes from that namespace |
| `none` | No Ingress or route. Reach the UI with `kubectl -n <ARGOCD_NAMESPACE> port-forward svc/tdp-argocd-server 8080:80` |

In every mode, ArgoCD's own URL (`configs.cm.url`) is set to `https://argo.${TDP_DOMAIN}`, so redirects and SSO callbacks match the host.

To change the exposure or the domain later, re-run `./deploy.sh --install` with the new settings. It upgrades `tdp-argo` in place, rebuilds its values from the variables file, and drops any flags you set by hand. Without a TLS configuration the Ingress serves the controller's default certificate.

### Step 5 — Publish the bootstrap and log in

The App of Apps reads `current/` **from the git repository**, so push it. The rendered Secrets are git-ignored and stay local.

```bash
git add current/
git commit -m "chore: bootstrap TDP GitOps"
git push origin main

# The App of Apps should report Synced
kubectl -n tdp-system get applications

# Initial admin password for the UI
kubectl -n tdp-system get secret tdp-argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Step 6 — Render the applications

Without component names, `deploy.sh` renders `current/common/` only. Name the components you want, or pass `--all-components`:

```bash
# A few components
./deploy.sh -p -v variables.env.local tdp-ozone tdp-hive-metastore tdp-trino

# Everything in available/, with hosts such as airflow.example.com
./deploy.sh -p -v variables.env.local -d example.com --all-components

# Exposed through Ingress, or through Gateway API HTTPRoutes on an existing Gateway
./deploy.sh -p -v variables.env.local -e ingress tdp-trino tdp-superset
./deploy.sh -p -v variables.env.local -e gatewayapi tdp-trino tdp-superset   # needs TDP_GATEWAY_NAME
```

Each component lands in `current/<component>/`: its Application manifest plus up to three values files (see [Values files](#values-files)).

- Rendering only adds or refreshes files: components already in `current/` that you don't name are left alone, so the App of Apps doesn't prune them.
- An existing `current/<component>/values*.yaml` may hold your edits, so it is **kept** (with a warning) unless you pass `--force`. The Application manifest is always refreshed.
- `deploy.sh` warns if anything in `current/` points at a registry other than `registry.tecnisys.com.br`.
- **Exposure** (`TDP_EXPOSE` / `-e`) sets each component's `TDP-Settings.gateway.ingress.enabled` and `TDP-Settings.gateway.gatewayApi.enabled` in `values-gitops.yaml`; they are mutually exclusive. Hosts are `<component>.${TDP_DOMAIN}` in both modes, Ingresses use `TDP_INGRESS_CLASS`, and HTTPRoutes attach to `TDP_GATEWAY_NAME` (the charts' own per-release Gateway stays off). To change the exposure of a component that is already rendered, re-render it with `--force` or edit its `values-gitops.yaml`. Spark gets two hosts, each with an Ingress or HTTPRoute: the Master UI at `spark.${TDP_DOMAIN}`, and the History Server at `spark-history.${TDP_DOMAIN}` (turned on in `tdp-spark/values-integration.yaml`, with its event logs in `s3a://warehouse/spark-events`).

### Step 7 — Push and let ArgoCD sync

```bash
git add current/
git commit -m "feat: add tdp-ozone, tdp-hive-metastore, tdp-trino"
git push origin main

# Follow the Applications and their pods
kubectl -n tdp get applications            # Synced / Healthy
kubectl -n tdp get pods -w
```

The App of Apps creates each new Application; every Application installs its chart from `registry.tecnisys.com.br` with the values from your repository, with automated sync, self-heal and prune.

**Direct mode** applies an Application with `kubectl`, without going through the App of Apps — ArgoCD still reads its values files from git, so push them anyway:

```bash
./deploy.sh -a -v variables.env.local tdp-trino
```

### Suggested rollout order

ArgoCD can sync everything at once, but components wired together by `values-integration.yaml` come up cleanly when their dependencies are already running:

| Order | Components | Notes |
| --- | --- | --- |
| 1. Object storage | `tdp-ozone` | Create the buckets `warehouse` and `clickhouse-data` in Ozone's `/s3v` volume (with Ozone security on, with the key from `ozone-s3-credentials`: see [Ozone security](#ozone-security)) |
| 2. Metadata and engines | `tdp-hive-metastore`, `tdp-spark`, `tdp-iceberg`, `tdp-trino` | Use Ozone's S3 Gateway |
| 3. Serving and BI | `tdp-clickhouse`, `tdp-superset` | Superset imports the ClickHouse and Trino datasources |
| 4. Any order | `tdp-airflow`, `tdp-kafka`, `tdp-nifi`, `tdp-jupyter`, and the rest | Kafka and ClickHouse need `tdp-operator` |

---

## Values files

Each Application layers up to four values files from `current/<component>/`, in this order — later files win:

| File | Content | On a release sync |
| --- | --- | --- |
| `values.yaml` | Chart defaults (a copy of the chart's own `values.yaml`) | Replaced by the new chart defaults |
| `values-gitops.yaml` | GitOps defaults: ArgoCD-specific fixes (e.g. Airflow migration Jobs as Sync hooks), Ozone S3 auth off while Kerberos is off, the ingress/storage class from `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS`, the exposure from `TDP_EXPOSE`, the component passwords from `TDP_*_PASSWORD`, production image mirrors | Kept |
| `values-integration.yaml` | Wiring to the other TDP components in `TDP_NAMESPACE`: Trino catalogs (hive, iceberg, clickhouse), Spark, Hive Metastore and ClickHouse on Ozone S3, Superset datasources | Kept |
| `values-ozone-security.yaml` | Only with `TDP_OZONE_SECURITY=true` (`tdp-ozone`, `tdp-trino`, `tdp-spark`, `tdp-hive-metastore`, `tdp-clickhouse`): Kerberos and S3 auth for Ozone, and the clients' S3 key from `ozone-s3-credentials`. See [Ozone security](#ozone-security) | Kept |

- Maps merge key by key, so an overlay only holds the keys it changes. Lists and multi-line strings are replaced as a whole.
- An empty `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS` renders as `null`, which removes the key: the chart default applies.
- The overlays are optional: delete one from `current/<component>/` to opt out of it (the Applications set `ignoreMissingValueFiles: true`).
- `values-integration.yaml` assumes the components it points at are deployed with their default names in `TDP_NAMESPACE`, and takes the ClickHouse, Trino and Superset passwords from `variables.env`.
- ArgoCD does not substitute variables: everything under `current/` must be rendered by `deploy.sh` before you push.

### Customizing values

Edit the files in `current/<component>/` — that is what ArgoCD reads, and `deploy.sh` keeps them on re-render. Prefer `values-gitops.yaml` (or a new overlay) for your own changes, so `values.yaml` can later be refreshed from a newer release with `--force`:

```bash
vim current/tdp-trino/values-gitops.yaml
git add current/tdp-trino/
git commit -m "chore: tune trino"
git push origin main
# ArgoCD syncs automatically
```

---

## Ozone security

`tdp-ozone` ships with security off: there is no Kerberos between its daemons, and the S3 Gateway accepts any key, so every client in the cluster can read and write every bucket. The other components use placeholder keys (`values-integration.yaml`). That is the default for a first deploy; turn security on for anything beyond a demo.

### What turning it on changes

- `tdp-ozone` gets Ozone's internal KDC (realm `TDP.LOCAL`), Kerberos between OM, SCM, the datanodes, the S3 Gateway and Recon, and real S3 authentication.
- A PostSync Job asks the OM for one S3 key, for the Ozone admin `tdp-s3-admin`, and stores it in the Secret `ozone-s3-credentials` in `TDP_NAMESPACE`. Every client below uses that key, so they all act as the Ozone admin.
- Each client gets a `values-ozone-security.yaml` that reads the key from that Secret instead of the placeholder keys:

| Component | How it reads the key |
| --- | --- |
| `tdp-trino` | `AWS_*` env on the coordinator and workers; the `hive` and `iceberg` catalogs use `${ENV:AWS_ACCESS_KEY_ID}` |
| `tdp-spark` | `AWS_*` env on the master, workers and History Server; `core-site.xml` uses `${env.AWS_ACCESS_KEY_ID}` |
| `tdp-hive-metastore` | `metastore.s3.existingSecret` |
| `tdp-clickhouse` | `AWS_*` env on the server pods; the `ozone` disk uses `from_env` |

- The OM, SCM, Recon and S3 Gateway web UIs stay unauthenticated.
- Spark drivers that run outside the `tdp-spark` pods (Jupyter, Airflow) need `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from that Secret themselves.
- It cannot be turned off from the kit: once `current/` holds a `values-ozone-security.yaml`, `deploy.sh` refuses to render with `TDP_OZONE_SECURITY=false`.

### Turning it on

It works on a new `tdp-ozone` and on one that already runs without security, keeping its data: on its first start with security on, the OM gets the SCM-signed certificate it was initialized without (`ozone om --init`, run by `values-ozone-security.yaml`). Back up anything you can't lose first, as for any change of this size.

```bash
./enable-ozone-security.sh -v variables.env.local
git add current/ && git commit -m "feat: enable Ozone security" && git push
```

The script:

1. Checks that the `tdp-ozone` chart in `HELM_CHART_VERSION` runs the keytab export as an ArgoCD Sync hook: older builds never finish their first sync with security on. It needs `helm` and registry access; `--skip-chart-check` skips it.
2. Asks for confirmation (`-y` skips it) and sets `TDP_OZONE_SECURITY=true` in your variables file.
3. Renders `tdp-ozone` and the clients above that are already in `current/` with `deploy.sh -p`, adding their `values-ozone-security.yaml` and keeping the other values files. Components you render later get theirs from `deploy.sh`.

`TDP_OZONE_KDC_MASTER_PASSWORD` is generated on the first render when empty, and kept in `current/tdp-ozone/values-ozone-security.yaml`.

### What happens on the sync

1. `tdp-ozone` syncs the KDC (sync wave -2), a Sync-hook Job that exports the keytabs into Secrets (wave -1), then the Ozone daemons. On an Ozone that already runs, those restart one by one with Kerberos, and the OM gets its certificate as it starts. A PostSync Job then fills `ozone-s3-credentials`:

   ```bash
   kubectl -n <TDP_NAMESPACE> get secret ozone-s3-credentials -o jsonpath='{.data.aws_access_key_id}'
   ```

2. Client pods that start before that wait in `CreateContainerConfigError` and start on their own once it is filled. Pods that were already running keep the old keys: restart the Deployments and StatefulSets of `tdp-trino`, `tdp-spark`, `tdp-hive-metastore` and `tdp-clickhouse` (**Restart** in the ArgoCD UI, or `kubectl rollout restart`).
3. Create the buckets `warehouse` and `clickhouse-data` with that key, if they don't exist yet:

   ```bash
   NS=<TDP_NAMESPACE>
   export AWS_ACCESS_KEY_ID=$(kubectl -n $NS get secret ozone-s3-credentials -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
   export AWS_SECRET_ACCESS_KEY=$(kubectl -n $NS get secret ozone-s3-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)
   kubectl -n $NS port-forward svc/tdp-ozone-s3g-rest 9878:9878 &
   aws s3 mb s3://warehouse --endpoint-url http://localhost:9878 --region us-east-1
   aws s3 mb s3://clickhouse-data --endpoint-url http://localhost:9878 --region us-east-1
   ```

---

## Day-2 operations

| Task | How |
| --- | --- |
| Change a setting | Edit `current/<component>/values-gitops.yaml`, commit and push |
| Upgrade the charts | Set `HELM_CHART_VERSION`, then re-render the components already in `current/` (see below) |
| Take new chart defaults | Re-render the component with `--force` (overwrites its values files) |
| Add a component | Render it (Step 6), commit and push |
| Remove a component | Delete `current/<component>/` and push: ArgoCD prunes the Application and runs its cleanup hooks |
| Rotate registry credentials | Update `variables.env.local`, then `./deploy.sh -c -v variables.env.local --force` |
| Renew the license | Replace the file `TDP_LICENSE_FILE` points to (and `TDP_LICENSE_PUBLIC_KEYS_FILE`, if Tecnisys sent new keys), then `./deploy.sh --license -v variables.env.local`. Workloads stopped by an expired license come back on their own |

Upgrading the chart version:

```bash
# 1. Update HELM_CHART_VERSION in variables.env.local
vim variables.env.local

# 2. Re-render the Applications of the components already in current/
#    (don't use --all-components here: it would add every component)
./deploy.sh -v variables.env.local -p $(ls -d current/tdp-*/ | xargs -n1 basename)

# 3. Commit
git add current/
git commit -m "chore: bump chart version to X.Y.Z"
git push origin main
```

### Upgrading a repository created with an older kit

Older kits committed `current/common/*-secret.yaml` and rendered Applications that only read `values.yaml`. To move an existing repository to this layout:

1. Copy the new kit files (`deploy.sh`, `common/`, `available/`, `.gitignore`, `variables.env`) into your repository, and add the new variables to `variables.env.local`.
2. Apply the common resources first: `./deploy.sh -c -v variables.env.local`. This puts `Prune=false` on the repository Secrets before the new App of Apps (which excludes them) syncs, so ArgoCD never deletes them.
3. Stop tracking the rendered Secrets: `git rm --cached current/common/*-secret.yaml`.
4. Re-render the components you run (their Application manifests now list the overlays; your existing `values.yaml` is kept): `./deploy.sh -p -v variables.env.local $(ls -d current/tdp-*/ | xargs -n1 basename)`.
5. Commit and push. **Rotate the git and registry tokens**: they are still in the repository's history.

---

## deploy.sh reference

```
./deploy.sh [OPTIONS] [COMPONENTS... | --all-components]
```

| Flag | Description |
| --- | --- |
| `--install` | **First install**: helm login → tdp-crds → license (tdp-license-operator, lease, `PlatformLicense`; waits until VALID) → tdp-argo (exposed at `argo.${TDP_DOMAIN}` per `TDP_EXPOSE`) → wait ready → render → apply common |
| `--license` | Install or renew only the license: tdp-crds (if missing) → tdp-license-operator → lease → `PlatformLicense`, waits until VALID, then stops |
| `-v FILE` | Use a custom variables file (default: `variables.env`) |
| `-p` | Only render → `current/` (no apply) |
| `-c` | Apply only common resources (`current/common/`) via kubectl |
| `-a` | Apply only the selected components' Applications via kubectl (not common) |
| `--all-components` | Select every component in `available/` (instead of naming them) |
| `-d DOMAIN` | Domain for Ingress/Gateway API hostnames; overrides `TDP_DOMAIN` |
| `-e MODE` | Exposure: `ingress`, `gatewayapi` or `none`; overrides `TDP_EXPOSE` |
| `-f`, `--force` | Overwrite existing `current/<component>/values*.yaml`, and replace an existing `tdp-registry` pull secret |
| `-h` | Show help |

- **No arguments** prints the help.
- **No components** renders (and, without `-p`, applies) `current/common/` only.
- Without `-p`, `-c` or `-a`, `deploy.sh` applies the common resources plus the selected components' Applications.

### Examples

```bash
# Full first-time setup (installs ArgoCD + bootstrap)
./deploy.sh --install -v variables.env.local

# Render components and publish (GitOps mode)
./deploy.sh -p -v variables.env.local tdp-ozone tdp-trino
git add current/ && git commit -m "chore: render" && git push

# Render every component, with hosts such as airflow.example.com
./deploy.sh -p -v variables.env.local -d example.com --all-components

# Switch an already-rendered component to Ingress (--force rewrites its values files)
./deploy.sh -p -v variables.env.local -e ingress --force tdp-trino

# Turn Ozone security on (Kerberos + real S3 auth), then publish
./enable-ozone-security.sh -v variables.env.local

# Re-apply only common resources (AppProject, Secrets, App of Apps)
./deploy.sh -c -v variables.env.local

# Direct deploy of one, several or every component (no git round trip for the Application)
./deploy.sh -a -v variables.env.local tdp-trino
./deploy.sh -a -v variables.env.local tdp-ozone tdp-trino
./deploy.sh -a -v variables.env.local --all-components
```

---

## Available Components

| Component | Description | Notes |
| --- | --- | --- |
| `tdp-airflow` | Apache Airflow | |
| `tdp-clickhouse` | ClickHouse | Needs `tdp-operator`; integration: Ozone S3 disk, `trino`/`superset` users |
| `tdp-cloudbeaver` | CloudBeaver UI | |
| `tdp-deltalake` | Delta Lake | |
| `tdp-hive-metastore` | Hive Metastore | Integration: warehouse on Ozone S3 |
| `tdp-iceberg` | Apache Iceberg | |
| `tdp-jupyter` | JupyterLab | |
| `tdp-kafka` | Apache Kafka (Strimzi) | Needs `tdp-operator` |
| `tdp-nifi` | Apache NiFi | |
| `tdp-openmetadata` | OpenMetadata | |
| `tdp-ozone` | Apache Ozone S3 | Ships with security off (S3 auth disabled); see [Ozone security](#ozone-security) |
| `tdp-postgresql` | PostgreSQL | |
| `tdp-ranger` | Apache Ranger | |
| `tdp-spark` | Apache Spark | Integration: s3a on Ozone S3 |
| `tdp-superset` | Apache Superset | Integration: ClickHouse and Trino datasources |
| `tdp-trino` | Trino SQL engine | Integration: hive, iceberg and clickhouse catalogs |

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| App of Apps: `current: app path does not exist` | `current/` was never pushed | Render and push `current/` |
| Pods `Pending`: `unbound immediate PersistentVolumeClaims` | The PVC has no StorageClass and the cluster has no default | Set `TDP_STORAGE_CLASS` (or mark a default StorageClass), re-render with `--force`, push, then delete the StatefulSet and its unbound PVCs so ArgoCD recreates them |
| `ImagePullBackOff` on a `tdp/` image | No `tdp-registry` Secret in `TDP_NAMESPACE` | `./deploy.sh -c -v variables.env.local` |
| Sync stuck on `waiting for healthy state` | A sync waiting for pods that never become healthy has no timeout, so new commits wait | Fix the cause, then Terminate the operation in the ArgoCD UI; auto-sync starts over |
| Application `OutOfSync` after a push | Not refreshed yet | `kubectl annotate application <name> -n <TDP_PROJECT_NAMESPACE> argocd.argoproj.io/refresh=hard --overwrite` |
| `[tdp-argo] license check failed: …` from `--install`, or `helm install` of a TDP chart | No `tdp-license-operator`, no `PlatformLicense`, or a license that is not VALID | Read the message, fix the license files, run `./deploy.sh --license -v variables.env.local` |
| `kubectl get platformlicense -A` shows `CAPACITY UNDER_LICENSED` | More nodes run licensed TDP pods than the license allows, for longer than 15 minutes. An alert only: nothing is stopped | `kubectl get pods -A -l tecnisys.com/licensed=true -o wide` shows where they run; reduce the nodes TDP runs on, or ask Tecnisys for a license with more nodes |
| Application sync fails on the PreSync hook `<release>-license-check` | Same, for a component synced by ArgoCD | `kubectl -n <TDP_NAMESPACE> logs job/<release>-license-check`; once `kubectl get platformlicense -A` shows VALID, sync again |
| Variables not substituted (`${VAR}` in the cluster) | A template from `available/` or `common/` was applied directly | Always apply or push `current/`, rendered by `deploy.sh` |
| Git or registry authentication errors | Wrong credentials, or an unquoted `$` in `variables.env.local` | Check `kubectl -n <ARGOCD_NAMESPACE> get secret tdp-devops-repo tdp-helm-oci-tdp`; re-run `./deploy.sh -c` |

Debugging a sync:

```bash
# Application events
kubectl describe application <name> -n <TDP_PROJECT_NAMESPACE>

# Application controller logs
kubectl logs -n <ARGOCD_NAMESPACE> -l app.kubernetes.io/name=tdp-argocd-application-controller --tail=100
```

---

## Security

- `variables.env.local`, the rendered `current/common/*-secret.yaml` and the license files in `license/` are in `.gitignore` — never commit tokens or passwords.
- The component passwords default to `ChangeMe!T3c` (`TDP_DEFAULT_PASSWORD`), and `deploy.sh` warns while any of them still does. **Set them before deploying to any real environment.** The rendered `current/<component>/values*.yaml` files hold them in plain text and are committed, so keep the GitOps repository private.
- `values-integration.yaml` points at Ozone's S3 Gateway with security off: the S3 keys there are not real credentials, and any client can read and write. Turn [Ozone security](#ozone-security) on for anything beyond a demo.
- Add TLS to every Ingress, the ArgoCD UI included.
- Use a pull-only robot account for the registry, and rotate the git and registry tokens regularly.
- `TDP_PROJECT_NAMESPACE` should have restricted RBAC: Applications there can deploy anywhere the AppProject allows.
