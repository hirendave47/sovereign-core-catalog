# IBM BYOP SDK — Product Import Guide for Standalone OpenShift Clusters

**Audience:** IBM internal users  
**Platform:** Standalone OpenShift cluster

---

## Table of Contents

1. [Introduction](#introduction)
2. [Assumptions](#assumptions)
3. [Prerequisites](#prerequisites)
4. [Importing Images and Charts](#importing-images-and-charts)
5. [Product Import and Instance Creation](#product-import-and-instance-creation)
6. [More Information](#more-information)
7. [Appendix — Commands Reference](#appendix--commands-reference)

---

## Introduction

The BYOP (Bring Your Own Product) SDK enables IBM product teams to register and expose their products through a centralized service broker running on OpenShift. This guide explains how to import a product into a **standalone OpenShift cluster**.

The overall flow involves:

1. Setting up the required registry infrastructure (Quay, backed by MinIO object storage) on the cluster. This step is optional if you already have a Quay registry set up on your OpenShift cluster that can be reused.
2. Mirroring the BYOP Broker images from IBM Container Registry (ICR) into that internal Quay registry. If you have access to a IBM Sovereign Core installation, then, these images are also available in the `sovcloud` organization of a Quay registry on an OpenShift cluster where Sovereign Core is installed.
3. Deploying the BYOP service broker and operator via a Helm chart. These charts are also available in the `sovcloud` organization of a Quay registry on an OpenShift cluster where Sovereign Core is installed.
4. Registering (importing) your product through the service broker.
5. Creating a running instance of your imported product.

---

## Assumptions

> **Note:** Quay, ArgoCD, and cert-manager are not part of the BYOP Broker and must be installed separately. If you do not have access to IBM Container Registry (`icr.io`), you can copy the BYOP Broker and operator images and Helm charts from a Quay registry of an existing Sovereign Core installation. They are available in the `sovcloud` organization.

- You are an IBM internal user with access to the BYOP SDK artifacts on IBM Container Registry (`icr.io/automation-saas-platform`).
- You have cluster-admin privileges on the target OpenShift cluster.
- The target cluster is **standalone** — it is not connected to IBM Cloud or any managed OpenShift service (ROKS, ARO, etc.).
- A Quay registry is already available, or will be, deployed on the cluster to serve as the internal image registry.
- ArgoCD (OpenShift GitOps) is already available, or will be, available on the cluster for GitOps-based continuous delivery.
- cert-manager is, or will be, installed on the cluster for TLS certificate provisioning.
- You have an IBM Cloud API key with read access to `icr.io/automation-saas-platform`.

---

## Prerequisites

Before importing a product, ensure the following infrastructure and tooling are in place.

### Cluster Requirements

| Requirement | Detail |
|---|---|
| OpenShift cluster | See the IBM Sovereign Core documentation for supported OpenShift versions |
| Worker nodes | At least 3 nodes with ~14 GiB RAM each |
| Cluster admin access | Required for registry and operator setup |

### Local Tooling

| Tool | Purpose |
|---|---|
| `oc` CLI | Interact with the OpenShift cluster; must be logged in as cluster-admin |
| `podman` | Pull, tag, and push container images |
| `helm` v3.8 or later | Package and deploy the BYOP Helm chart (OCI support is GA from v3.8) |
| `skopeo` *(optional)* | Direct registry-to-registry image mirroring as an alternative to podman |

### Accounts and Credentials

| Credential | Purpose |
|---|---|
| Red Hat account | Pull base images from `registry.redhat.io` |
| IBM Cloud API key | Authenticate with ICR (`icr.io`) to pull BYOP product images |
| Quay superuser credentials | Push mirrored images and Helm charts into the on-cluster Quay registry |

### Infrastructure Components (must be deployed before product import)

The following components must be running on the cluster before you begin the product import process.

| Component | Purpose |
|---|---|
| Internal OpenShift image registry (exposed route) | Bootstrap image storage before Quay is available |
| MinIO (object storage) | Provides the S3-compatible backend required by Quay |
| Quay Operator + QuayRegistry | On-cluster container image registry for mirrored images and Helm charts. Must be installed in the `quay-enterprise` namespace with a `QuayRegistry` CR deployed via OperatorHub. |
| ArgoCD (OpenShift GitOps Operator) | GitOps-based deployment of the BYOP service broker |
| cert-manager | TLS certificate provisioning for the service broker |
| git | Git client |

> **Note:** This guide assumes all infrastructure components listed above are already operational before proceeding to the sections below.

### Product Listing in the Sovereign Core Catalog

 [IBM Sovereign Core Catalog](https://github.com/IBM/sovereign-core-catalog) — the public repository contains list of software including samples which can be deployed.

---

## Importing Images and Charts

Before the service broker can be deployed, the product container images and Helm chart must be available in the on-cluster Quay registry.

### Step 0 — Trust the OpenShift ingress CA

Trust the OpenShift ingress CA on your local machine so that podman, skopeo, and Helm can connect to the Quay registry over TLS. Do this before Step 1.

### Step 1 — Mirror product images from ICR to Quay

1. Authenticate with IBM Cloud and ICR using your IBM Cloud API key.
2. Set the target Quay registry URL, your Quay organization, Quay credentials, and the image tag as environment variables.
3. Pull the `byop-service-broker` and `byop-service-broker-operator` images from `icr.io/automation-saas-platform`.
4. Tag both images for your Quay registry and organization.
5. Push both tagged images to Quay.

An alternative to the pull-tag-push workflow is direct registry-to-registry mirroring using `skopeo copy`, which avoids storing images locally.

### Step 2 — Push the BYOP Helm chart to Quay

1. Create a values override file (e.g. `overrides/byop-sdk.yaml`) with your environment-specific configuration such as registry URL, image tags, and namespace settings.
2. From the `charts/` directory, package the Helm chart with `helm package`.
3. Log in to the Quay OCI registry with `helm registry login`.
4. Push the packaged chart to your Quay organization with `helm push`.

---

## Product Import and Instance Creation

Product import means registering a product (e.g. MariaDB) with the BYOP service broker on the OpenShift cluster. It involves the following steps:

1. Log in to the target OpenShift cluster with `oc login`.
2. Change to the `sdk` directory.
3. Copy `scripts/import.sh` to the current directory.
4. Copy `scripts/import.env.example` to `import.env` in the current directory and make appropriate changes.
5. The script `run-import.sh` lets you skip some or all steps of the import process. Based on the product that you are importing, set the step variables to true/false.
6. Execute the `run-import.sh` script, e.g. (for MariaDB):
   $ ./run-import.sh mariadb

To provision an instance, perform the following steps:

1. To create an instance of the product in the OpenShift cluster, you need to create
   a json file for your product describing the instance parameters. A sample json file for 'mariadb' has been provided.
   > **Note:** The sample `mariadb.provision.json` contains placeholder passwords (`change-me-password`, `change-me-root-password`). Replace them with strong, unique values before provisioning, and do not commit real credentials.

2. To provision an instance (e.g. mariadb):
   $ ./provision-portforward.sh mariadb
3. To deprovision an instance
   $ ./deprovision-portforward.sh mariadb

---

## More Information

| Resource | Link |
|---|---|
| Quay documentation | [https://docs.redhat.com/en/documentation/red_hat_quay](https://docs.redhat.com/en/documentation/red_hat_quay) |
| OpenShift GitOps (ArgoCD) documentation | [https://docs.redhat.com/en/documentation/red_hat_openshift_gitops](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops) |
| cert-manager documentation | [https://cert-manager.io/docs](https://cert-manager.io/docs) |
| IBM Cloud Container Registry (ICR) | [https://cloud.ibm.com/docs/Registry](https://cloud.ibm.com/docs/Registry) |
| OpenShift Service Catalog | [https://docs.openshift.com/container-platform/latest/applications/service_brokers/installing-service-catalog.html](https://docs.openshift.com/container-platform/latest/applications/service_brokers/installing-service-catalog.html) |
| Helm OCI registry support | [https://helm.sh/docs/topics/registries](https://helm.sh/docs/topics/registries) |

For internal support, raise an issue in the BYOP SDK repository or contact the BYOP SDK team via the internal IBM Slack channel.

---

## Appendix — Commands Reference

This appendix provides the exact commands for each step described in this guide.

---

### A.1 Importing Images and Charts

#### Step 0 — Trust the OpenShift ingress CA

Trust the OpenShift ingress CA (macOS):

```bash
oc get secret -n openshift-ingress-operator router-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/quay-ca.crt

sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/quay-ca.crt
```

> On Linux, copy `/tmp/quay-ca.crt` to `/etc/pki/ca-trust/source/anchors/` and run `sudo update-ca-trust`.

#### Step 1 — Mirror product images from ICR to Quay

Authenticate with IBM Cloud and ICR. Export your API key as an environment variable (for example, read from your secrets manager) so it does not appear in the command line or shell history; the `ibmcloud` CLI reads `IBMCLOUD_API_KEY` automatically:

```bash
export IBMCLOUD_API_KEY="<your-ibm-cloud-api-key>" # pragma: allowlist secret
ibmcloud login -r global
ibmcloud cr region-set global
ibmcloud cr login --client podman
```

Set environment variables:

```bash
export QUAY_REGISTRY=$(oc get route quay-quay -n quay-enterprise -o jsonpath='{.spec.host}')
export QUAY_USER="<your-quay-username>"
export QUAY_PASSWORD="<your-quay-password>" # pragma: allowlist secret
export QUAY_ORG="<your-quay-organization>"
export TAG="<image-tag>"
```

Pull images from ICR:

```bash
podman pull icr.io/automation-saas-platform/byop-service-broker:${TAG}
podman pull icr.io/automation-saas-platform/byop-service-broker-operator:${TAG}
```

Log in to Quay:

```bash
echo "${QUAY_PASSWORD}" | podman login ${QUAY_REGISTRY} -u "${QUAY_USER}" --password-stdin --tls-verify=false
```

> **Security note:** `--tls-verify=false` disables TLS certificate verification. It is kept on the login commands only as a bootstrap fallback in case the ingress CA from [Step 0](#step-0--trust-the-openshift-ingress-ca) is not yet trusted by podman or skopeo on your machine. Remove it once the CA is trusted.

Tag images for Quay:

```bash
podman tag \
  icr.io/automation-saas-platform/byop-service-broker:${TAG} \
  ${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker:${TAG}

podman tag \
  icr.io/automation-saas-platform/byop-service-broker-operator:${TAG} \
  ${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker-operator:${TAG}
```

Push images to Quay:

```bash
podman push --remove-signatures \
  ${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker:${TAG}

podman push --remove-signatures \
  ${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker-operator:${TAG}
```

> **Note:** If the OpenShift ingress CA is not yet trusted by podman, the push fails with an `x509` certificate error. In that case only, add `--tls-verify=false` to the push commands as a temporary bootstrap measure.

**Alternative: direct registry-to-registry mirroring with Skopeo**

Log in to Quay, storing the credentials in the same auth file used for the ICR login:

```bash
echo "${QUAY_PASSWORD}" | skopeo login ${QUAY_REGISTRY} -u "${QUAY_USER}" --password-stdin \
  --authfile ~/.config/containers/auth.json --tls-verify=false
```

Copy the images:

```bash
skopeo copy --all --remove-signatures \
  --authfile ~/.config/containers/auth.json \
  docker://icr.io/automation-saas-platform/byop-service-broker:${TAG} \
  docker://${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker:${TAG}

skopeo copy --all --remove-signatures \
  --authfile ~/.config/containers/auth.json \
  docker://icr.io/automation-saas-platform/byop-service-broker-operator:${TAG} \
  docker://${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker-operator:${TAG}
```

> **Note:** If the OpenShift ingress CA is not yet trusted, add `--dest-tls-verify=false` to the `skopeo copy` commands as a temporary bootstrap measure only.

#### Step 2 — Push the BYOP Helm chart to Quay

Log in to the Quay OCI registry:

```bash
helm registry login <QUAY_REGISTRY>
```

Package the Helm chart (run from the `charts/` directory):

```bash
helm package .
```

Push the chart to Quay:

```bash
helm push byop-service-broker-<version>.tgz oci://<QUAY_REGISTRY>/<QUAY_ORG>
```

---

### A.2 Deploy the BYOP Service Broker

Install cert-manager:

```bash
oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml

oc wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

Create the values override file at `overrides/byop-sdk.yaml` with your environment-specific settings:

```yaml
# overrides/byop-sdk.yaml
global:
  registry: <QUAY_REGISTRY>/<QUAY_ORG>
  tag: <image-tag>

namespace: byop-service-broker
```

> Adjust the keys and values to match the parameters defined in the chart's `values.yaml`.

Install the BYOP service broker from the Quay OCI registry:

```bash
helm upgrade --install byop-service-broker \
  oci://<QUAY_REGISTRY>/<QUAY_ORG>/byop-service-broker \
  --version <chart-version> \
  --namespace byop-service-broker \
  --create-namespace \
  -f overrides/byop-sdk.yaml
```

Verify the installation:

```bash
# Check Helm release status
helm list -n byop-service-broker

# Check all pods are Running
oc get pods -n byop-service-broker

# Check the service broker service
oc get svc -n byop-service-broker
```
