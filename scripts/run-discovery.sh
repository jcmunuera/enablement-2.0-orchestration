#!/bin/bash
# =============================================================================
# run-discovery.sh - Execute Discovery Agent
# =============================================================================
# Usage: ./run-discovery.sh <inputs_dir> [output_file]
# =============================================================================
set -e

INPUTS_DIR="${1:-}"
OUTPUT_FILE="${2:-discovery-result.json}"

if [ -z "${INPUTS_DIR}" ]; then
    echo "Usage: $0 <inputs_dir> [output_file]"
    exit 1
fi

[ ! -d "${INPUTS_DIR}" ] && echo "ERROR: Directory not found: ${INPUTS_DIR}" && exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="${KB_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/enablement-2.0-kb}"

CAPABILITY_INDEX="${KB_DIR}/runtime/discovery/capability-index.yaml"
DISCOVERY_GUIDANCE="${KB_DIR}/runtime/discovery/discovery-guidance.md"

[ ! -f "${INPUTS_DIR}/prompt.md" ] && echo "ERROR: Missing prompt.md" && exit 1
[ ! -f "${CAPABILITY_INDEX}" ] && echo "ERROR: Missing capability-index.yaml" && exit 1
[ ! -f "${DISCOVERY_GUIDANCE}" ] && echo "ERROR: Missing discovery-guidance.md" && exit 1

echo "═══════════════════════════════════════════════════════════════"
echo "  DISCOVERY AGENT"
echo "═══════════════════════════════════════════════════════════════"
echo "Inputs:  ${INPUTS_DIR}"
echo "Output:  ${OUTPUT_FILE}"
echo ""

TEMP_PROMPT=$(mktemp)
trap "rm -f ${TEMP_PROMPT}" EXIT

# =============================================================================
# SYSTEM PROMPT - EMBEBIDO PARA DETERMINISMO
# =============================================================================
cat >> "${TEMP_PROMPT}" << 'SYSTEM_PROMPT'
You are the Discovery Agent for Enablement 2.0.

## Task
Analyze the provided inputs and produce a JSON output identifying the capabilities needed to generate the requested service.

## Critical Rules

1. **Output ONLY valid JSON** - No explanations, no markdown code blocks, no commentary before or after
2. **Use ONLY capabilities defined in capability-index.yaml** - Never invent capabilities
3. **Follow discovery-guidance.md rules R1-R9 exactly** - Apply rules in order
4. **Be deterministic** - Given the same inputs, always produce the same output

## Detection Algorithm

Apply these rules IN ORDER:
- R1: Keyword Matching (scan prompt for capability keywords)
- R2: Default Features (use default_feature when capability detected without specific feature)
- R3: Dependency Resolution (add required dependencies)
- R4: Foundational Guarantee (always include architecture.hexagonal-light for java-springboot)
- R5: Incompatibility Check (verify no mutually exclusive capabilities)
- R6: Phase Assignment (assign modules to phases 1/2/3)
- R7: Config Prerequisites (verify config requirements)
- R8: Resolve Implications (apply 'implies' relationships)
- R9: Calculate Config Flags (compute flags from config_rules)

## EXACT Output Schema

You MUST produce EXACTLY this JSON structure. No variations. No extra fields. No wrapper objects.

{
  "version": "1.0",
  "timestamp": "{{ISO-8601 timestamp}}",
  "agent": "discovery",
  "service_name": "{{extracted from prompt}}",
  "stack": "java-springboot",
  "detected_capabilities": [
    {
      "capability_id": "{{capability.feature, e.g., 'resilience.circuit-breaker'}}",
      "feature": "{{feature name, e.g., 'circuit-breaker'}}",
      "module_id": "{{full module id, e.g., 'mod-code-001-circuit-breaker-java-resilience4j'}}",
      "phase": {{1 or 2 or 3}},
      "detection_reason": "{{one of: foundational, keyword, dependency, implication}}"
    }
  ],
  "phases": {
    "1_structural": ["{{module_ids sorted alphabetically}}"],
    "2_implementation": ["{{module_ids sorted alphabetically}}"],
    "3_cross_cutting": ["{{module_ids sorted alphabetically}}"]
  },
  "config_flags": {
    "transactional": {{true or false}},
    "idempotent": {{true or false}}
  },
  "variant_selections": {
    "{{module_id.variant_name}}": "{{selected_option}}"
  },
  "warnings": [],
  "errors": []
}

## VARIANT DETECTION (DEC-041)

When a module has variants (defined in MODULE.md), scan the prompt for variant keywords:

| Module | Variant | Keywords → Selection |
|--------|---------|---------------------|
| mod-code-017-persistence-systemapi | http_client | "feign", "openfeign", "declarative client" → "feign" |
| mod-code-017-persistence-systemapi | http_client | "resttemplate", "rest template", "legacy client" → "resttemplate" |
| mod-code-017-persistence-systemapi | http_client | "restclient", "rest client", "webclient" → "restclient" |

**Rules:**
1. Only check variants for detected modules
2. If NO keyword found, do NOT include in variant_selections (Context Agent will use module default)
3. If keyword found, include: `"mod-017.http_client": "feign"`

## SORTING RULES (for determinism)

1. detected_capabilities[]: Sort by phase ASC, then by capability_id ASC
2. phases.1_structural[]: Sort alphabetically
3. phases.2_implementation[]: Sort alphabetically
4. phases.3_cross_cutting[]: Sort alphabetically

---

Analyze these inputs:

SYSTEM_PROMPT

# Add inputs
echo "" >> "${TEMP_PROMPT}"
echo "<prompt>" >> "${TEMP_PROMPT}"
cat "${INPUTS_DIR}/prompt.md" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</prompt>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "<domain_api_spec>" >> "${TEMP_PROMPT}"
if [ -f "${INPUTS_DIR}/domain-api-spec.yaml" ]; then
    cat "${INPUTS_DIR}/domain-api-spec.yaml" >> "${TEMP_PROMPT}"
else
    echo "(not provided)" >> "${TEMP_PROMPT}"
fi
echo "" >> "${TEMP_PROMPT}"
echo "</domain_api_spec>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "<system_api_spec>" >> "${TEMP_PROMPT}"
SYSTEM_APIS=$(find "${INPUTS_DIR}" -name "system-api-*.yaml" 2>/dev/null || true)
if [ -n "${SYSTEM_APIS}" ]; then
    echo "${SYSTEM_APIS}" | while read -r api; do
        echo "--- $(basename "${api}") ---" >> "${TEMP_PROMPT}"
        cat "${api}" >> "${TEMP_PROMPT}"
        echo "" >> "${TEMP_PROMPT}"
    done
else
    echo "(not provided)" >> "${TEMP_PROMPT}"
fi
echo "</system_api_spec>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "<mapping>" >> "${TEMP_PROMPT}"
if [ -f "${INPUTS_DIR}/mapping.json" ]; then
    cat "${INPUTS_DIR}/mapping.json" >> "${TEMP_PROMPT}"
else
    echo "(not provided)" >> "${TEMP_PROMPT}"
fi
echo "" >> "${TEMP_PROMPT}"
echo "</mapping>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "<capability_index>" >> "${TEMP_PROMPT}"
cat "${CAPABILITY_INDEX}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</capability_index>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "<discovery_guidance>" >> "${TEMP_PROMPT}"
cat "${DISCOVERY_GUIDANCE}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</discovery_guidance>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "---" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "OUTPUT ONLY THE JSON. No preamble, no explanation, no markdown code blocks." >> "${TEMP_PROMPT}"

# Execute
echo "Executing Claude..."
OUTPUT_DIR=$(dirname "${OUTPUT_FILE}")
[ -n "${OUTPUT_DIR}" ] && [ "${OUTPUT_DIR}" != "." ] && mkdir -p "${OUTPUT_DIR}"

if ! cat "${TEMP_PROMPT}" | claude -p --tools "" > "${OUTPUT_FILE}" 2>/dev/null; then
    echo "ERROR: Claude execution failed"
    exit 1
fi

# Clean markdown code blocks if present
python3 -c "
import re
with open('${OUTPUT_FILE}', 'r') as f:
    content = f.read()
content = re.sub(r'^\s*\x60\x60\x60json?\s*\n', '', content)
content = re.sub(r'\n\s*\x60\x60\x60\s*\$', '', content)
with open('${OUTPUT_FILE}', 'w') as f:
    f.write(content)
"

# Validate
if python3 -c "import json; json.load(open('${OUTPUT_FILE}'))" 2>/dev/null; then
    echo "✓ Valid JSON"
    echo ""
    python3 << PYSCRIPT
import json
with open('${OUTPUT_FILE}') as f:
    d = json.load(f)
    print(f"Service:      {d.get('service_name', 'N/A')}")
    print(f"Capabilities: {len(d.get('detected_capabilities', []))}")
    phases = d.get('phases', {})
    print(f"Phase 1:      {len(phases.get('1_structural', []))} modules")
    print(f"Phase 2:      {len(phases.get('2_implementation', []))} modules")
    print(f"Phase 3:      {len(phases.get('3_cross_cutting', []))} modules")
PYSCRIPT
else
    echo "✗ Invalid JSON"
    head -20 "${OUTPUT_FILE}"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Output: ${OUTPUT_FILE}"
echo "═══════════════════════════════════════════════════════════════"
