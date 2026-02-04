#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# ORCHESTRATOR - Enablement 2.0
# ═══════════════════════════════════════════════════════════════════════════
# Full pipeline orchestration: Discovery → Context → Plan → Generate
# Creates KB-compliant output package (per flow-generate-output.md)
#
# Usage:
#   ./orchestrate.sh <inputs_dir> [base_output_dir]
#
# Where inputs_dir contains:
#   - prompt.txt              (user prompt, required)
#   - domain-api-spec.yaml    (OpenAPI spec, optional)
#   - system-api-*.yaml       (System API specs, optional)
#   - mapping.json            (field mappings, optional)
#
# Output Structure (KB-compliant):
#   gen_{service-name}_{YYYYMMDD_HHMMSS}/
#   ├── input/                      # Original user inputs
#   │   ├── prompt.txt
#   │   ├── domain-api-spec.yaml
#   │   └── mapping.json
#   ├── output/                     # Generated project
#   │   └── {service-name}/
#   │       ├── src/...
#   │       ├── pom.xml
#   │       └── .enablement/manifest.json
#   ├── trace/                      # All traceability
#   │   ├── discovery-result.json
#   │   ├── generation-context.json
#   │   ├── execution-plan.json
#   │   └── codegen-result-*.json
#   └── validation/                 # Validation suite
#       ├── run-all.sh
#       └── scripts/tier{1,2,3}/
# ═══════════════════════════════════════════════════════════════════════════
set -e

INPUTS_DIR="${1:-}"
BASE_OUTPUT_DIR="${2:-.}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${INPUTS_DIR}" ]; then
    echo "Usage: $0 <inputs_dir> [base_output_dir]"
    echo ""
    echo "Where inputs_dir contains:"
    echo "  - prompt.txt              (required)"
    echo "  - domain-api-spec.yaml    (optional)"
    echo "  - system-api-*.yaml       (optional)"
    echo "  - mapping.json            (optional)"
    echo ""
    echo "Example:"
    echo "  $0 ./poc-inputs ."
    exit 1
fi

if [ ! -d "${INPUTS_DIR}" ]; then
    echo "ERROR: Inputs directory not found: ${INPUTS_DIR}"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════════════════"
echo "  ENABLEMENT 2.0 ORCHESTRATOR"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0: INIT - Determine service name and create package structure
# ─────────────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  PHASE 0: INIT"
echo "─────────────────────────────────────────────────────────────────────────────"

# Extract service name from prompt or spec
SERVICE_NAME=$(python3 << EXTRACT_NAME
import os
import yaml
import re

inputs_dir = '${INPUTS_DIR}'

# Try to get from OpenAPI spec first
for f in os.listdir(inputs_dir):
    if f.endswith('.yaml') or f.endswith('.yml'):
        try:
            with open(os.path.join(inputs_dir, f)) as yf:
                spec = yaml.safe_load(yf)
                if spec and 'info' in spec and 'title' in spec['info']:
                    # Convert "Customer API" to "customer-api"
                    title = spec['info']['title']
                    name = re.sub(r'[^a-zA-Z0-9]+', '-', title).lower().strip('-')
                    print(name)
                    exit(0)
        except:
            pass

# Fallback: use directory name
print(os.path.basename(inputs_dir.rstrip('/')))
EXTRACT_NAME
)

# Generate package name
RUN_ID=$(date +%Y%m%d_%H%M%S)
PACKAGE_NAME="gen_${SERVICE_NAME}_${RUN_ID}"
PACKAGE_DIR="${BASE_OUTPUT_DIR}/${PACKAGE_NAME}"

echo "  Service:  ${SERVICE_NAME}"
echo "  Run ID:   ${RUN_ID}"
echo "  Package:  ${PACKAGE_DIR}"
echo ""

# Create structure
mkdir -p "${PACKAGE_DIR}/input"
mkdir -p "${PACKAGE_DIR}/output"
mkdir -p "${PACKAGE_DIR}/trace"
mkdir -p "${PACKAGE_DIR}/validation"

# Copy original inputs
echo "  Copying inputs..."
for f in "${INPUTS_DIR}"/*; do
    if [ -f "$f" ]; then
        cp "$f" "${PACKAGE_DIR}/input/"
        echo "    → $(basename $f)"
    fi
done
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: DISCOVERY
# ─────────────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  PHASE 1: DISCOVERY"
echo "─────────────────────────────────────────────────────────────────────────────"

DISCOVERY_OUTPUT="${PACKAGE_DIR}/trace/discovery-result.json"

if ! "${SCRIPT_DIR}/run-discovery.sh" "${PACKAGE_DIR}/input" "${DISCOVERY_OUTPUT}"; then
    echo "ERROR: Discovery phase failed"
    exit 1
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: CONTEXT RESOLUTION
# ─────────────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  PHASE 2: CONTEXT RESOLUTION"
echo "─────────────────────────────────────────────────────────────────────────────"

CONTEXT_OUTPUT="${PACKAGE_DIR}/trace/generation-context.json"

if ! "${SCRIPT_DIR}/run-context.sh" "${PACKAGE_DIR}/input" "${DISCOVERY_OUTPUT}" "${CONTEXT_OUTPUT}"; then
    echo "ERROR: Context resolution phase failed"
    exit 1
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: PLAN
# ─────────────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  PHASE 3: EXECUTION PLAN"
echo "─────────────────────────────────────────────────────────────────────────────"

PLAN_OUTPUT="${PACKAGE_DIR}/trace/execution-plan.json"

if ! "${SCRIPT_DIR}/run-plan.sh" "${DISCOVERY_OUTPUT}" "${CONTEXT_OUTPUT}" "${PLAN_OUTPUT}"; then
    echo "ERROR: Plan phase failed"
    exit 1
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: CODE GENERATION
# ─────────────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  PHASE 4: CODE GENERATION"
echo "─────────────────────────────────────────────────────────────────────────────"

PROJECT_DIR="${PACKAGE_DIR}/output/${SERVICE_NAME}"

if ! "${SCRIPT_DIR}/run-generate.sh" "${PLAN_OUTPUT}" "${CONTEXT_OUTPUT}" "${PROJECT_DIR}"; then
    echo "WARNING: Code generation had failures"
    GENERATION_STATUS="PARTIAL"
else
    GENERATION_STATUS="SUCCESS"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: ASSEMBLE PACKAGE
# ─────────────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  PHASE 5: ASSEMBLE PACKAGE"
echo "─────────────────────────────────────────────────────────────────────────────"

# Move codegen trace files from project to package trace
if [ -d "${PROJECT_DIR}/.trace" ]; then
    mv "${PROJECT_DIR}/.trace"/* "${PACKAGE_DIR}/trace/" 2>/dev/null || true
    rmdir "${PROJECT_DIR}/.trace" 2>/dev/null || true
    echo "  ✓ Moved trace files"
fi

# Move validation from project to package level
if [ -d "${PROJECT_DIR}/validation" ]; then
    cp -r "${PROJECT_DIR}/validation"/* "${PACKAGE_DIR}/validation/" 2>/dev/null || true
    rm -rf "${PROJECT_DIR}/validation"
    echo "  ✓ Moved validation scripts"
fi

# Update validation paths to point to correct project location
if [ -f "${PACKAGE_DIR}/validation/run-all.sh" ]; then
    # The validation scripts need to know the project is in output/{service}/
    sed -i.bak 's|PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"|PROJECT_DIR="$(cd "${SCRIPT_DIR}/../output/'"${SERVICE_NAME}"'" \&\& pwd)"|' \
        "${PACKAGE_DIR}/validation/run-all.sh" 2>/dev/null || true
    rm -f "${PACKAGE_DIR}/validation/run-all.sh.bak"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  ORCHESTRATION COMPLETE"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Package:     ${PACKAGE_DIR}"
echo "  Status:      ${GENERATION_STATUS}"
echo ""
echo "  Structure:"
echo "    ${PACKAGE_NAME}/"
echo "    ├── input/        $(ls -1 ${PACKAGE_DIR}/input 2>/dev/null | wc -l | tr -d ' ') files"
echo "    ├── output/${SERVICE_NAME}/"
echo "    ├── trace/        $(ls -1 ${PACKAGE_DIR}/trace 2>/dev/null | wc -l | tr -d ' ') files"
echo "    └── validation/"
echo ""
echo "  To validate:"
echo "    ${PACKAGE_DIR}/validation/run-all.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"

if [ "${GENERATION_STATUS}" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi
