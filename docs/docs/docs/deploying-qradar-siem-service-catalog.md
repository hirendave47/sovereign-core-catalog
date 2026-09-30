# Deploying IBM QRadar SIEM using the IBM Sovereign Core Service Catalog

## End User Guide

This guide explains how to provision and access an **IBM QRadar SIEM** instance through the **IBM Sovereign Core Service Catalog** (GitOps CSB Broker Web Interface).

The Service Catalog provides self-service deployment of enterprise services onto OpenShift clusters using GitOps. QRadar SIEM is deployed on **OpenShift Virtualization using Helm charts**. The catalog provides both standalone and high-availability deployment plans.

> **Service model:** The provided documentation describes the Sovereign Core Service Catalog as a **Tech Preview under a try-and-buy model**. Deployment is self-service and IBM Support is not included.

---

## 1. Before You Begin

Make sure you have the following information available:

| Requirement | Details |
|---|---|
| Service Catalog access | Catalog URL and valid credentials |
| Target cluster | Cluster name or identifier where QRadar will be deployed |
| Primary DNS | IP address of a DNS resolver reachable by the QRadar VM(s) |
| Secondary DNS | Optional secondary DNS resolver IP address |
| Time zone | Standard timezone identifier, such as `UTC`, `America/New_York`, or `Europe/London` |
| QRadar admin password | Password for the QRadar Web Console `admin` user |
| QRadar root password | Password for the underlying VM operating system `root` user |

### Important

Keep the `admin_password` and `root_password` in a secure location. The provisioning documentation states that these passwords cannot later be retrieved from the UI in plain text.

---

## 2. Choose a Deployment Plan

Open the Service Catalog and locate the **QRadar SIEM (Helm)** service.

The service provides two deployment topologies:

- **Standalone:** One QRadar Console VM using DHCP networking. Available plans are `Tiny`, `Small`, `Medium`, and `Large`.
- **High Availability (HA):** A primary and secondary VM pair using a fixed `10.0.0.x` private synchronization network. Available plans are `Small HA`, `Medium HA`, and `Large HA`.

### Plan and Resource Reference

| Category | Plan ID | Display Name | VM Count | vCPU / VM | Memory / VM | Root Disk / VM | Total Resources | Intended Use |
|---|---|---|---:|---:|---:|---:|---|---|
| Standalone | `tiny` | **Tiny** | 1 | 8 | 32 GB | 250 GB | 8 vCPU / 32 GB / 250 GB | Development, test, evaluation |
| Standalone | `small` | **Small** | 1 | 16 | 64 GB | 250 GB | 16 vCPU / 64 GB / 250 GB | Functional testing / QA |
| Standalone | `medium` | **Medium** | 1 | 24 | 96 GB | 250 GB | 24 vCPU / 96 GB / 250 GB | Staging / mid-tier ingestion |
| Standalone | `large` | **Large** | 1 | 48 | 192 GB | 500 GB | 48 vCPU / 192 GB / 500 GB | High-throughput standalone |
| High Availability | `small-ha` | **Small HA** | 2 | 16 | 64 GB | 250 GB | 32 vCPU / 128 GB / 500 GB | Small production HA |
| High Availability | `medium-ha` | **Medium HA** | 2 | 24 | 96 GB | 250 GB | 48 vCPU / 192 GB / 500 GB | Enterprise production |
| High Availability | `large-ha` | **Large HA** | 2 | 48 | 192 GB | 500 GB | 96 vCPU / 384 GB / 1000 GB | High-capacity enterprise HA |

> **HA sizing baseline:** `Small HA` is the minimum validated HA plan. The supplied documentation states that smaller footprints do not provide sufficient memory headroom for DRBD replication and data synchronization under load.

> **Additional storage:** Each VM automatically mounts a **30 GB installation-media DataVolume** backed by the cluster storage class `ocs-storagecluster-ceph-rbd`.

### Deployment Guidelines

The supplied documentation also notes:

- The **Tiny** deployment has been validated with **5000 EPS**.
- The deployment is **All-in-One (AIO) only**; **Managed Hosts are not supported**.
- **App installation is not supported**.

---

## 3. Provision QRadar SIEM

### Step 1: Open the Service Catalog

1. Open a supported web browser.
2. Navigate to the **IBM Sovereign Core Service Catalog** web portal.
3. In the top navigation, open **Available Services**.

### Step 2: Open QRadar SIEM

1. Locate **QRadar SIEM (Helm)**.
2. Review the available plans.
3. Select the required plan, such as **Tiny** for a standalone deployment or **Small HA** for an HA deployment.
4. The **Provision Service** dialog opens.

### Step 3: Enter Provisioning Details

Complete the following fields.

#### Instance ID

Enter a unique name for the QRadar deployment.

Examples:

```text
secops-qradar-prod
qateam-standalone-test4
```

Use lowercase alphanumeric characters and hyphens (`-`).

#### Target Cluster

Select the OpenShift cluster from the **Target Cluster** dropdown.

Example:

```text
in-cluster (Hub)
```

#### Parameters (JSON)

Select **Fill Example** and replace the example values with your environment-specific settings.

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

### Parameter Reference

| Parameter | Type | Required | Description | Example |
|---|---|---|---|---|
| `qradar.admin_password` | String | Yes | QRadar Web Console password for the `admin` user. Use upper/lowercase letters, numbers, and symbols. | `"SecureAdm1nP@ssw0rd!"` |
| `qradar.root_password` | String | Yes | Operating system `root` password for the underlying QRadar VM. | `"VerySecureR00tP@ssw0rd!"` |
| `qradar.dns_primary` | String | Yes | Primary DNS resolver IP address reachable by the VM. | `"8.8.8.8"` or `"10.x.x.x"` |
| `qradar.dns_secondary` | String | Optional | Secondary DNS resolver IP address. | `"8.8.4.4"` or `"10.x.x.y"` |
| `qradar.security_template` | String | Yes | QRadar security template profile. The documented default is `Enterprise`. | `"Enterprise"` |
| `qradar.timezone` | String | Yes | Timezone identifier used for log event timestamps. | `"UTC"`, `"EST"`, `"America/New_York"` |

### Step 4: Start Provisioning

1. Review the instance ID, cluster, JSON parameters, and passwords.
2. Verify that the DNS addresses are correct and reachable from the deployment environment.
3. Click **Provision**.

The Service Catalog broker triggers the GitOps workflow that creates the QRadar VM or VM pair on OpenShift Virtualization.

---

## 4. Monitor the Deployment

After provisioning starts, go to **Provisioned Instances** on the catalog dashboard.

Locate the instance using the **Instance ID** you entered.

Typical instance information includes:

```text
Instance: secops-qradar-prod
Service:  qradar
Plan:     small-ha
Status:   SUCCEEDED
```

### Status Indicators

| Status | Meaning |
|---|---|
| `IN_PROGRESS` / `PROVISIONING` | VM disks are being imported or cloned and boot-stage scripts are running. |
| `SUCCEEDED` | The QRadar deployment is fully configured and online. |

### Available Actions

**Check Status**  
Use this action to inspect runtime status, the allocated IP address, and connection logs.

**Delete**  
Use this action to deprovision the VM or VM pair and clean up storage volumes when the instance is no longer required.

---

## 5. Access the QRadar Web Console

Access QRadar after the catalog reports **`SUCCEEDED`**.

1. Open the QRadar instance in **Provisioned Instances**.
2. Click **Check Status**.
3. Obtain the assigned IP address or OpenShift Route/Service endpoint.
4. Open the endpoint in a browser:

```text
https://<QRADAR_IP_OR_HOSTNAME>/
```

5. Accept the SSL certificate warning when the environment uses a self-signed or internal CA certificate.
6. Sign in with:

```text
Username: admin
Password: <the admin_password used during provisioning>
```

---

## 6. What Is and Is Not Supported

The supplied deployment documentation identifies the following scope:

### Supported deployment model

- QRadar SIEM deployed through the Service Catalog on OpenShift Virtualization.
- Standalone single-console VM deployments.
- HA primary/secondary VM deployments.
- All-in-One (AIO) QRadar deployment.

### Not supported / not available through this deployment model

- Managed Hosts.
- QRadar App installation.
- Customer-driven in-place upgrades from an older catalog version.

### Version updates

The supplied documentation states that customers cannot upgrade the deployed QRadar instance when a new version becomes available. IBM updates the Service Catalog with the latest QRadar version, and customers install the latest version available in the catalog.

---

## 7. Troubleshooting

Most end users should first use **Check Status** in the Service Catalog. The following checks are useful when OpenShift or VM-level access is available to the platform administrator.

### Layer 1 — OpenShift and VM Level

Check VM, VMI, and DataVolume status:

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

### Layer 2 — VM Boot and Installation

Check cloud-init completion:

```bash
ls /var/lib/cloud/instance/boot-finished
```

Monitor the unattended installation log:

```bash
tail -f /var/log/qradar-ocp-install.log
```

Check the QRadar installation completion marker:

```bash
ls /var/log/qradar-ocp-install-complete
```

### Layer 3 — QRadar Service Health

Check the core QRadar daemons:

```bash
systemctl status --no-pager hostcontext tomcat
```

Check local web-console availability:

```bash
curl -k -I https://localhost/console/
```

An HTTP `302` response is expected by the supplied troubleshooting procedure.

### Layer 4 — HA and DRBD

For HA deployments, check DRBD replication state:

```bash
drbdadm dstate store
```

The expected state is:

```text
UpToDate/UpToDate
```

Check HA node role and state:

```bash
/opt/qradar/ha/bin/ha stateshow
```

Check remote node health:

```bash
/opt/qradar/ha/bin/ha remote_state
```

---

## 8. Diagnostic Script and Important Logs

A built-in diagnostic script is available on the QRadar VM:

```bash
/usr/local/bin/qradar-ocp-status.sh
```

Supported modes include:

```bash
/usr/local/bin/qradar-ocp-status.sh --json
/usr/local/bin/qradar-ocp-status.sh --failover
/usr/local/bin/qradar-ocp-status.sh --standalone
```

The supplied documentation describes these modes as follows:

| Mode | Purpose |
|---|---|
| `--json` | Machine-readable health snapshot for automation or attaching to a support/ticket record. |
| `--failover` | Focused HA diagnosis, including HA state, daemon crash loops, and JMS ports. |
| `--standalone` | Checks tailored for a single-VM deployment and omits HA/DRBD checks. |

### Key Log Files

| Area | Location |
|---|---|
| OpenShift provisioning / unattended installer | `/var/log/qradar-ocp-install.log` |
| QRadar installer stages | `/var/log/setup-*` |
| HA pairing | `/var/log/setup-*/qradar_hasetup.log` |
| QRadar core platform | `/var/log/qradar.log` |
| Hostcontext / Tomcat services | `journalctl -u hostcontext -u tomcat --no-pager` |
| cloud-init / system logs | `/var/log/cloud-init.log`, `/var/log/messages` |

For OpenShift/GitOps diagnostics, the supplied documentation lists:

```bash
oc get application qradar-<instance> -n argocd
oc describe vm <vm-name> -n <namespace>
oc get route,endpoints -n <namespace>
```

---

## 9. Quick Deployment Checklist

Before clicking **Provision**:

- [ ] Correct QRadar plan selected.
- [ ] Unique lowercase instance ID entered.
- [ ] Correct target OpenShift cluster selected.
- [ ] Strong `admin_password` entered.
- [ ] Strong `root_password` entered.
- [ ] Primary DNS address entered.
- [ ] Secondary DNS address entered if required.
- [ ] Correct timezone selected.
- [ ] Configuration reviewed before submission.

After provisioning:

- [ ] Instance appears under **Provisioned Instances**.
- [ ] Status changes from `PROVISIONING` / `IN_PROGRESS` to `SUCCEEDED`.
- [ ] **Check Status** returns the QRadar endpoint or IP address.
- [ ] QRadar Web Console is reachable.
- [ ] Login succeeds with the configured `admin` credentials.
- [ ] Credentials are stored securely.

---

## 10. Reference

The content in this guide was consolidated from the supplied end-user markdown draft and the supplied **Deploying IBM QRadar SIEM by using the IBM Sovereign Core Service Catalog** document.

> **Version note for publication:** The two supplied source files contain a QRadar version discrepancy: the markdown draft refers to **QRadar SIEM 7.5.0**, while the supplied PDF documentation refers to **QRadar SIEM 7.6.0**. This consolidated guide follows the **7.6.0** version stated in the PDF. Verify the version displayed in the Service Catalog before publishing the guide for a specific environment.
