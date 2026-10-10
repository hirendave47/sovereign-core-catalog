#!/usr/bin/env bash
# deprovision.sh <product_name>
#
# Calls the BYOP service broker to deprovision an instance of the given product.
#
# Usage:
#   ./deprovision.sh nginx
#   INSTANCE_ID=my-nginx BROKER_URL=http://localhost:7329 ./deprovision.sh nginx
set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && { echo "Usage: $0 <product_name>"; exit 1; }
PRODUCT_NAME="$1"

# ---------------------------------------------------------------------------
# Configuration — override any of these via environment variables
# ---------------------------------------------------------------------------
BROKER_URL="${BROKER_URL:-http://localhost:7329}"
INSTANCE_ID="${INSTANCE_ID:-${PRODUCT_NAME}-test-instance}"
SERVICE_ID="${SERVICE_ID:-${PRODUCT_NAME}}"
PLAN_ID="${PLAN_ID:-standard}"
TENANT_ID="${TENANT_ID:-test-tenant}"

# The broker URL path parameter must be a CRN; the instance ID is extracted from segment 7.
# Format: crn:v1:<cname>:<ctype>:<service-name>:<location>:<scope>:<instance-id>::
# Override CRN_INSTANCE_ID to use a different instance ID inside the CRN than INSTANCE_ID.
CRN_INSTANCE_ID="${CRN_INSTANCE_ID:-${INSTANCE_ID}}"
INSTANCE_CRN="crn:v1:bluemix:public:${SERVICE_ID}:us-south:a/${TENANT_ID}:${CRN_INSTANCE_ID}::"

# ---------------------------------------------------------------------------
# Call broker
# ---------------------------------------------------------------------------
echo "Deprovisioning '${PRODUCT_NAME}' instance '${INSTANCE_ID}' via broker at ${BROKER_URL}..."
echo "CRN: ${INSTANCE_CRN}"
echo ""

ENCODED_CRN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${INSTANCE_CRN}', safe=''))")

HTTP_CODE=$(curl -sk -o /tmp/byop-deprovision-response.json -w "%{http_code}" \
  -X DELETE \
  -H "Content-Type: application/json" \
  -H "X-Broker-API-Version: 2.16" \
  "${BROKER_URL}/v2/service_instances/${ENCODED_CRN}?accepts_incomplete=true&service_id=${SERVICE_ID}&plan_id=${PLAN_ID}")

echo "HTTP ${HTTP_CODE}"
cat /tmp/byop-deprovision-response.json
echo ""

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "202" && "${HTTP_CODE}" != "410" ]]; then
  echo "ERROR: broker returned HTTP ${HTTP_CODE}" >&2
  exit 1
fi

echo "Instance '${INSTANCE_ID}' deprovisioned successfully."
