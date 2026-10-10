# Deploying IBM QRadar SIEM using the IBM Sovereign Core Service Catalog

## End User Guide

This guide explains how to provision and manage **IBM QRadar SIEM 7.6.0** by using the **IBM Sovereign Core Service Catalog (GitOps CSB Broker Web Interface)**.

The IBM Sovereign Core Service Catalog provides self-service deployment of enterprise services onto OpenShift clusters through GitOps. QRadar SIEM is deployed on **OpenShift Virtualization by using Helm charts**.

> **Service model:** The Service Catalog documentation describes this capability as a **Tech Preview available under a try-and-buy model**. Deployment is self-service and **IBM Support is not included**.

---

## 1. Overview

QRadar SIEM is available through the Service Catalog in two deployment topologies:

| Deployment topology | Available plans | Networking | VM topology | Typical use |
|---|---|---|---|---|
| **Standalone** | Tiny, Small, Medium, Large | DHCP | One Console VM | Development, sandbox, test, QA, staging, or standalone monitoring |
| **High Availability (HA)** | Small HA, Medium HA, Large HA | Fixed `10.0.0.x` private synchronization network | Primary + Secondary VMs | Production and enterprise HA deployments |

The HA plans provide a primary and secondary VM pair connected through the private synchronization network for automatic failover.

### Plan selection

The Service Catalog provides the following plans:

| Plan type | Plan | Target environment | Networking | Topology |
|---|---|---|---|---|
| Standalone | **Tiny** | Development / Sandbox | DHCP | 1 Console VM |
| Standalone | **Small** | Test / QA | DHCP | 1 Console VM |
| Standalone | **Medium** | Staging / Mid-tier | DHCP | 1 Console VM |
| Standalone | **Large** | High-throughput standalone | DHCP | 1 Console VM |
| High Availability | **Small HA** | Small Production | Fixed `10.0.0.x` sync | 2 VMs (Primary + Secondary) |
| High Availability | **Medium HA** | Enterprise Production | Fixed `10.0.0.x` sync | 2 VMs (Primary + Secondary) |
| High Availability | **Large HA** | High-capacity Enterprise HA | Fixed `10.0.0.x` sync | 2 VMs (Primary + Secondary) |

---

## 2. Prerequisites

### 2a. Platform administrator — one-time cluster setup

> **Who performs this step:** A cluster administrator, not the end user. This step is required **once per cluster** before any QRadar instance can be provisioned. If your cluster administrator confirms these secrets are already in place, skip to [Section 2b](#2b-end-user-information).

QRadar VM images are stored in a private container registry (Quay). Two secrets must exist in the `qradar-media` namespace so that:

- The **CDI importer** can pull the golden disk image to create the VM root volume (`quay-cdi-secret`).
- The **KubeVirt virt-launcher** pod can pull the installation ISO image at VM startup (`quay-pull-secret`).

These secrets are **never stored in Git**. They must be created directly on the cluster using the following commands:

```bash
# Set your environment variables
REGISTRY="<quay-registry-host>"   # e.g. registry-quay-quay-enterprise.apps.<cluster-domain>
QUAY_USER="<quay-username>"
QUAY_PASS="<quay-password>"

# Ensure the qradar-media namespace exists
oc create namespace qradar-media --dry-run=client -o yaml | oc apply -f -

# Secret 1: quay-pull-secret
# Used by the KubeVirt virt-launcher pod to pull the QRadar installation ISO containerDisk image.
oc create secret docker-registry quay-pull-secret \
  --docker-server="${REGISTRY}" \
  --docker-username="${QUAY_USER}" \
  --docker-password="${QUAY_PASS}" \
  -n qradar-media

# Secret 2: quay-cdi-secret
# Used by the CDI importer pod to pull the golden disk image into a DataVolume (block PVC).
# Note: CDI requires an Opaque secret with accessKeyId and secretKey keys — it does NOT
# read kubernetes.io/dockerconfigjson format.
oc create secret generic quay-cdi-secret \
  --from-literal=accessKeyId="${QUAY_USER}" \
  --from-literal=secretKey="${QUAY_PASS}" \
  -n qradar-media
```

**Verify the secrets were created:**

```bash
oc get secret quay-pull-secret quay-cdi-secret -n qradar-media
```

Expected output:

```text
NAME               TYPE                             DATA   AGE
quay-pull-secret   kubernetes.io/dockerconfigjson   1      10s
quay-cdi-secret    Opaque                           2      8s
```

> **How it works at provision time:** When a user provisions a QRadar instance, the Helm chart runs a Kubernetes Job (`quay-secret-copy`) as an ArgoCD sync hook. This Job copies both secrets from `qradar-media` into the new instance namespace automatically — no manual action is required per instance.

---

### 2b. Platform administrator — configure the tool image for the secret-copy Job

> **Who performs this step:** A cluster administrator. This step is required **once per cluster** and must be completed before the first QRadar instance is provisioned. It ensures the `quay-secret-copy` Job can start successfully on that cluster.

The Helm chart uses a small container image to run `oc` commands inside the `quay-secret-copy` Job. The image to use depends on what container registries are accessible from your cluster. An incorrect image causes the Job to fail with `ImagePullBackOff`, which blocks the entire ArgoCD sync.

#### Choosing the correct tool image

| Option | Image | When to use | Auth required |
|--------|-------|-------------|---------------|
| **A** | `registry.redhat.io/openshift4/ose-cli:latest` | Cluster has a global Red Hat pull secret | Yes — Red Hat subscription |
| **B** | `image-registry.openshift-image-registry.svc:5000/openshift/cli:latest` | Cluster has the internal OpenShift image registry deployed | No — uses in-cluster SA token |
| **C** ✅ **Recommended** | `quay.io/openshift/origin-cli:latest` | Cluster has outbound access to `quay.io` (most clusters) | No |
| **D** | `<your-mirror>/openshift4/ose-cli:latest` | Fully air-gapped — no access to `registry.redhat.io` or `quay.io` | Yes — set `toolImage.pullSecret` |

**To verify which option applies to your cluster:**

```bash
# Option A — check for a Red Hat pull secret
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | python3 -m json.tool | grep 'registry.redhat.io'

# Option B — check whether the internal registry is deployed and running
oc get configs.imageregistry.operator.openshift.io cluster \
  -o jsonpath='{.spec.managementState}'
# Expected output: Managed  (if "Removed", Option B is unavailable)

# Option C — check outbound access to quay.io
curl -sk https://quay.io/v2/ | head -c 50
# Expected output: true  (if unreachable, use Option D)
```

#### Setting the tool image in the instance values

The tool image is configured in the instance `values.yaml` file under `instances/qradar/<instance-name>/values.yaml` in the GitOps repository. Add or update the `toolImage` block to match your cluster:

```yaml
# Option C — recommended (quay.io, no auth required)
toolImage:
  repository: quay.io/openshift/origin-cli
  tag: latest
  pullPolicy: IfNotPresent
  pullSecret: ""

# Option B — internal OpenShift registry (requires ManagementState: Managed)
# toolImage:
#   repository: image-registry.openshift-image-registry.svc:5000/openshift/cli
#   tag: latest
#   pullPolicy: IfNotPresent
#   pullSecret: ""

# Option A — Red Hat registry (requires global pull secret)
# toolImage:
#   repository: registry.redhat.io/openshift4/ose-cli
#   tag: latest
#   pullPolicy: IfNotPresent
#   pullSecret: ""

# Option D — private/mirrored registry (set pullSecret to existing Secret name)
# toolImage:
#   repository: my-mirror.example.com/openshift4/ose-cli
#   tag: latest
#   pullPolicy: IfNotPresent
#   pullSecret: "my-mirror-pull-secret"
```

> **`pullSecret`** must be the **name** of a pre-existing `kubernetes.io/dockerconfigjson` Secret in the instance namespace. Credentials are never stored directly in `values.yaml`.

After editing the instance `values.yaml`, commit and push the change to the GitOps repository. ArgoCD picks up the change on the next sync cycle. Delete the stuck Job (if any) to force an immediate re-run:

```bash
oc delete job quay-secret-copy -n <instance-namespace>
```

---

### 2c. Platform administrator — configure the StorageClass

> **Who performs this step:** A cluster administrator. This step is required **once per cluster** before the first QRadar instance is provisioned. An incorrect StorageClass causes the DataVolume PVC to remain `Pending` indefinitely.

QRadar VM root disks are provisioned as PersistentVolumeClaims by the CDI importer. The StorageClass must support **ReadWriteOnce (RWO) block storage**.

#### Finding the correct StorageClass

```bash
# List all StorageClasses on your cluster
oc get sc

# Identify the default (marked with "(default)")
# or look for a RWO block-capable class
```

#### Common StorageClass values

| Option | StorageClass name | Typical environment |
|--------|-------------------|---------------------|
| **A** | `ocs-storagecluster-ceph-rbd` | IBM-deployed clusters with OpenShift Data Foundation (ODF/OCS) |
| **B** | `ceph-rbd-platform` | Fyre, demo, and some partner-deployed clusters |
| **C** ✅ **Chart default** | `""` *(empty — uses cluster default)* | Any cluster with a defined default StorageClass |

#### Setting the StorageClass in the instance values

Add or update the `storage.storageClassName` field in `instances/qradar/<instance-name>/values.yaml` in the GitOps repository:

```yaml
# Option C — Chart default: use the cluster default StorageClass (no override needed)
# storage:
#   storageClassName: ""

# Option A — ODF/OCS (explicit override for IBM-deployed clusters)
# storage:
#   storageClassName: ocs-storagecluster-ceph-rbd

# Option B — Platform Ceph RBD (explicit override for Fyre / demo clusters)
# storage:
#   storageClassName: ceph-rbd-platform
```

After editing, commit and push to the GitOps repository. ArgoCD picks up the change on the next sync. If the DataVolume is already stuck in `Pending`, delete it to force re-creation:

```bash
# Standalone instances
oc delete datavolume qradar-primary-rootdisk -n <instance-namespace>
oc delete pvc qradar-primary-rootdisk -n <instance-namespace>

# HA instances — delete both primary and secondary
oc delete datavolume qradar-primary-rootdisk qradar-secondary-rootdisk -n <instance-namespace>
oc delete pvc qradar-primary-rootdisk qradar-secondary-rootdisk -n <instance-namespace>
```

---

### 2d. End user information

Before provisioning QRadar, make sure you have the following information:

1. **Service Catalog access**
   - Service Catalog URL.
   - Credentials to access the catalog.

2. **Target cluster information**
   - OpenShift cluster name or identifier where QRadar will be deployed.

3. **Network information**
   - Primary DNS server IP address.
   - Secondary DNS server IP address, when available.
   - Required timezone, for example `UTC`, `America/New_York`, or `Europe/London`.

4. **QRadar credentials**
   - Password for the QRadar Web Console `admin` user.
   - Password for the underlying operating system `root` user.

> **Credential handling:** Save the `admin_password` and `root_password` securely. These passwords cannot be retrieved in plain text from the Service Catalog UI after provisioning.

---

## 3. Provisioning Procedure

### Step 1: Open the Service Catalog

1. Open a browser.
2. Navigate to the IBM Sovereign Core Service Catalog web portal.
3. In the top navigation, open **Available Services**.

The catalog URL is environment-specific. An example format is:

```text
https://byop-catalog-app-byop.apps.<cluster-domain>/
```

### Step 2: Select the QRadar Service and Plan

1. Locate the **QRadar SIEM (Helm)** service card.
2. Review the available plans.
3. Select the plan that matches your deployment requirement.
4. The **Provision Service** dialog opens.

The service supports:

- Single-console standalone deployments.
- Two-node HA deployments consisting of a primary and secondary VM.

For HA deployments, the primary and secondary VMs use a fixed `10.0.0.x` private network for synchronization.

### Step 3: Enter Provisioning Parameters

In the **Provision Service** dialog, provide the following:

#### Instance ID

Enter a unique name for the service instance.

Examples:

```text
secops-qradar-prod
qateam-standalone-test4
```

Use lowercase alphanumeric characters and hyphens (`-`).

#### Target Cluster

Select the target OpenShift cluster from the **Target Cluster** dropdown.

Example:

```text
in-cluster (Hub)
```

#### Parameters (JSON)

Click **Fill Example** and replace the example values with values for your environment.

```json
{
  "qradar": {
    "admin_password": "<YOUR_STRONG_ADMIN_PASSWORD>",
    "dns_primary": "<PRIMARY_DNS_IP>",
    "dns_secondary": "<SECONDARY_DNS_IP>",
    "root_password": "<YOUR_STRONG_ROOT_PASSWORD>",
    "security_template": "Enterprise",
    "timezone": "UTC"
  }
}
```

### Parameter reference

| Parameter | Type | Required | Description | Example |
|---|---|---|---|---|
| `qradar.admin_password` | String | Yes | Password for the QRadar Web Console `admin` user. Use a strong password containing uppercase/lowercase letters, numbers, and symbols. | `"SecureAdm1nP@ssw0rd"` |
| `qradar.root_password` | String | Yes | Password for the operating system `root` user on the underlying VM. | `"VerySecureR00tP@ssw0rd!"` |
| `qradar.dns_primary` | String | Yes | IP address of the primary DNS resolver reachable by the VM. | `"8.8.8.8"` or `"10.x.x.x"` |
| `qradar.dns_secondary` | String | Optional | IP address of the secondary DNS resolver. | `"8.8.4.4"` or `"10.x.x.y"` |
| `qradar.security_template` | String | Yes | QRadar security template profile. The documented default is `Enterprise`. | `"Enterprise"` |
| `qradar.timezone` | String | Yes | Standard timezone identifier for QRadar log event timestamps. | `"UTC"`, `"EST"`, `"America/New_York"` |

### Step 4: Provision the Service

1. Review the instance ID, target cluster, JSON parameters, and credentials.
2. Confirm that the DNS information is correct.
3. Click **Provision**.

The catalog broker starts the GitOps workflow to deploy the QRadar VM or VM pair on OpenShift Virtualization.

---

## 4. Monitor the Deployment

After provisioning starts:

1. Return to the main Service Catalog dashboard.
2. Scroll to **Provisioned Instances**.
3. Locate the instance by its **Instance ID**.

A provisioned instance displays information such as:

```text
Instance: secops-qradar-prod
Service:  qradar
Plan:     small-ha
Status:   SUCCEEDED
```

### Status indicators

| Status | Meaning |
|---|---|
| `IN_PROGRESS` / `PROVISIONING` | VM disks are being imported or cloned and boot-stage scripts are running. |
| `SUCCEEDED` | The QRadar deployment is fully configured and online. |

### Instance actions

**Check Status**

Use **Check Status** to inspect:

- Current runtime status.
- Assigned IP address.
- Connection logs.
- OpenShift Route or Service endpoint, where available.

**Delete**

Use **Delete** to deprovision the VM or VMs and clean up the associated storage when the service instance is no longer required.

---

## 5. Access the QRadar Web Console

Access QRadar after the instance reaches **`SUCCEEDED`**.

1. Open the instance under **Provisioned Instances**.
2. Click **Check Status**.
3. Obtain the assigned IP address or the OpenShift Route/Service endpoint.
4. Open the QRadar URL:

```text
https://<QRADAR_IP_OR_HOSTNAME>/
```

5. If the environment uses a self-signed or internal CA certificate, accept the SSL certificate prompt when required.
6. Sign in with:

```text
Username: admin
Password: <the admin_password configured during provisioning>
```

---

## 6. Deployment Guidelines and Scope

The supplied deployment documentation identifies the following guidelines and limitations.

### Deployment validation

- The deployment is validated on the **Tiny** plan with **5000 EPS**.
- The deployment model is **All-in-One (AIO)**.

### Unsupported capabilities

- **Managed Hosts are not supported.**
- **QRadar App installation is not supported.**

### Upgrades

Customers cannot upgrade an existing deployment when a new QRadar version becomes available in the Service Catalog.

Instead:

1. IBM updates the catalog with the latest QRadar version.
2. Customers can install the latest version that is available in the catalog.

---

## 7. Troubleshooting

The following diagnostic procedures are intended primarily for administrators who have access to the OpenShift cluster and QRadar VM.

### Layer 0: Sync blocked — secret-copy Job fails with ImagePullBackOff

Before any DataVolume import begins, the `quay-secret-copy` ArgoCD sync hook Job must complete successfully. If it stays in `ImagePullBackOff`, the entire sync is blocked and no secrets are copied into the instance namespace.

**Diagnose:**

```bash
# Check the Job and pod status
oc get job quay-secret-copy -n <instance-namespace>
oc get pods -n <instance-namespace> -l job-name=quay-secret-copy

# See the exact pull error
oc describe pod -n <instance-namespace> -l job-name=quay-secret-copy | grep -A5 'Events:'
```

**Common causes and fixes:**

| Symptom | Cause | Fix |
|---|---|---|
| `unauthorized: Please login to the Red Hat Registry` | Cluster has no Red Hat pull secret | Switch to Option C (`quay.io/openshift/origin-cli`) per [Section 2b](#2b-platform-administrator--configure-the-tool-image-for-the-secret-copy-job) |
| `no such host: image-registry.openshift-image-registry.svc` | Internal image registry is not deployed (`ManagementState: Removed`) | Switch to Option C (`quay.io/openshift/origin-cli`) per [Section 2b](#2b-platform-administrator--configure-the-tool-image-for-the-secret-copy-job) |
| `ImagePullBackOff` on a private mirror | `toolImage.pullSecret` is missing or wrong | Create the pull secret in the instance namespace and set `toolImage.pullSecret` to its name |

**Fix — update the instance `values.yaml` and force a re-sync:**

```bash
# 1. Edit instances/qradar/<instance-name>/values.yaml in the GitOps repo
#    and set toolImage.repository to the correct image for your cluster.
#    Example for Option C (recommended):
#
#    toolImage:
#      repository: quay.io/openshift/origin-cli
#      tag: latest
#      pullPolicy: IfNotPresent
#      pullSecret: ""

# 2. Commit and push the change
git add instances/qradar/<instance-name>/values.yaml
git commit -m "fix: set toolImage for <instance-name>"
git push

# 3. Delete the stuck Job so ArgoCD re-runs the hook with the new image
oc delete job quay-secret-copy -n <instance-namespace>
```

ArgoCD detects the push and automatically re-syncs. The Job is recreated with the new image.

---

### Layer 0: DataVolume stuck in Pending — StorageClass not found

If the DataVolume remains in `Pending` with no importer pod starting, check whether the configured StorageClass exists on the cluster:

```bash
# Check DataVolume phase and events
oc get datavolume -n <instance-namespace>
oc get events -n <instance-namespace> --sort-by='.lastTimestamp' | grep -i 'storageclass\|pending\|pvc'

# List available StorageClasses on the cluster
oc get sc
```

**Common error and fix:**

| Error message | Cause | Fix |
|---|---|---|
| `storageclass.storage.k8s.io "<name>" not found` | The `storageClassName` in the instance `values.yaml` does not exist on this cluster | Set `storage.storageClassName` to a valid class per [Section 2c](#2c-platform-administrator--configure-the-storageclass) |

**Fix — update the instance `values.yaml` and delete the stuck resources:**

```bash
# 1. Edit instances/qradar/<instance-name>/values.yaml
#    and set the correct storageClassName, for example:
#
#    storage:
#      storageClassName: ceph-rbd-platform

# 2. Commit and push
git add instances/qradar/<instance-name>/values.yaml
git commit -m "fix: set storageClassName for <instance-name>"
git push

# 3. Delete the stuck DataVolume(s) and PVC(s) so CDI re-provisions with the new class
# Standalone
oc delete datavolume qradar-primary-rootdisk -n <instance-namespace>
oc delete pvc qradar-primary-rootdisk -n <instance-namespace>

# HA — delete both
oc delete datavolume qradar-primary-rootdisk qradar-secondary-rootdisk -n <instance-namespace>
oc delete pvc qradar-primary-rootdisk qradar-secondary-rootdisk -n <instance-namespace>
```

ArgoCD re-creates the VM and DataVolume on the next sync using the correct StorageClass.

---

### Layer 0: HA VM stuck in `ErrorUnschedulable` — single-node cluster

For HA deployments, the Helm chart enforces a `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity rule so that the primary and secondary VMs always land on **separate worker nodes**. On a single-node cluster (or a cluster where all nodes are already occupied), the second VM cannot be scheduled and stays in `ErrorUnschedulable`.

**Diagnose:**

```bash
oc get vm,vmi -n <instance-namespace>
# Look for: STATUS=ErrorUnschedulable on one VM

oc describe vmi qradar-primary -n <instance-namespace> | grep -A3 'Unschedulable'
# Expected message:
# 0/1 nodes are available: 1 node(s) didn't match pod anti-affinity rules.
```

**Resolution options:**

| Option | When to use |
|--------|-------------|
| **Add a worker node** ✅ Recommended for production | The cluster genuinely needs a second node for HA |
| **Accept co-location** — force-delete the stuck VMI | Lab/demo only — both VMs run on the same node, anti-affinity is `IgnoredDuringExecution` so running VMs are not evicted |

**Lab/demo workaround — force the VMI to reschedule:**

```bash
# Force-delete the stuck VMI pod so KubeVirt recreates it fresh
# (the running secondary VMI must also be bounced so its old required-affinity
#  pod is replaced before the primary attempts scheduling again)
oc delete vmi qradar-secondary -n <instance-namespace>
# Wait for secondary to come back Running, then:
oc delete pod -n <instance-namespace> -l kubevirt.io/domain=qradar-primary --force --grace-period=0
```

> ⚠️ **Production note:** The anti-affinity rule is intentional. Both VMs on the same node defeats the purpose of HA — a node failure would take down both primary and secondary simultaneously. Always provision HA plans on clusters with at least two worker nodes.

---

### Layer 0: VM stuck in Provisioning — registry pull secrets

If a VM remains in `Provisioning` state and never starts, check for missing or incorrectly formatted pull secrets first:

```bash
# Check DataVolume phase and events
oc get datavolume -n <namespace>
oc get events -n <namespace> --sort-by='.lastTimestamp' | grep -i "secret\|accessKey\|pull\|failed"
```

**Common errors and fixes:**

| Error message | Cause | Fix |
|---|---|---|
| `couldn't find key accessKeyId in Secret …/quay-pull-secret` | `quay-pull-secret` is a `dockerconfigjson` secret — CDI expects `quay-cdi-secret` (Opaque) | Create `quay-cdi-secret` in `qradar-media` per [Section 2a](#2a-platform-administrator--one-time-cluster-setup) |
| `secret "quay-cdi-secret" not found` | The `quay-cdi-secret` was not created in `qradar-media` before provisioning | Create both secrets in `qradar-media` per [Section 2a](#2a-platform-administrator--one-time-cluster-setup) |
| `manifest unknown` | Image tag does not exist in the registry | Verify the golden disk and ISO images are pushed and tagged correctly in Quay |

After creating missing secrets, delete stuck importer pods to trigger an immediate retry:

```bash
oc delete pod -n <namespace> --all
```

---

### Layer 1: OpenShift and VM-level checks

Check the VM, VMI, and DataVolume status:

```bash
oc get vm,vmi,datavolume -n <namespace>
```

Check Route, Service, and Pod readiness:

```bash
oc get route,svc,pods -n <namespace>
```

Open the VM serial console when the VM is unreachable:

```bash
virtctl console <vm-name> -n <namespace>
```

### Layer 2: VM boot and installation checks

Check whether cloud-init completed:

```bash
ls /var/lib/cloud/instance/boot-finished
```

Monitor the QRadar OpenShift installation log:

```bash
tail -f /var/log/qradar-ocp-install.log
```

Check for the QRadar installation completion marker:

```bash
ls /var/log/qradar-ocp-install-complete
```

### Layer 3: QRadar services and application health

Check the core QRadar application daemons:

```bash
systemctl status --no-pager hostcontext tomcat
```

Check web interface availability from the VM:

```bash
curl -k -I https://localhost/console/
```

An **HTTP 302** response is expected.

### Layer 4: HA pairing and DRBD synchronization

For HA deployments, verify DRBD replication state:

```bash
drbdadm dstate store
```

The expected state is:

```text
UpToDate/UpToDate
```

Check the HA node role and cluster state:

```bash
/opt/qradar/ha/bin/ha stateshow
```

Expected output includes an active or standby state, such as `active 1.0` or `standby`.

Check the remote HA node:

```bash
/opt/qradar/ha/bin/ha remote_state
```

---

## 8. Diagnostics and Logs

### Built-in diagnostic script

The QRadar deployment includes the following diagnostic utility:

```bash
/usr/local/bin/qradar-ocp-status.sh
```

Available modes include:

```bash
# Standard health report
/usr/local/bin/qradar-ocp-status.sh

# Machine-readable output
/usr/local/bin/qradar-ocp-status.sh --json

# HA-focused diagnosis
/usr/local/bin/qradar-ocp-status.sh --failover

# Standalone-focused checks
/usr/local/bin/qradar-ocp-status.sh --standalone
```

Use `--json` when a machine-readable snapshot is needed for automation or when attaching diagnostic information to a ticket.

### Key log files

| Purpose | Location |
|---|---|
| OpenShift provisioning and unattended installer | `/var/log/qradar-ocp-install.log` |
| QRadar installer stage logs | `/var/log/setup-*/` |
| HA wizard and pairing | `/var/log/setup-*/qradar_hasetup.log` |
| Core platform and daemon logs | `/var/log/qradar.log` |
| Hostcontext and Tomcat service logs | `journalctl -u hostcontext -u tomcat --no-pager` |
| Cloud-init logs | `/var/log/cloud-init.log` |
| System messages | `/var/log/messages` |

### OpenShift and GitOps diagnostics

Check ArgoCD application synchronization and resource health:

```bash
oc get application qradar-<instance> -n argocd
```

Inspect KubeVirt VM status and events:

```bash
oc describe vm <vm-name> -n <namespace>
```

Inspect the ingress route and endpoints:

```bash
oc get route,endpoints -n <namespace>
```

---

## 9. Quick Deployment Checklist

Use this checklist before and after provisioning.

### Before provisioning

**Platform administrator (once per cluster):**
- [ ] `qradar-media` namespace exists on the target cluster.
- [ ] `quay-pull-secret` (`kubernetes.io/dockerconfigjson`) created in `qradar-media`.
- [ ] `quay-cdi-secret` (`Opaque`, keys: `accessKeyId` + `secretKey`) created in `qradar-media`.
- [ ] `toolImage.repository` in instance `values.yaml` set to an image reachable from this cluster (see [Section 2b](#2b-platform-administrator--configure-the-tool-image-for-the-secret-copy-job)).
- [ ] `storage.storageClassName` in instance `values.yaml` set to a valid RWO block StorageClass on this cluster (see [Section 2c](#2c-platform-administrator--configure-the-storageclass)).

**End user:**
- [ ] Service Catalog URL and credentials available.
- [ ] Target OpenShift cluster identified.
- [ ] Primary DNS IP available.
- [ ] Secondary DNS IP available, if applicable.
- [ ] Timezone selected.
- [ ] QRadar `admin` password prepared.
- [ ] QRadar OS `root` password prepared.
- [ ] Standalone or HA plan selected.

### During provisioning

- [ ] Unique Instance ID entered.
- [ ] Correct target cluster selected.
- [ ] JSON parameters validated.
- [ ] **Provision** selected.

### After provisioning

- [ ] Instance reaches `SUCCEEDED`.
- [ ] **Check Status** returns the endpoint/IP information.
- [ ] QRadar Web Console is reachable over HTTPS.
- [ ] Login succeeds with the configured `admin` credentials.
- [ ] Credentials are stored securely for future administrative access.

---

## 10. Summary

The IBM Sovereign Core Service Catalog provides self-service deployment of **IBM QRadar SIEM 7.6.0** on OpenShift Virtualization through Helm and GitOps.

The deployment workflow is:

```text
Available Services
       |
       v
QRadar SIEM (Helm)
       |
       v
Select Plan
       |
       v
Enter Instance ID + Cluster + JSON Parameters
       |
       v
Provision
       |
       v
GitOps / OpenShift Virtualization Deployment
       |
       v
Provisioned Instances
       |
       v
SUCCEEDED
       |
       v
Check Status
       |
       v
Access QRadar Web Console
```

For deployment failures, use the Service Catalog **Check Status** action first. Platform administrators can then use the OpenShift, VM, QRadar service, HA/DRBD, diagnostic-script, and log checks described in this guide.
