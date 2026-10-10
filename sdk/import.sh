#!/usr/bin/env bash
# import.sh <product_name> [vX.X.X]
#
# Imports a BYOP product from the external catalog repo into the platform:
#   1. Sparse-clone the product directory from the external catalog repo
#   2. Copy the helm chart to Quay (helm-registry) or the GitOps repo (helm-git)
#   3. Mirror container images to Quay
#   4. Create the BYOPTemplate CR
#
# Product directory layout expected in the catalog repo:
#   <product>/
#     catalog/
#       catalog.yaml, schema.json, metrics.json
#     template/
#       values.yaml.tmpl
#     vX.X.X/
#       metadata.yaml
#
# If [vX.X.X] is omitted the latest version folder is selected automatically.
#
# Requires: git, helm, skopeo, oc, yq (mikefarah/yq), base64

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && { echo "Usage: $0 <product_name> [vX.X.X]  (e.g. $0 kafka v1.2.3)"; exit 1; }
PRODUCT_NAME="$1"
PRODUCT_VERSION="${2:-}"   # optional — resolved after clone if empty

# ---------------------------------------------------------------------------
# Load env
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/import.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found"; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

# Defaults
EXT_CATALOG_REPO="${EXT_CATALOG_REPO:-}"
EXT_CATALOG_BRANCH="${EXT_CATALOG_BRANCH:-main}"
EXT_CATALOG_PREFIX="${EXT_CATALOG_PREFIX:-}"

# Step enable flags — set any to 'false' in import.env or on the command line to skip that step
# e.g. STEP3_PUSH_CHART=false ./import.sh mariadb
STEP1_CLONE_CATALOG_ARTIFACTS="${STEP1_CLONE_CATALOG_ARTIFACTS:-true}"
STEP2_PULL_CHART="${STEP2_PULL_CHART:-true}"
STEP3_PUSH_CHART="${STEP3_PUSH_CHART:-true}"
STEP4_MIRROR_IMAGES="${STEP4_MIRROR_IMAGES:-true}"
STEP5_CREATE_BYOP_TEMPLATE="${STEP5_CREATE_BYOP_TEMPLATE:-true}"
STEP6_CREATE_PLATFORM_OWNER_SECRET="${STEP6_CREATE_PLATFORM_OWNER_SECRET:-true}"
STEP7_REGISTER_TARGET_REPO="${STEP7_REGISTER_TARGET_REPO:-true}"
STEP8_CREATE_ACM_PLACEMENT_RESOURCES="${STEP8_CREATE_ACM_PLACEMENT_RESOURCES:-true}"

# Required keys
for var in QUAY_USERNAME QUAY_PASSWORD; do
  [[ -z "${!var:-}" ]] && { echo "ERROR: $var must be set in import.env"; exit 1; }
done
[[ -z "$EXT_CATALOG_REPO" ]] && { echo "ERROR: EXT_CATALOG_REPO must be set in import.env"; exit 1; }

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
for tool in git helm skopeo oc yq base64; do
  command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found in PATH"; exit 1; }
done

# ---------------------------------------------------------------------------
# Resolve Quay hostname — use QUAY_REGISTRY override if set, otherwise look up from cluster
# ---------------------------------------------------------------------------
if [[ -n "${QUAY_REGISTRY:-}" ]]; then
  # Strip scheme if the override includes one
  QUAY_REGISTRY="${QUAY_REGISTRY#https://}"
  QUAY_REGISTRY="${QUAY_REGISTRY#http://}"
  echo "==> Using QUAY_REGISTRY override: ${QUAY_REGISTRY}"
else
  echo "==> Looking up Quay registry from cluster"
  QUAY_REGISTRY=$(oc get quayregistry registry -n quay-enterprise \
    -o jsonpath='{.status.registryEndpoint}' 2>/dev/null || true)
  [[ -z "$QUAY_REGISTRY" ]] && { echo "ERROR: could not retrieve Quay registryEndpoint from quay-enterprise namespace; set QUAY_REGISTRY in import.env to override"; exit 1; }
  # Strip scheme — helm and skopeo expect a bare hostname
  QUAY_REGISTRY="${QUAY_REGISTRY#https://}"
  QUAY_REGISTRY="${QUAY_REGISTRY#http://}"
  echo "    QUAY_REGISTRY=${QUAY_REGISTRY}"
fi

# ---------------------------------------------------------------------------
# Working directory — always created so later steps can write temp files
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — Sparse-clone product directory from external catalog repo
# ---------------------------------------------------------------------------
if [[ "$STEP1_CLONE_CATALOG_ARTIFACTS" == "false" ]]; then
  echo "--- Step 1: SKIPPED (STEP1_CLONE_CATALOG_ARTIFACTS=false)"
  # When skipping, PRODUCT_DIR must point to a local product checkout.
  # Set PRODUCT_DIR in import.env or on the command line.
  [[ -z "${PRODUCT_DIR:-}" ]] && { echo "ERROR: STEP1_CLONE_CATALOG_ARTIFACTS=false requires PRODUCT_DIR to be set"; exit 1; }
  METADATA_FILE="${PRODUCT_DIR}/catalog/metadata.yaml"
  [[ -f "$METADATA_FILE" ]] || { echo "ERROR: catalog/metadata.yaml not found in ${PRODUCT_DIR}"; exit 1; }
  SOURCE_TYPE=$(yq '.sourceType' "$METADATA_FILE")
  SOURCE_REPO=$(yq '.sourceRepo // ""' "$METADATA_FILE")
  PRODUCT_ID=$(yq '.name' "$METADATA_FILE")
  TARGET_TYPE=$(yq '.targetType // ""' "$METADATA_FILE")
  [[ -z "$TARGET_TYPE" ]] && TARGET_TYPE="$SOURCE_TYPE"
  echo "    sourceType=${SOURCE_TYPE}  targetType=${TARGET_TYPE}  productId=${PRODUCT_ID}"
else
echo "==> Step 1: Cloning product directory '${PRODUCT_NAME}' from external catalog"

CLONE_DIR="${WORK_DIR}/storefront"

# Inject token into catalog repo URL if PRODUCT_SOURCE_TOKEN is set
EXT_CATALOG_CLONE_URL="$EXT_CATALOG_REPO"
if [[ -n "${PRODUCT_SOURCE_TOKEN:-}" ]]; then
  EXT_CATALOG_CLONE_URL=$(echo "$EXT_CATALOG_REPO" | sed "s|https://|https://${PRODUCT_SOURCE_TOKEN}@|")
fi

git clone --no-checkout --depth=1 --branch "$EXT_CATALOG_BRANCH" "$EXT_CATALOG_CLONE_URL" "$CLONE_DIR"
git -C "$CLONE_DIR" sparse-checkout init --cone

# If a prefix is set, sparse-checkout the prefixed path (e.g. demo/kafka)
PRODUCT_PATH="${PRODUCT_NAME}"
[[ -n "$EXT_CATALOG_PREFIX" ]] && PRODUCT_PATH="${EXT_CATALOG_PREFIX}/${PRODUCT_NAME}"

# Sparse-checkout: always fetch the full product tree so cone mode includes
# catalog/, template/, and all vX.X.X/ subdirectories in one pass.
git -C "$CLONE_DIR" sparse-checkout set "$PRODUCT_PATH"
git -C "$CLONE_DIR" checkout

PRODUCT_DIR="${CLONE_DIR}/${PRODUCT_PATH}"
[[ -d "$PRODUCT_DIR" ]] || { echo "ERROR: product directory '${PRODUCT_PATH}' not found in external catalog repo"; exit 1; }

# Resolve version — use the supplied argument or pick the highest vX.X.X folder
if [[ -z "$PRODUCT_VERSION" ]]; then
  # Sort version folders (vMAJOR.MINOR.PATCH) and take the last (highest)
  PRODUCT_VERSION=$(find "$PRODUCT_DIR" -maxdepth 1 -type d -name 'v*.*.*' \
    | xargs -I{} basename {} \
    | sort -t. -k1,1V -k2,2n -k3,3n \
    | tail -1)
  [[ -z "$PRODUCT_VERSION" ]] && { echo "ERROR: no vX.X.X directory found in ${PRODUCT_DIR}"; exit 1; }
  echo "    Auto-selected version: ${PRODUCT_VERSION}"
else
  echo "    Using requested version: ${PRODUCT_VERSION}"
fi

# Read metadata — lives in <vX.X.X>/metadata.yaml
METADATA_FILE="${PRODUCT_DIR}/${PRODUCT_VERSION}/metadata.yaml"
[[ -f "$METADATA_FILE" ]] || { echo "ERROR: ${PRODUCT_VERSION}/metadata.yaml not found in ${PRODUCT_DIR}"; exit 1; }

# Read metadata — lives in catalog/metadata.yaml
SOURCE_TYPE=$(yq '.spec.catalog.sourceType' "$METADATA_FILE")
SOURCE_REPO=$(yq '.spec.catalog.sourceRepo // ""' "$METADATA_FILE")
PRODUCT_ID=$(yq '.spec.catalog.name' "$METADATA_FILE")
# targetType controls where the chart is delivered; defaults to matching sourceType
TARGET_TYPE=$(yq '.spec.catalog.targetType // ""' "$METADATA_FILE")
[[ -z "$TARGET_TYPE" ]] && TARGET_TYPE="$SOURCE_TYPE"

echo "    version=${PRODUCT_VERSION}  sourceType=${SOURCE_TYPE}  targetType=${TARGET_TYPE}  productId=${PRODUCT_ID}"
fi

# ---------------------------------------------------------------------------
# Step 2 — Acquire chart source into CHART_SRC (local directory)
# ---------------------------------------------------------------------------

if [[ "$STEP2_PULL_CHART" == "false" ]]; then
  echo "--- Step 2: SKIPPED (STEP2_PULL_CHART=false)"
  # CHART_SRC must point to an already-pulled chart directory containing Chart.yaml.
  [[ -z "${CHART_SRC:-}" ]] && { echo "ERROR: STEP2_PULL_CHART=false requires CHART_SRC to be set"; exit 1; }
  [[ -f "${CHART_SRC}/Chart.yaml" ]] || { echo "ERROR: Chart.yaml not found at CHART_SRC=${CHART_SRC}"; exit 1; }
  CHART_VERSION=$(yq '.version' "${CHART_SRC}/Chart.yaml")
  CHART_NAME=$(yq '.name' "${CHART_SRC}/Chart.yaml")
  echo "    chart=${CHART_NAME}  version=${CHART_VERSION}"
elif [[ "$SOURCE_TYPE" == "helm-registry" ]]; then
  echo "==> Step 2: Pulling helm chart from registry ${SOURCE_REPO}"

  CHART_DIR="${WORK_DIR}/chart"
  mkdir -p "$CHART_DIR"

  # Login to source registry if credentials provided
  if [[ -n "${PRODUCT_SOURCE_KEY:-}" ]]; then
    SOURCE_REGISTRY=$(echo "$SOURCE_REPO" | sed 's|oci://||' | cut -d'/' -f1)
    helm registry login "$SOURCE_REGISTRY" \
      --username "${PRODUCT_SOURCE_KEY%%:*}" \
      --password "${PRODUCT_SOURCE_KEY##*:}" 2>/dev/null || true
  fi

  helm pull "$SOURCE_REPO" --untar --untardir "$CHART_DIR" --insecure-skip-tls-verify || \
    { echo "ERROR: helm pull failed from ${SOURCE_REPO}"; exit 1; }

  # Find root application Chart.yaml, avoiding dependency library charts (e.g., charts/common)
  CHART_YAML=""
  while IFS= read -r f; do
    CHART_TYPE=$(yq '.type // "application"' "$f" 2>/dev/null || echo "application")
    if [[ "$CHART_TYPE" == "application" ]]; then
      CHART_YAML="$f"
      break
    fi
  done < <(find "$CHART_DIR" -name "Chart.yaml" | awk '{ print length, $0 }' | sort -n | cut -d" " -f2-)

  [[ -z "$CHART_YAML" ]] && { echo "ERROR: Application Chart.yaml not found after helm pull"; exit 1; }
  CHART_SRC="$(dirname "$CHART_YAML")"

elif [[ "$SOURCE_TYPE" == "helm-git" ]]; then
  echo "==> Step 2: Acquiring helm chart from git"

  if [[ -d "${PRODUCT_DIR}/chart" ]]; then
    # Chart is bundled directly in the product directory
    CHART_SRC="${PRODUCT_DIR}/chart"
  else
    SOURCE_BRANCH=$(yq '.spec.catalog.sourceBranch // "main"' "$METADATA_FILE")
    SOURCE_PATH=$(yq '.spec.catalog.sourcePath' "$METADATA_FILE")
    CHART_CLONE="${WORK_DIR}/chart-source"

    # Inject token into URL if PRODUCT_SOURCE_TOKEN is set
    CHART_CLONE_URL="$SOURCE_REPO"
    if [[ -n "${PRODUCT_SOURCE_TOKEN:-}" ]]; then
      CHART_CLONE_URL=$(echo "$SOURCE_REPO" | sed "s|https://|https://${PRODUCT_SOURCE_TOKEN}@|")
    fi

    git clone --no-checkout --depth=1 --branch "$SOURCE_BRANCH" "$CHART_CLONE_URL" "$CHART_CLONE"
    git -C "$CHART_CLONE" sparse-checkout init --cone
    git -C "$CHART_CLONE" sparse-checkout set "${SOURCE_PATH#/}"
    git -C "$CHART_CLONE" checkout
    CHART_SRC="${CHART_CLONE}/${SOURCE_PATH#/}"
  fi

  [[ -f "${CHART_SRC}/Chart.yaml" ]] || { echo "ERROR: Chart.yaml not found in chart source"; exit 1; }

else
  echo "ERROR: unsupported sourceType '${SOURCE_TYPE}' in metadata.yaml"
  exit 1
fi

CHART_VERSION=$(yq '.version' "${CHART_SRC}/Chart.yaml")
CHART_NAME=$(yq '.name' "${CHART_SRC}/Chart.yaml")
echo "    chart=${CHART_NAME}  version=${CHART_VERSION}"

# ---------------------------------------------------------------------------
# Step 3 — Deliver chart to target (helm-registry or helm-git)
# ---------------------------------------------------------------------------

if [[ "$STEP3_PUSH_CHART" == "false" ]]; then
  echo "--- Step 3: SKIPPED (STEP3_PUSH_CHART=false)"
  # Derive the same values step 3 would have produced, so downstream steps work unchanged.
  # Override SPEC_REGISTRY or SPEC_REPO_URL in import.env if the defaults are wrong.
  if [[ "$TARGET_TYPE" == "helm-registry" ]]; then
    SPEC_REGISTRY="${SPEC_REGISTRY:-oci://${QUAY_REGISTRY}/sovcloud/cp/sovereign-cloud-platform/byop/charts/${CHART_NAME}}"
    SPEC_REPO_URL=""
    echo "    SPEC_REGISTRY=${SPEC_REGISTRY}"
  else
    SPEC_REGISTRY=""
    SPEC_REPO_URL="${SPEC_REPO_URL:-${TARGET_REPO}}"
    [[ -z "$SPEC_REPO_URL" ]] && { echo "ERROR: STEP3_PUSH_CHART=false with helm-git requires SPEC_REPO_URL or TARGET_REPO to be set"; exit 1; }
    echo "    SPEC_REPO_URL=${SPEC_REPO_URL}"
  fi
elif [[ "$TARGET_TYPE" == "helm-registry" ]]; then
  echo "==> Step 3: Pushing helm chart to Quay registry"

  helm registry login "$QUAY_REGISTRY" --username "$QUAY_USERNAME" --password "$QUAY_PASSWORD" \
    --insecure

  CHART_TGZ="${WORK_DIR}/${CHART_NAME}-${CHART_VERSION}.tgz"
  helm package "$CHART_SRC" --destination "$WORK_DIR"

  helm push "$CHART_TGZ" \
    "oci://${QUAY_REGISTRY}/sovcloud/cp/sovereign-cloud-platform/byop/charts" \
    --insecure-skip-tls-verify

  SPEC_REGISTRY="oci://${QUAY_REGISTRY}/sovcloud/cp/sovereign-cloud-platform/byop/charts/${CHART_NAME}"
  SPEC_REPO_URL=""

elif [[ "$TARGET_TYPE" == "helm-git" ]]; then
  echo "==> Step 3: Copying helm chart to GitOps repo"

  for var in TARGET_REPO TARGET_BRANCH TARGET_TOKEN; do
    [[ -z "${!var:-}" ]] && { echo "ERROR: $var must be set in import.env for helm-git targetType"; exit 1; }
  done

  TARGET_CLONE="${WORK_DIR}/target"
  TARGET_CLONE_URL=$(echo "$TARGET_REPO" | sed "s|https://|https://${TARGET_TOKEN}@|")

  git clone --depth=1 --branch "$TARGET_BRANCH" "$TARGET_CLONE_URL" "$TARGET_CLONE"

  TARGET_PATH="${TARGET_CLONE}/products/${PRODUCT_ID}/${CHART_VERSION}/chart"
  mkdir -p "$TARGET_PATH"
  cp -r "${CHART_SRC}/." "$TARGET_PATH/"

  git -C "$TARGET_CLONE" add .
  git -C "$TARGET_CLONE" diff --cached --quiet || \
    git -C "$TARGET_CLONE" commit -m "chore: import ${PRODUCT_ID} chart ${CHART_VERSION}"
  git -C "$TARGET_CLONE" push "$TARGET_CLONE_URL" HEAD:"$TARGET_BRANCH"

  SPEC_REGISTRY=""
  SPEC_REPO_URL="$TARGET_REPO"

else
  echo "ERROR: unsupported targetType '${TARGET_TYPE}' in metadata.yaml (must be helm-registry or helm-git)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4 — Mirror images to Quay
# ---------------------------------------------------------------------------
# Images are defined inline in <version>/metadata.yaml — needed by Steps 4 and 5
IMAGE_COUNT=$(yq '.spec.catalog.images | length' "$METADATA_FILE")

if [[ "$STEP4_MIRROR_IMAGES" == "false" ]]; then
  echo "--- Step 4: SKIPPED (STEP4_MIRROR_IMAGES=false)"
else
echo "==> Step 4: Mirroring images to Quay"

skopeo login "$QUAY_REGISTRY" --username "$QUAY_USERNAME" --password "$QUAY_PASSWORD" --tls-verify=false

if [[ -n "${PRODUCT_REGISTRY_KEY:-}" ]]; then
  SRC_CREDS="--src-creds ${PRODUCT_REGISTRY_KEY}"
else
  SRC_CREDS=""
fi

for (( idx=0; idx<IMAGE_COUNT; idx++ )); do
  SRC_IMAGE=$(yq ".spec.catalog.images[${idx}].source" "$METADATA_FILE")
  DEST_LINE=$(yq ".spec.catalog.images[${idx}].destination" "$METADATA_FILE")

  # Derive Quay destination from the canonical chart path (destination field)
  REGISTRY=$(echo "$DEST_LINE" | cut -d'/' -f1)
  REMAINDER=$(echo "$DEST_LINE" | cut -d'/' -f2-)
  DEST_IMAGE="${QUAY_REGISTRY}/sovcloud/${REGISTRY}-mirror/${REMAINDER}"

  echo "    pull: ${SRC_IMAGE}"
  echo "    push: ${DEST_IMAGE}"

  # shellcheck disable=SC2086
  skopeo copy --all \
    $SRC_CREDS \
    --dest-tls-verify=false \
    "docker://${SRC_IMAGE}" \
    "docker://${DEST_IMAGE}"
done
fi

# ---------------------------------------------------------------------------
# Step 5 — Create BYOPTemplate CR
# ---------------------------------------------------------------------------
if [[ "$STEP5_CREATE_BYOP_TEMPLATE" == "false" ]]; then
  echo "--- Step 5: SKIPPED (STEP5_CREATE_BYOP_TEMPLATE=false)"
else
echo "==> Step 5: Creating BYOPTemplate CR"

# Encode schema from catalog/schema.json
SCHEMA_FILE="${PRODUCT_DIR}/catalog/schema.json"
[[ -f "$SCHEMA_FILE" && -s "$SCHEMA_FILE" ]] || { echo "ERROR: catalog/schema.json not found or empty in ${PRODUCT_DIR}"; exit 1; }
REGISTRATION_SCHEMA=$(base64 -i "$SCHEMA_FILE" | tr -d '\n')

# Build imageMirrors block from metadata.yaml (destination field = canonical chart path)
IMAGE_MIRRORS=""
for (( idx=0; idx<IMAGE_COUNT; idx++ )); do
  DEST_LINE=$(yq ".images[${idx}].destination" "$METADATA_FILE")
  REGISTRY=$(echo "$DEST_LINE" | cut -d'/' -f1)
  REMAINDER=$(echo "$DEST_LINE" | cut -d'/' -f2-)
  REPO_NO_TAG=$(echo "$REMAINDER" | cut -d':' -f1)
  MIRROR="${QUAY_REGISTRY}/sovcloud/${REGISTRY}-mirror/${REPO_NO_TAG}"
  IMAGE_MIRRORS="${IMAGE_MIRRORS}
  - source: ${REGISTRY}/${REPO_NO_TAG}
    mirrors:
      - ${MIRROR}
    mirrorByDigest: true"
done

# Read catalog fields from catalog/catalog.yaml
CATALOG_FILE="${PRODUCT_DIR}/catalog/catalog.yaml"
[[ -f "$CATALOG_FILE" ]] || { echo "ERROR: catalog/catalog.yaml not found in ${PRODUCT_DIR}"; exit 1; }
DISPLAY_NAME=$(yq '.display_name' "$CATALOG_FILE")
DESCRIPTION=$(yq '.description'   "$CATALOG_FILE")
CATEGORY=$(yq '.category // "other"' "$CATALOG_FILE")
SUPPORT_URL=$(yq '.support_url'   "$CATALOG_FILE")
MARKETING_URL=$(yq '.marketing_url' "$CATALOG_FILE")

CR_NAME="${PRODUCT_ID}-${SOURCE_TYPE}"
BYOP_NAMESPACE="byop-service-broker"

# Build source-type-specific fields
# CR sourceType reflects where the operator fetches the chart FROM (the target delivery)
if [[ "$TARGET_TYPE" == "helm-registry" ]]; then
  SOURCE_FIELDS="  sourceType: helm-registry
  registry: ${SPEC_REGISTRY}
  version: \"${CHART_VERSION}\""
else
  SOURCE_FIELDS="  sourceType: helm-git
  repoURL: ${SPEC_REPO_URL}
  version: \"${CHART_VERSION}\""
fi

CR_FILE="${WORK_DIR}/byoptemplate-${CR_NAME}.yaml"
cat > "$CR_FILE" <<EOF
apiVersion: byop.cloud.ibm.com/v1alpha1
kind: BYOPTemplate
metadata:
  name: ${CR_NAME}
  namespace: ${BYOP_NAMESPACE}
spec:
  productId: ${PRODUCT_ID}
${SOURCE_FIELDS}
  catalogRegistration:
    displayName: ${DISPLAY_NAME}
    description: ${DESCRIPTION}
    category: ${CATEGORY}
    tags: [$(yq '(.tags // []) | join(", ")' "$CATALOG_FILE")]
    supportUrl: ${SUPPORT_URL}
    marketingUrl: ${MARKETING_URL}
  imageMirrors:${IMAGE_MIRRORS}
  registrationSchema: ${REGISTRATION_SCHEMA}
EOF

echo "    Applying ${CR_FILE}"
oc apply -f "$CR_FILE"

# Apply cluster-scoped ImageTagMirrorSet and ImageDigestMirrorSet directly
if [[ $IMAGE_COUNT -gt 0 ]]; then
  echo "    Applying cluster ImageTagMirrorSet and ImageDigestMirrorSet for ${PRODUCT_ID}"

  ITMS_ENTRIES=""
  for (( idx=0; idx<IMAGE_COUNT; idx++ )); do
    DEST_LINE=$(yq ".spec.catalog.images[${idx}].destination" "$METADATA_FILE")
    REGISTRY=$(echo "$DEST_LINE" | cut -d'/' -f1)
    REMAINDER=$(echo "$DEST_LINE" | cut -d'/' -f2-)
    REPO_NO_TAG=$(echo "$REMAINDER" | cut -d':' -f1)
    MIRROR="${QUAY_REGISTRY}/sovcloud/${REGISTRY}-mirror/${REPO_NO_TAG}"
    ITMS_ENTRIES="${ITMS_ENTRIES}
    - source: ${REGISTRY}/${REPO_NO_TAG}
      mirrors:
        - ${MIRROR}"
  done

  ITMS_IDMS_FILE="${WORK_DIR}/itms-idms-${PRODUCT_ID}.yaml"
  cat > "$ITMS_IDMS_FILE" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: byop-${PRODUCT_ID}-tag-mirrors
spec:
  imageTagMirrors:${ITMS_ENTRIES}
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: byop-${PRODUCT_ID}-digest-mirrors
spec:
  imageDigestMirrors:${ITMS_ENTRIES}
EOF
  oc apply -f "$ITMS_IDMS_FILE" || echo "WARNING: Failed to apply ITMS/IDMS directly (cluster-scoped admin permissions may be required)"
fi

fi  # end Step 5

# ---------------------------------------------------------------------------
# Step 6 — Ensure platform owner secret exists in byop-service-broker
# ---------------------------------------------------------------------------
if [[ "$STEP6_CREATE_PLATFORM_OWNER_SECRET" == "false" ]]; then
  echo "--- Step 6: SKIPPED (STEP6_CREATE_PLATFORM_OWNER_SECRET=false)"
else
echo "==> Step 6: Ensuring platform owner secret 'byop-platform-owner-secret'"

[[ -z "${SOVEREIGN_CORE_APIKEY:-}" ]] && { echo "ERROR: SOVEREIGN_CORE_APIKEY must be set in import.env for Step 6"; exit 1; }

oc create secret generic byop-platform-owner-secret \
  --from-literal=apiKey="${SOVEREIGN_CORE_APIKEY}" \
  --namespace "${BYOP_NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -
echo "    byop-platform-owner-secret applied to namespace '${BYOP_NAMESPACE}'"

fi

# ---------------------------------------------------------------------------
# Step 7 — Register TARGET_REPO with ArgoCD in openshift-gitops
# ---------------------------------------------------------------------------
if [[ "$STEP7_REGISTER_TARGET_REPO" == "false" ]]; then
  echo "--- Step 7: SKIPPED (STEP7_REGISTER_TARGET_REPO=false)"
else
echo "==> Step 7: Registering GitOps repo with ArgoCD"

ARGOCD_SECRET_NAME="argocd-repo-byop-gitops"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"

# Build and apply the secret (HTTPS token-based)
ARGOCD_SECRET_FILE="${WORK_DIR}/argocd-repo-secret.yaml"
cat > "$ARGOCD_SECRET_FILE" <<ARGOEOF
apiVersion: v1
kind: Secret
metadata:
  name: ${ARGOCD_SECRET_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repo
stringData:
  type: git
  url: ${TARGET_REPO}
  username: token
  password: ${TARGET_TOKEN}
ARGOEOF

oc apply -f "$ARGOCD_SECRET_FILE"
echo "    ArgoCD repo secret '${ARGOCD_SECRET_NAME}' applied to namespace '${ARGOCD_NAMESPACE}'"

fi

# ---------------------------------------------------------------------------
# Step 8 — Ensure ACM placement resources exist in byop-service-broker
# These are cluster-level prerequisites created once; oc apply is idempotent.
# ---------------------------------------------------------------------------
if [[ "$STEP8_CREATE_ACM_PLACEMENT_RESOURCES" == "false" ]]; then
  echo "--- Step 8: SKIPPED (STEP8_CREATE_ACM_PLACEMENT_RESOURCES=false)"
else
echo "==> Step 8: Ensuring ACM ManagedClusterSetBinding / Placement / PlacementBinding"

ACM_MANIFEST="${WORK_DIR}/acm-placement.yaml"
cat > "$ACM_MANIFEST" <<ACMEOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: account
  namespace: ${BYOP_NAMESPACE}
  labels:
    app: byop-service-broker
    by-squad: byop
    for-product: all
spec:
  clusterSet: account
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: byop-image-mirror-placement
  namespace: ${BYOP_NAMESPACE}
  labels:
    app: byop-service-broker
    by-squad: byop
    for-product: all
spec:
  clusterSets:
    - account
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: byop-image-mirror-placement-binding
  namespace: ${BYOP_NAMESPACE}
  labels:
    app: byop-service-broker
    by-squad: byop
    for-product: all
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: byop-image-mirror-placement
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: byop-image-mirror-policy
ACMEOF

oc apply -f "$ACM_MANIFEST"
echo "    ACM placement resources applied to namespace '${BYOP_NAMESPACE}'"

fi

echo ""
echo "Done. BYOPTemplate '${CR_NAME}' applied to namespace '${BYOP_NAMESPACE}'."
