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

> **Credential handling:** Save the `admin_password` and `root_password` securely. The documentation states that these passwords cannot later be retrieved in plain text from the Service Catalog UI.

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
