#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PLAN AGENT - Enablement 2.0
# ═══════════════════════════════════════════════════════════════════════════
# Generates execution plan from discovery result
#
# Usage:
#   ./run-plan.sh <discovery_file> <context_file> [output_file]
#
# Inputs:
#   - discovery_file: JSON from Discovery Agent (discovery-result.json)
#   - context_file: JSON from Context Agent (generation-context.json)
#
# Output:
#   - execution-plan.json: Ordered list of generation steps
# ═══════════════════════════════════════════════════════════════════════════
set -e

DISCOVERY_FILE="${1:-}"
CONTEXT_FILE="${2:-}"
OUTPUT_FILE="${3:-execution-plan.json}"

# Resolve KB_DIR relative to script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="${KB_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/enablement-2.0-kb}"

MODULES_DIR="${KB_DIR}/modules"

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${DISCOVERY_FILE}" ] || [ -z "${CONTEXT_FILE}" ]; then
    echo "Usage: $0 <discovery_file> <context_file> [output_file]"
    exit 1
fi

if [ ! -f "${DISCOVERY_FILE}" ]; then
    echo "ERROR: Discovery file not found: ${DISCOVERY_FILE}"
    exit 1
fi

if [ ! -f "${CONTEXT_FILE}" ]; then
    echo "ERROR: Context file not found: ${CONTEXT_FILE}"
    exit 1
fi

if [ ! -d "${MODULES_DIR}" ]; then
    echo "ERROR: Modules directory not found: ${MODULES_DIR}"
    echo "       Set KB_DIR environment variable or check repo structure"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  PLAN AGENT"
echo "═══════════════════════════════════════════════════════════════"
echo "Discovery: ${DISCOVERY_FILE}"
echo "Context:   ${CONTEXT_FILE}"
echo "Output:    ${OUTPUT_FILE}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Build prompt with EMBEDDED system prompt
# ─────────────────────────────────────────────────────────────────────────────
TEMP_PROMPT=$(mktemp)
trap "rm -f ${TEMP_PROMPT}" EXIT

cat >> "${TEMP_PROMPT}" << 'SYSTEM_PROMPT'
You are the Plan Agent for Enablement 2.0.

## Task

Generate an execution plan that organizes modules into PHASES and SUBPHASES for holistic code generation. Each subphase groups modules that should be generated TOGETHER in a single LLM invocation.

## Critical Rules

1. **Output ONLY valid JSON** - No explanations, no markdown code blocks, no preamble
2. **Be 100% deterministic** - Same inputs MUST produce EXACTLY the same output
3. **Follow phase ordering strictly** - Phase 1 → Phase 2 → Phase 3
4. **Within each subphase, sort modules alphabetically by module_id**
5. **Use ONLY data from inputs** - Never invent or assume values

## Subphase Optimization Rules (ODEC-015)

Modules within a subphase are generated HOLISTICALLY (single LLM call, shared context).
Correct grouping is CRITICAL for code consistency.

### PRIMARY RULE: Minimize Subphases per Phase

**Default:** ALL modules in a phase go into ONE subphase (if ≤4 modules).

```
Phase 1: ALL structural modules    → Subphase 1.1
Phase 2: ALL implementation modules → Subphase 2.1
Phase 3: ALL cross-cutting modules  → Subphase 3.1
```

**This is the PREFERRED output for most services.**

### OVERFLOW RULE: Split only when >4 modules

If a phase has MORE than 4 modules, split by architectural layer:

| Layer | Modules | Subphase |
|-------|---------|----------|
| adapter/out/persistence | jpa, systemapi, redis, cache | X.1 |
| adapter/out/integration | rest-client, kafka, soap | X.2 |
| adapter/in | controllers, handlers | X.3 |

### DEPENDENCY RULE: Force co-location

**Known dependencies (must be in SAME subphase):**
- `mod-017-persistence-systemapi` + `mod-018-api-integration-rest` → both use RestClient patterns
- All resilience modules → apply together to same adapters

If splitting would separate dependent modules, keep them together even if >4.

### Context Limit

- **Soft limit:** 4 modules per subphase
- **Hard limit:** 6 modules per subphase (only if dependencies force it)
- If >6 modules with circular dependencies → ERROR, review architecture

## EXACT Output Schema

{
  "version": "1.0",
  "timestamp": "2026-01-30T00:00:00Z",
  "agent": "plan",
  "service_name": "{{from discovery.service_name}}",
  "total_subphases": {{integer count of subphases}},
  "phases": [
    {
      "phase": 1,
      "name": "structural",
      "description": "Foundation and architecture setup",
      "subphases": [
        {
          "id": "1.1",
          "name": "core-architecture",
          "action": "generate",
          "modules": [
            {
              "module_id": "{{module_id, alphabetically sorted}}",
              "capability_id": "{{capability_id}}",
              "templates_path": "modules/{{module_id}}/templates"
            }
          ],
          "depends_on_subphases": []
        }
      ]
    },
    {
      "phase": 2,
      "name": "implementation",
      "description": "Persistence and integration adapters",
      "subphases": [
        {
          "id": "2.1",
          "name": "implementation",
          "action": "generate",
          "modules": [...all Phase 2 modules together...],
          "depends_on_subphases": ["1.1"]
        }
      ]
    },
    {
      "phase": 3,
      "name": "cross_cutting",
      "description": "Patterns applied as code transformations",
      "subphases": [
        {
          "id": "3.1",
          "name": "resilience",
          "action": "transform",
          "target_layer": "adapter/out",
          "modules": [...],
          "depends_on_subphases": ["1.1", "2.1"]
        }
      ]
    }
  ],
  "execution_order": ["1.1", "2.1", "3.1"],
  "validation_modules": ["{{ALL module_ids, sorted alphabetically}}"]
}

## ORDERING RULES (Critical for determinism)

1. **Phase ordering:** Always Phase 1 → Phase 2 → Phase 3
2. **Subphase IDs:** Format "X.Y" where X=phase number, Y=sequential (1,2,3...)
3. **Within subphase:** Sort modules ALPHABETICALLY by module_id
4. **Subphase naming:** Based on content (see table below)
5. **depends_on_subphases:** Include all prior subphase IDs that this subphase depends on, sorted
6. **execution_order:** List all subphase IDs in execution sequence
7. **validation_modules:** ALL module_ids from discovery, sorted alphabetically

## ACTION RULES

- Phase 1 & 2 subphases: action = "generate"
- Phase 3 subphases: action = "transform"

## SUBPHASE NAMING CONVENTIONS

| Modules in Subphase | Subphase Name |
|---------------------|---------------|
| hexagonal + api-exposure only | core-architecture |
| ALL Phase 2 modules (≤4) | implementation |
| persistence modules only | persistence |
| integration modules only | integration |
| ALL Phase 3 resilience | resilience |

## EXAMPLE: Simple service (7 modules, typical case)

Input modules by phase:
- Phase 1: mod-015-hexagonal, mod-019-api-exposure (2 modules)
- Phase 2: mod-017-persistence-systemapi, mod-018-api-integration (2 modules)
- Phase 3: mod-001-circuit-breaker, mod-002-retry, mod-003-timeout (3 modules)

**Analysis:** Each phase has ≤4 modules → ONE subphase per phase

Output subphases:
- 1.1 core-architecture: [mod-015, mod-019] - ALL structural together
- 2.1 implementation: [mod-017, mod-018] - ALL implementation together
- 3.1 resilience: [mod-001, mod-002, mod-003] - ALL cross-cutting together

**Total: 3 subphases (minimum possible)**

## EXAMPLE: Large service (10 modules in Phase 2)

Input modules Phase 2:
- mod-016-jpa, mod-017-systemapi, mod-020-redis, mod-021-cache (4 persistence)
- mod-018-rest, mod-022-kafka, mod-023-soap (3 integration)

**Analysis:** 7 modules > 4 → must split by layer

Output subphases:
- 2.1 persistence: [mod-016, mod-017, mod-020, mod-021] - adapter/out/persistence
- 2.2 integration: [mod-018, mod-022, mod-023] - adapter/out/integration

**Dependency check:** No cross-dependencies between persistence and integration → split OK

---

Generate the execution plan from these inputs:

SYSTEM_PROMPT

# Add discovery result
echo "" >> "${TEMP_PROMPT}"
echo "<discovery_result>" >> "${TEMP_PROMPT}"
cat "${DISCOVERY_FILE}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</discovery_result>" >> "${TEMP_PROMPT}"

# Add generation context
echo "" >> "${TEMP_PROMPT}"
echo "<generation_context>" >> "${TEMP_PROMPT}"
cat "${CONTEXT_FILE}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</generation_context>" >> "${TEMP_PROMPT}"

# Final instruction
echo "" >> "${TEMP_PROMPT}"
echo "---" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "OUTPUT ONLY THE JSON. No preamble, no explanation, no markdown code blocks." >> "${TEMP_PROMPT}"

# ─────────────────────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# Validate
# ─────────────────────────────────────────────────────────────────────────────
if python3 -c "import json; json.load(open('${OUTPUT_FILE}'))" 2>/dev/null; then
    echo "✓ Valid JSON"
    echo ""
    python3 << PYSCRIPT
import json
with open('${OUTPUT_FILE}') as f:
    d = json.load(f)
    print(f"Service:        {d.get('service_name', 'N/A')}")
    print(f"Total Subphases: {d.get('total_subphases', 0)}")
    phases = d.get('phases', [])
    for p in phases:
        subphases = p.get('subphases', [])
        total_modules = sum(len(sp.get('modules', [])) for sp in subphases)
        print(f"Phase {p.get('phase')} ({p.get('name')}): {len(subphases)} subphase(s), {total_modules} module(s)")
        for sp in subphases:
            modules = [m.get('module_id', '?').split('-')[-1] for m in sp.get('modules', [])]
            print(f"  └─ {sp.get('id')} {sp.get('name')}: [{', '.join(modules)}]")
    print(f"Validations:    {len(d.get('validation_modules', []))}")
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
