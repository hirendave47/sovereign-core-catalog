#!/usr/bin/env bash
# provision.sh <product_name> [payload_file]
#
# Calls the BYOP service broker to provision an instance of the given product.
# The request body is read from payload_file (default: <product_name>.provision.json
# in the same directory as this script).
#
# Usage:
#   ./provision.sh nginx
#   ./provision.sh nginx /path/to/custom-payload.json
#   INSTANCE_ID=my-nginx BROKER_URL=http://localhost:7329 ./provision.sh nginx
set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && { echo "Usage: $0 <product_name> [payload_file]"; exit 1; }
PRODUCT_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# Resolve payload file
# ---------------------------------------------------------------------------
if [[ $# -ge 2 ]]; then
  PAYLOAD_FILE="$2"
else
  PAYLOAD_FILE="${SCRIPT_DIR}/${PRODUCT_NAME}.provision.json"
fi

[[ -f "$PAYLOAD_FILE" ]] || {
  echo "ERROR: payload file not found: ${PAYLOAD_FILE}"
  echo "  Create ${PRODUCT_NAME}.provision.json in ${SCRIPT_DIR} or pass a path as the second argument."
  exit 1
}

# ---------------------------------------------------------------------------
# Call broker
# ---------------------------------------------------------------------------
echo "Provisioning '${PRODUCT_NAME}' instance '${INSTANCE_ID}' via broker at ${BROKER_URL}..."
echo "CRN:          ${INSTANCE_CRN}"
echo "Payload file: ${PAYLOAD_FILE}"
echo ""

ENCODED_CRN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${INSTANCE_CRN}', safe=''))")

HTTP_CODE=$(curl -sk -o /tmp/byop-provision-response.json -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -H "X-Broker-API-Version: 2.16" \
  "${BROKER_URL}/v2/service_instances/${ENCODED_CRN}?accepts_incomplete=true" \
  --data "@${PAYLOAD_FILE}")

echo "HTTP ${HTTP_CODE}"
cat /tmp/byop-provision-response.json
echo ""

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "201" && "${HTTP_CODE}" != "202" ]]; then
  echo "ERROR: broker returned HTTP ${HTTP_CODE}" >&2
  exit 1
fi

echo "Instance '${INSTANCE_ID}' provisioned successfully."
