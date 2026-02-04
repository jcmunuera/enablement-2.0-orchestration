# Discovery Agent

## Purpose
Analyzes user inputs to identify required capabilities for code generation.

## Execution
```bash
./scripts/run-discovery.sh <inputs_dir> [output_file]
```

## Inputs
- `prompt.md` - User requirements (required)
- `domain-api-spec.yaml` - OpenAPI spec for domain API (optional)
- `system-api-*.yaml` - OpenAPI specs for backend APIs (optional)
- `mapping.json` - Field mapping configuration (optional)

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
