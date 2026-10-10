#!/usr/bin/env bash
# deprovision-portforward.sh
# Port-forwards the broker service from the cluster, then runs deprovision.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_PORT=7329
REMOTE_PORT=7332
NAMESPACE=byop-service-broker
SERVICE=byop-service-broker-svc

echo "==> Port-forwarding ${NAMESPACE}/${SERVICE} :${REMOTE_PORT} -> localhost:${LOCAL_PORT}"
oc port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" -n "${NAMESPACE}" &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null; wait "${PF_PID}" 2>/dev/null' EXIT

# Wait for the port to be ready
for i in {1..10}; do
  nc -z localhost "${LOCAL_PORT}" 2>/dev/null && break
  sleep 0.5
done
nc -z localhost "${LOCAL_PORT}" 2>/dev/null || { echo "ERROR: port-forward did not become ready"; exit 1; }

echo "    Ready — broker reachable at https://localhost:${LOCAL_PORT}"
echo ""

BROKER_URL="https://localhost:${LOCAL_PORT}" "${SCRIPT_DIR}/deprovision.sh" "${1:-nginx}"
