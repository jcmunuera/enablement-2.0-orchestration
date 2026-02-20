# Discovery Agent

## Purpose
Analyzes user inputs to identify required capabilities for code generation.
Supports two operational modes:
- **Mode A (Standalone):** Discovery from prompt only. No prior context.
- **Mode B (DESIGN-seeded):** Receives a manifest.yaml with pre-resolved capabilities from DESIGN pipeline. Merges with prompt-discovered capabilities.

## Execution
```bash
./scripts/run-discovery.sh <inputs_dir> [output_file]
```

## Inputs
- `prompt.md` - User requirements (required)
- `domain-api-spec.yaml` - OpenAPI spec for domain API (optional)
- `system-api-*.yaml` - OpenAPI specs for backend APIs (optional)
- `mapping.json` - Field mapping configuration (optional)
- `manifest.yaml` - DESIGN-resolved capabilities (optional, triggers Mode B)

## Mode Detection
- If `manifest.yaml` exists in inputs → **Mode B**
- Otherwise → **Mode A**

## Mode B: Merge with Precedence
When manifest.yaml is present:
1. Load seed capabilities from manifest (already validated by DESIGN pipeline)
2. Extract service_name from manifest.context_id (e.g., card-management)
3. Extract tech_defaults from manifest (e.g., http_client: feign)
4. Run normal discovery on prompt (R1-R9) to find additional capabilities
5. Merge: seed capabilities + prompt-discovered, no duplicates. Seed has precedence.
6. Resolve modules from final capability set using capability-index.yaml
7. Apply tech_defaults as variant_selections
8. Mark detection_reason as "design-seeded" for manifest capabilities

## KB Dependencies
- `runtime/discovery/capability-index.yaml`
- `runtime/discovery/discovery-guidance.md`

## Output Schema
```json
{
  "version": "1.0",
  "timestamp": "ISO-8601",
  "agent": "discovery",
  "service_name": "from prompt",
  "stack": "java-springboot",
  "detected_capabilities": [
    {
      "capability_id": "capability.feature",
      "feature": "feature name",
      "module_id": "full module id",
      "phase": 1|2|3,
      "detection_reason": "foundational|keyword|dependency|implication"
    }
  ],
  "phases": {
    "1_structural": ["module_ids sorted alphabetically"],
    "2_implementation": ["module_ids sorted alphabetically"],
    "3_cross_cutting": ["module_ids sorted alphabetically"]
  },
  "config_flags": {
    "transactional": true|false,
    "idempotent": true|false
  },
  "warnings": [],
  "errors": []
}
```

## Determinism Rules
1. Sort `detected_capabilities[]` by: phase ASC, then capability_id ASC
2. Sort all phase arrays alphabetically
3. Use full module IDs from capability-index.yaml
4. `detection_reason` must be one of: foundational, keyword, dependency, implication

## Algorithm (R1-R9)
1. R1: Keyword Matching
2. R2: Default Features
3. R3: Dependency Resolution
4. R4: Foundational Guarantee
5. R5: Incompatibility Check
6. R6: Phase Assignment
7. R7: Config Prerequisites
8. R8: Resolve Implications
9. R9: Calculate Config Flags
