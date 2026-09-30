# TDP Available Applications

This directory contains ArgoCD application manifests for all available TDP components. Each application uses ArgoCD's **multi-source feature** to deploy external Helm charts with local Git-based configuration.

## Overview

This repository drives the deployment of TDP (Tecnisys Data Platform) components — PostgreSQL, Trino, Kafka, Airflow, Spark, Superset, and others — onto Kubernetes clusters using ArgoCD's App-of-Apps pattern. Application manifests are kept as envsubst templates under available/, rendered per-environment into current/ (the source of truth ArgoCD watches), and reference versioned Helm charts hosted on Tecnisys' OCI registry. A single deploy.sh script handles ArgoCD bootstrap, template rendering, and both GitOps (git-driven) and direct (kubectl apply) deployment modes.

## Architecture

All applications follow the same pattern:

- **External Helm Chart**: Pulled from `registry.tecnisys.com.br/tdp/charts`
- **Local Values**: Managed in Git at `available/<app-name>/values.yaml`
- **Auto-sync**: Changes to values.yaml are automatically applied

## Prerequisites

The components below are **cluster bootstrap dependencies**, not part of this `available/` catalog. They must already be installed before any Application here can be deployed:

| Component | Purpose | How it's installed |
|---|---|---|
| `tdp-crds` | Cluster-wide CRDs (ArgoCD + TDP custom resources) | `deploy.sh --install` |
| `tdp-argo` | ArgoCD itself | `deploy.sh --install` |
| `tdp-license` | License enforcement subsystem (operator/webhook/agent/license-server) | manual `helm install`, by the cluster administrator |
| `tdp-operator` | Shared operator instance required by some components (e.g. `tdp-kafka`, `tdp-clickhouse`) | manual `helm install`, by the cluster administrator |

> `tdp-license` and `tdp-operator` are intentionally **not** part of `deploy.sh --install`. They are installed beforehand via `helm install` directly by the tdp-k8s administrator/operator team, outside of this GitOps flow.

## Available Applications

### Data Processing

- **tdp-spark** - Apache Spark cluster
- **tdp-airflow** - Apache Airflow workflow orchestration
- **tdp-nifi** - Apache NiFi data flow automation

### Data Storage

- **tdp-postgresql** - PostgreSQL database
- **tdp-clickhouse** - ClickHouse analytics database
- **tdp-deltalake** - Delta Lake storage layer
- **tdp-iceberg** - Apache Iceberg table format
- **tdp-kafka** - Apache Kafka streaming
- **tdp-ozone** - Apache Ozone S3-compatible storage

### Data Catalog & Governance

- **tdp-hive-metastore** - Hive Metastore
- **tdp-openmetadata** - OpenMetadata data catalog
- **tdp-ranger** - Apache Ranger security

### Analytics & Visualization

- **tdp-jupyter** - JupyterHub notebooks
- **tdp-superset** - Apache Superset visualization
- **tdp-trino** - Trino distributed SQL engine
- **tdp-cloudbeaver** - CloudBeaver database manager

### Infrastructure

> These are cluster bootstrap prerequisites, installed and managed outside this `available/` catalog (see [Prerequisites](#prerequisites)) — listed here for reference only, not as deployable Applications.

- **tdp-crds** - Cluster-wide CRDs (ArgoCD + TDP custom resources)
- **tdp-argo** - ArgoCD itself
- **tdp-license** - License enforcement subsystem (operator/webhook/agent/license-server)
- **tdp-operator** - Shared operator instance required by some components (e.g. `tdp-kafka`, `tdp-clickhouse`)

## User Workflow

`available/` holds **templates** — files with `${VAR}` placeholders (`${HELM_CHART_REPO_URL}`, `${HELM_CHART_VERSION}`, `${GIT_REPO_URL}`, `${TDP_PROJECT_NAMESPACE}`, …). They are never applied or watched directly; `deploy.sh` must run first, with your `variables.env.local`, to substitute those placeholders and generate the real manifests under `current/` — which is what ArgoCD actually watches.

### 1. Modify Configuration

Edit the `values.yaml` file in the application directory:

```bash
cd available/tdp-spark
vim values.yaml
```

### 2. Render

```bash
cd ../..
./deploy.sh -p -v variables.env.local
```

This substitutes every `${VAR}` in `available/tdp-spark/*.yaml` and writes the result to `current/tdp-spark/`.

### 3. Commit and Push

Commit the **rendered** files in `current/` — not `available/`:

```bash
git add current/tdp-spark/
git commit -m "Update Spark worker replicas to 5"
git push origin main
```

### 4. Automatic Deployment

ArgoCD (App of Apps) watches `current/` directly from git and, with `selfHeal: true`, automatically:

- Detects the Git change
- Pulls the external Helm chart
- Applies your rendered values
- Deploys to Kubernetes

## Multi-Source Configuration

Each application manifest uses this structure (from the real `available/tdp-kafka/tdp-kafka.yaml` template):

```yaml
sources:
- repoURL: ${HELM_CHART_REPO_URL}
  targetRevision: ${HELM_CHART_VERSION}
  chart: <app-name>
  helm:
    valueFiles:
    - $values/current/<app-name>/values.yaml

- repoURL: '${GIT_REPO_URL}'
  targetRevision: main
  ref: values
```

Note the `valueFiles` path points at `current/`, not `available/` — the values file only exists there once `deploy.sh -p` has rendered it.

This allows:
✅ External Helm charts (maintained separately)
✅ Local configuration (Git-based GitOps)
✅ Automatic synchronization
✅ Full Git history and rollback capability

## Deploying Applications

To deploy an application, render it and push `current/` — never `mv`/copy `available/` files directly, since they still contain unsubstituted `${VAR}` placeholders:

```bash
./deploy.sh -p -v variables.env.local tdp-spark   # render only this component
git add current/tdp-spark/
git commit -m "Deploy Spark to production"
git push origin main
```

The App of Apps monitors the `current/` directory and will automatically deploy the application once the rendered manifest is pushed.
