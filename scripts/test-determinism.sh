#!/bin/bash
# =============================================================================
# test-determinism.sh - Test agent determinism
# =============================================================================
# Usage: ./test-determinism.sh <agent> <inputs_dir> [runs]
# Example: ./test-determinism.sh discovery ./my-inputs 5
# =============================================================================
set -e

AGENT="${1:-}"
INPUTS_DIR="${2:-}"
RUNS="${3:-5}"

if [ -z "${AGENT}" ] || [ -z "${INPUTS_DIR}" ]; then
    echo "Usage: $0 <agent> <inputs_dir> [runs]"
    echo ""
    echo "Agents: discovery, context"
    echo "Runs: number of executions (default: 5)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

echo "═══════════════════════════════════════════════════════════════"
echo "  DETERMINISM TEST: ${AGENT}"
echo "═══════════════════════════════════════════════════════════════"
echo "Inputs: ${INPUTS_DIR}"
echo "Runs:   ${RUNS}"
echo ""

# Run agent N times
for i in $(seq 1 ${RUNS}); do
    echo "Run ${i}/${RUNS}..."
    
    if [ "${AGENT}" = "discovery" ]; then
        "${SCRIPT_DIR}/run-discovery.sh" "${INPUTS_DIR}" "${TEMP_DIR}/result-${i}.json" > /dev/null 2>&1
    elif [ "${AGENT}" = "context" ]; then
        # Context needs discovery first
        if [ ! -f "${TEMP_DIR}/discovery.json" ]; then
            "${SCRIPT_DIR}/run-discovery.sh" "${INPUTS_DIR}" "${TEMP_DIR}/discovery.json" > /dev/null 2>&1
        fi
        "${SCRIPT_DIR}/run-context.sh" "${INPUTS_DIR}" "${TEMP_DIR}/discovery.json" "${TEMP_DIR}/result-${i}.json" > /dev/null 2>&1
    else
        echo "ERROR: Unknown agent: ${AGENT}"
        exit 1
    fi
    
    sleep 1
done

echo ""
echo "───────────────────────────────────────────────────────────────"
echo "COMPARING RESULTS (ignoring timestamp)"
echo "───────────────────────────────────────────────────────────────"
echo ""

# Compute hashes (normalize timestamp)
HASHES=""
for i in $(seq 1 ${RUNS}); do
    HASH=$(python3 -c "
import json
with open('${TEMP_DIR}/result-${i}.json') as f:
    d = json.load(f)
    d.pop('timestamp', None)
    print(json.dumps(d, sort_keys=True))
" | md5sum | cut -d' ' -f1)
    echo "  Run ${i}: ${HASH}"
    HASHES="${HASHES}${HASH}\n"
done

# Count unique hashes
UNIQUE=$(echo -e "${HASHES}" | sort | uniq | wc -l)
IDENTICAL=$((RUNS - UNIQUE + 1))

echo ""
echo "───────────────────────────────────────────────────────────────"
if [ "${UNIQUE}" -eq 1 ]; then
    echo "✅ DETERMINISM: 100% (${RUNS}/${RUNS} identical)"
else
    echo "❌ DETERMINISM: ${IDENTICAL}/${RUNS} identical (${UNIQUE} variants)"
fi
echo "───────────────────────────────────────────────────────────────"
