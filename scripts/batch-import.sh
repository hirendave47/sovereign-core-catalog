#!/usr/bin/env bash
# batch-import.sh [products-file]
#
# Imports multiple BYOP products by calling import.sh for each one.
#
# Usage:
#   ./batch-import.sh                         # reads products.txt in the same directory
#   ./batch-import.sh my-product-list.txt     # reads a custom file
#
# products-file format (one entry per line):
#   <product_name> [vX.X.X]
#
#   Lines starting with '#' and blank lines are ignored.
#   Version is optional; import.sh auto-selects the latest if omitted.
#
# Examples:
#   kafka
#   kafka v4.0.0
#   mariadb v12.3.2
#
# Exit codes:
#   0  — all products imported successfully
#   1  — one or more products failed (see summary at the end)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT_SH="${SCRIPT_DIR}/import.sh"
PRODUCTS_FILE="${1:-${SCRIPT_DIR}/products.txt}"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
[[ -x "$IMPORT_SH" ]] || { echo "ERROR: import.sh not found or not executable at ${IMPORT_SH}"; exit 1; }
[[ -f "$PRODUCTS_FILE" ]] || { echo "ERROR: products file not found: ${PRODUCTS_FILE}"; exit 1; }

# ---------------------------------------------------------------------------
# Parse products file
# ---------------------------------------------------------------------------
PRODUCTS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip leading/trailing whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  # Skip blank lines and comments
  [[ -z "$line" || "$line" == \#* ]] && continue
  PRODUCTS+=("$line")
done < "$PRODUCTS_FILE"

if [[ ${#PRODUCTS[@]} -eq 0 ]]; then
  echo "ERROR: no products found in ${PRODUCTS_FILE}"
  exit 1
fi

echo "=========================================="
echo " BYOP Batch Import"
echo " Products file : ${PRODUCTS_FILE}"
echo " Total products: ${#PRODUCTS[@]}"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# Import each product
# ---------------------------------------------------------------------------
PASS=()
FAIL=()

for entry in "${PRODUCTS[@]}"; do
  # Split into product name and optional version
  read -r product version <<< "$entry"

  echo "------------------------------------------"
  if [[ -n "${version:-}" ]]; then
    echo "Importing: ${product} ${version}"
    echo "------------------------------------------"
    if "$IMPORT_SH" "$product" "$version"; then
      PASS+=("${product} ${version}")
    else
      echo "ERROR: import failed for '${product} ${version}'"
      FAIL+=("${product} ${version}")
    fi
  else
    echo "Importing: ${product} (latest)"
    echo "------------------------------------------"
    if "$IMPORT_SH" "$product"; then
      PASS+=("${product}")
    else
      echo "ERROR: import failed for '${product}'"
      FAIL+=("${product}")
    fi
  fi
  echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Batch Import Summary"
echo "=========================================="
echo " Passed : ${#PASS[@]}"
for p in "${PASS[@]}"; do echo "   ✓ ${p}"; done
echo " Failed : ${#FAIL[@]}"
for f in "${FAIL[@]}"; do echo "   ✗ ${f}"; done
echo "=========================================="

[[ ${#FAIL[@]} -eq 0 ]]
