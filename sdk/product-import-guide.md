# IBM BYOP SDK — Product Import Guide for Standalone OpenShift Clusters

**Audience:** IBM internal users  
**Platform:** Standalone OpenShift cluster

---

## Table of Contents

1. [Introduction](#introduction)
2. [Assumptions](#assumptions)
3. [Prerequisites](#prerequisites)
4. [Importing Images and Charts](#importing-images-and-charts)
5. [Product Import](#product-import)
6. [Creating an Instance](#creating-an-instance)
7. [More Information](#more-information)
8. [Appendix — Commands Reference](#appendix--commands-reference)

---

## Introduction

The BYOP (Bring Your Own Product) SDK enables IBM product teams to register and expose their products through a centralised service broker running on OpenShift. This guide explains how to import a product into a **standalone OpenShift cluster**.

The overall flow involves:

1. Standing up the required registry infrastructure (Quay, backed by MinIO object storage) on the cluster.
2. Mirroring the BYOP SDK product images from IBM Container Registry (ICR) into that internal Quay registry.
3. Deploying the BYOP service broker and operator via a Helm chart.
4. Registering (importing) your product through the service broker.
5. Creating a running instance of your imported product.

---

## Assumptions

- You are an IBM internal user with access to the BYOP SDK artefacts on IBM Container Registry (`icr.io/automation-saas-platform`).
- You have cluster-admin privileges on the target OpenShift cluster.
- The target cluster is **standalone** — it is not connected to IBM Cloud or any managed OpenShift service (ROKS, ARO, etc.).
- A Quay registry backed by MinIO object storage is, or will be, deployed on the cluster to serve as the internal image registry.
- ArgoCD (OpenShift GitOps) is, or will be, available on the cluster for GitOps-based continuous delivery.
- cert-manager is, or will be, installed on the cluster for TLS certificate provisioning.
- You have an IBM Cloud API key with read access to `icr.io/automation-saas-platform`.

---

## Prerequisites

Before importing a product, ensure the following infrastructure and tooling are in place.

### Cluster Requirements

| Requirement | Detail |
|---|---|
| OpenShift version | 4.x (tested on 4.22.8) |
| Worker nodes | At least 3 nodes with ~14 GiB RAM each |
| Cluster admin access | Required for registry and operator setup |

### Local Tooling

| Tool | Purpose |
|---|---|
| `oc` CLI | Interact with the OpenShift cluster; must be logged in as cluster-admin |
| `podman` | Pull, tag, and push container images |
| `helm` v3.8 or later | Package and deploy the BYOP Helm chart (OCI support is GA from v3.8) |
| `skopeo` *(optional)* | Direct registry-to-registry image mirroring as an alternative to podman |
| Go | Required only if rebuilding the MinIO binary from source |
| IBM Cloud CLI (`ibmcloud`) | Authenticate with ICR to pull BYOP product images |

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

> **Note:** This guide assumes all infrastructure components listed above are already operational before proceeding to the sections below.

### Product Listing in the Sovereign Core Catalog

Before a product can be imported, its details must be registered in the [IBM Sovereign Core Catalog](https://github.com/IBM/sovereign-core-catalog) — the public repository that serves as the source of truth for all products available for import.

Each product is defined by a `metadata.yaml` file located under `components/<category>/<vendor>/<product-name>/<version>/` in the repository. This file describes the product's identity, deployment format, architecture requirements, and security posture using the `SoftwareListing` schema. The BYOP service broker reads from this catalog to resolve product metadata at import time.

Ensure the product you intend to import has a valid and published `metadata.yaml` entry in the catalog before proceeding.

---

## Importing Images and Charts

Before the service broker can be deployed, the product container images and Helm chart must be available in the on-cluster Quay registry.

### Step 1 — Mirror product images from ICR to Quay

1. Authenticate with IBM Cloud and ICR using your IBM Cloud API key.
2. Set the target Quay registry URL, your Quay organisation, Quay credentials, and the image tag as environment variables.
3. Pull the `byop-service-broker` and `byop-service-broker-operator` images from `icr.io/automation-saas-platform`.
4. Tag both images for your Quay registry and organisation.
5. Push both tagged images to Quay.

An alternative to the pull-tag-push workflow is direct registry-to-registry mirroring using `skopeo copy`, which avoids storing images locally.

### Step 2 — Push the BYOP Helm chart to Quay

1. Create a values override file (e.g. `overrides/byop-sdk.yaml`) with your environment-specific configuration such as registry URL, image tags, and namespace settings.
2. From the `charts/` directory, package the Helm chart with `helm package`.
3. Trust the OpenShift ingress CA on your local machine so that Helm can connect to the Quay OCI endpoint.
4. Log in to the Quay OCI registry with `helm registry login`.
5. Push the packaged chart to your Quay organisation with `helm push`.

---

## Product Import

Product import means importing the product e.g mariadb to openshift cluster. Please refer to https://github.ibm.com/Sovereign-Core/sovereign-core-catalog-internal/blob/main/sdk/readme.md for more informaton.

---

## Creating an Instance

After the service broker is running and your product has been imported, you can create a running instance of the product. Please refer to https://github.ibm.com/Sovereign-Core/sovereign-core-catalog-internal/blob/main/sdk/readme.md for more informaton.

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

### A.1 Infrastructure Prerequisites

#### Expose the internal OpenShift image registry

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'

# Get the registry route
oc get route -n openshift-image-registry
```

Log in to the internal registry:

```bash
oc whoami -t | podman login <REGISTRY_ROUTE> \
  -u kubeadmin \
  --password-stdin \
  --tls-verify=false
```

#### Build and push the MinIO image

Log in to the Red Hat registry:

```bash
podman login registry.redhat.io
```

Clone and build the MinIO binary for Linux amd64:

```bash
git clone https://github.com/minio/minio.git /tmp/minio-src
cd /tmp/minio-src
GOOS=linux GOARCH=amd64 go build -o /tmp/minio-linux .
```

Build a UBI-based container image:

```bash
cat <<EOF > /tmp/Containerfile
FROM registry.redhat.io/ubi9/ubi-minimal:latest

COPY minio-linux /usr/local/bin/minio
RUN chmod +x /usr/local/bin/minio

RUN microdnf install -y shadow-utils && \
    useradd -m -u 1001 minio && \
    microdnf clean all

USER 1001

EXPOSE 9000 9001

ENTRYPOINT ["/usr/local/bin/minio"]
CMD ["server", "/data", "--console-address", ":9001"]
EOF

cd /tmp && podman build -f Containerfile -t minio-ubi9:latest .
```

Push to the internal OpenShift registry:

```bash
oc new-project minio
podman tag localhost/minio-ubi9:latest <REGISTRY_ROUTE>/minio/minio-ubi9:latest
podman push <REGISTRY_ROUTE>/minio/minio-ubi9:latest --tls-verify=false
```

#### Deploy MinIO

Create a PersistentVolume for MinIO data:

```bash
oc debug node/<worker-node> -- chroot /host mkdir -p /mnt/minio-data

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local:
    path: /mnt/minio-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <worker-node-hostname>
EOF
```

Create the PVC:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  volumeMode: Filesystem
  storageClassName: ""
  volumeName: minio-pv
EOF
```

Deploy MinIO and expose routes:

```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: image-registry.openshift-image-registry.svc:5000/minio/minio-ubi9:latest
          args:
            - server
            - /data
            - --console-address
            - ":9001"
          env:
            - name: MINIO_ROOT_USER
              value: minioadmin
            - name: MINIO_ROOT_PASSWORD
              value: minioadmin
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
EOF

oc create route edge minio-api --service=minio --port=9000 -n minio
oc create route edge minio-console --service=minio --port=9001 -n minio
```

#### Install the Quay Operator

```bash
oc new-project quay-enterprise

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay-operator-group
  namespace: quay-enterprise
spec:
  targetNamespaces:
    - quay-enterprise
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  channel: stable-3.13
  name: quay-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Verify operator is ready (wait for Succeeded)
oc get csv -n quay-enterprise
```

#### Create Persistent Volumes for Quay databases

```bash
oc debug node/<worker0> -- chroot /host mkdir -p /mnt/quay-postgres
oc debug node/<worker1> -- chroot /host mkdir -p /mnt/clair-postgres

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: quay-postgres-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local:
    path: /mnt/quay-postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <worker0-hostname>
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: clair-postgres-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local:
    path: /mnt/clair-postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <worker1-hostname>
EOF
```

#### Deploy the Quay Registry

Create the config bundle secret:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: quay-config-bundle
  namespace: quay-enterprise
stringData:
  config.yaml: |
    SUPER_USERS:
      - <your-admin-username>
    DISTRIBUTED_STORAGE_CONFIG:
      default:
        - RadosGWStorage
        - access_key: minioadmin
          secret_key: minioadmin
          bucket_name: quay
          hostname: minio.minio.svc.cluster.local
          port: 9000
          is_secure: false
          storage_path: /datastorage/registry
    DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: []
    DISTRIBUTED_STORAGE_PREFERENCE:
      - default
EOF
```

Create the QuayRegistry CR:

```bash
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  configBundleSecret: quay-config-bundle # pragma: allowlist secret
  components:
    - kind: clair
      managed: true
    - kind: postgres
      managed: true
    - kind: objectstorage
      managed: false
    - kind: redis
      managed: true
    - kind: horizontalpodautoscaler
      managed: false
    - kind: route
      managed: true
    - kind: monitoring
      managed: false
    - kind: tls
      managed: true
    - kind: quay
      managed: true
    - kind: mirror
      managed: false
    - kind: clairpostgres
      managed: true
EOF
```

Bind PVCs to PVs:

```bash
oc patch pvc quay-quay-postgres-13 -n quay-enterprise \
  -p '{"spec":{"storageClassName":"","volumeName":"quay-postgres-pv"}}' --type=merge

oc patch pvc quay-clair-postgres-15 -n quay-enterprise \
  -p '{"spec":{"storageClassName":"","volumeName":"clair-postgres-pv"}}' --type=merge
```

Verify all pods are running:

```bash
oc get pods -n quay-enterprise
```

---

### A.2 Importing Images and Charts

#### Step 1 — Mirror product images from ICR to Quay

Authenticate with IBM Cloud and ICR:

```bash
ibmcloud login --apikey <YOUR_API_KEY> -r global
ibmcloud cr region-set global
ibmcloud cr login --client podman
```

Set environment variables:

```bash
export QUAY_REGISTRY=$(oc get route quay-quay -n quay-enterprise -o jsonpath='{.spec.host}')
export QUAY_USER="<your-quay-username>"
export QUAY_PASSWORD="<your-quay-password>" # pragma: allowlist secret
export QUAY_ORG="<your-quay-organisation>"
export TAG="<image-tag>"
```

Pull images from ICR:

```bash
podman pull icr.io/automation-saas-platform/byop-service-broker:${TAG}
podman pull icr.io/automation-saas-platform/byop-service-broker-operator:${TAG}
```

Log in to Quay:

```bash
podman login ${QUAY_REGISTRY} -u "${QUAY_USER}" -p "${QUAY_PASSWORD}" --tls-verify=false
```

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
podman push --remove-signatures --tls-verify=false \
  ${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker:${TAG}

podman push --remove-signatures --tls-verify=false \
  ${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker-operator:${TAG}
```

**Alternative: direct registry-to-registry mirroring with Skopeo**

```bash
skopeo copy --all --remove-signatures \
  --src-authfile ~/.config/containers/auth.json \
  --dest-creds "${QUAY_USER}:${QUAY_PASSWORD}" \
  --dest-tls-verify=false \
  docker://icr.io/automation-saas-platform/byop-service-broker:${TAG} \
  docker://${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker:${TAG}

skopeo copy --all --remove-signatures \
  --src-authfile ~/.config/containers/auth.json \
  --dest-creds "${QUAY_USER}:${QUAY_PASSWORD}" \
  --dest-tls-verify=false \
  docker://icr.io/automation-saas-platform/byop-service-broker-operator:${TAG} \
  docker://${QUAY_REGISTRY}/${QUAY_ORG}/byop-service-broker-operator:${TAG}
```

#### Step 2 — Push the BYOP Helm chart to Quay

Trust the OpenShift ingress CA (macOS):

```bash
oc get secret -n openshift-ingress-operator router-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/quay-ca.crt

sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/quay-ca.crt
```

> On Linux, copy `/tmp/quay-ca.crt` to `/etc/pki/ca-trust/source/anchors/` and run `sudo update-ca-trust`.

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

### A.3 Product Import — Deploy the BYOP Service Broker

Install cert-manager:

```bash
oc apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

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
