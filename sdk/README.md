## Broker deployment

1. Copy operator and broker images to quay

2. Pull byop-service-broker chart

3. Update a values file

4. Run Helm install


## Importing a product

1. Manually package push chart to quay

2. Update git metadata for product

3. Copy import.env to this directory and populate with git and quay values

4. Copy import.sh script to this directory

5. Update `run-import.sh` as needed and execute it


## Installing a product instance

1. Create a file called `<product>.provision.json` and update with provision payload (see [Provision Payload & Helm Overrides Guide](#provision-payload--helm-overrides-guide) below)

2. Login to cluster

3. Run `provision-portforward.sh <product_name>` (defaults to `nginx` if omitted)


## Deprovisioning a product instance

1. Login to cluster

2. Run `deprovision-portforward.sh <product_name>` (defaults to `nginx` if omitted)


## Provision Payload & Helm Overrides Guide

The provision payload JSON file (`<product>.provision.json`) supplies both service routing metadata and chart configuration overrides to the BYOP service broker.

### Payload Structure

```json
{
  "service_id": "<product_name>",
  "plan_id": "standard",
  "context": {
    "platform": "kubernetes",
    "account_id": "<tenant_id>"
  },
  "parameters": {
    "spec": {
      "productId": "<product_name>",
      "tenantId": "<tenant_id>",
      "clusterTarget": "<argocd_cluster_name>",
      "namespace": "<target_namespace>",
      "instanceName": "<optional_instance_name>",

      "<helm_value_override_1>": "<value>",
      "<helm_value_override_2>": {
        "<nested_key>": "<nested_value>"
      }
    }
  }
}
```

### Field Breakdown

| Field | Location | Description |
|---|---|---|
| `service_id` | Root | Service identifier matching the registered catalog product |
| `plan_id` | Root | Pricing/service plan (typically `"standard"`) |
| `context.account_id` | `context` | Tenant / account identifier |
| `parameters.spec.productId` | `parameters.spec` | Product ID used by broker to locate the matching `BYOPTemplate` |
| `parameters.spec.clusterTarget` | `parameters.spec` | Target ArgoCD cluster destination name (e.g. `"in-cluster"`, `"gori-int-vm2"`) |
| `parameters.spec.tenantId` | `parameters.spec` | Deployment tenant identifier (defaults to `context.account_id` if omitted) |
| `parameters.spec.namespace` | `parameters.spec` | Target Kubernetes namespace on the destination cluster |
| `parameters.spec.instanceName` | `parameters.spec` | Optional custom name for the deployed instance |
| *`<any other field>`* | `parameters.spec` | **Helm chart value overrides** |

### How Helm Overrides Flow

1. **Broker Extraction**: When the broker receives the request, it extracts standard routing fields (`productId`, `clusterTarget`, `namespace`, etc.) and packages the entire `parameters.spec` dictionary into `BYOPRequest.spec.overrides`.
2. **Operator Application**:
   - **For `helm-registry` templates**: The operator extracts `overrides` and places them directly into the generated ArgoCD Application under `spec.source.helm.valuesObject`. Any keys defined under `parameters.spec` override the chart's default `values.yaml` at deploy time.
   - **For `helm-git` / GitOps templates**: The operator injects `overrides` into the template data map used to render `values.yaml` in the Git repository.

### Example: Nginx (`nginx.provision.json`)

```json
{
  "service_id": "nginx",
  "plan_id": "standard",
  "context": {
    "platform": "kubernetes",
    "account_id": "test-tenant"
  },
  "parameters": {
    "spec": {
      "productId": "nginx",
      "tenantId": "test-tenant",
      "clusterTarget": "gori-int-vm2",
      "replicaCount": 2,
      "service": {
        "type": "ClusterIP",
        "port": 80
      },
      "resources": {
        "limits": {
          "cpu": "500m",
          "memory": "512Mi"
        }
      }
    }
  }
}
```

### Example: MariaDB (`mariadb.provision.json`)

```json
{
  "service_id": "mariadb",
  "plan_id": "standard",
  "context": {
    "platform": "kubernetes",
    "account_id": "test-tenant"
  },
  "parameters": {
    "spec": {
      "productId": "mariadb",
      "tenantId": "test-tenant",
      "clusterTarget": "in-cluster",
      "replicaCount": 1,
      "databaseName": "appdb",
      "databaseUser": "appuser",
      "databasePassword": "change-me-password",
      "rootPassword": "change-me-root-password",
      "storageSize": "10Gi"
    }
  }
}
```