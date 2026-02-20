# Plan Agent

**Version:** 1.0  
**Purpose:** Generate deterministic execution plan from discovery and context results

---

## Overview

The Plan Agent takes the outputs from Discovery Agent and Context Agent and produces an ordered execution plan for the CodeGen Agent. The plan determines:

1. Which modules to execute
2. In what order (respecting phase dependencies)
3. With what action (generate vs transform)
4. What dependencies exist between steps

---

## Input Contract

### Required Inputs

1. **discovery-result.json** - Output from Discovery Agent
2. **generation-context.json** - Output from Context Agent

### Input Schema (Discovery)

```json
{
  "service_name": "string",
  "phases": {
    "1_structural": ["module_id", ...],
    "2_implementation": ["module_id", ...],
    "3_cross_cutting": ["module_id", ...]
  },
  "detected_capabilities": [
    {
      "capability_id": "string",
      "module_id": "string",
      "phase": 1|2|3
    }
  ]
}
```

---

## Output Contract

### Output File

`execution-plan.json`

### Output Schema

```json
{
  "version": "1.0",
  "timestamp": "ISO-8601",
  "agent": "plan",
  "service_name": "string",
  "total_steps": integer,
  "phases": [
    {
      "phase": 1,
      "name": "structural",
      "description": "Foundation and architecture setup",
      "steps": [
        {
          "step": 1,
          "module_id": "string",
          "capability_id": "string",
          "action": "generate",
          "templates_path": "modules/{module_id}/templates",
          "depends_on": []
        }
      ]
    },
    {
      "phase": 2,
      "name": "implementation",
      "steps": [...]
    },
    {
      "phase": 3,
      "name": "cross_cutting",
      "steps": [
        {
          "step": N,
          "module_id": "string",
          "capability_id": "string",
          "action": "transform",
          "transform_path": "modules/{module_id}/transform",
          "target_layer": "adapter/out",
          "depends_on": [...]
        }
      ]
    }
  ],
  "execution_order": ["module_id", ...],
  "validation_modules": ["module_id", ...]
}
```

---

## Determinism Rules

### Ordering Rules

| Rule | Description |
|------|-------------|
| Phase order | Always 1 → 2 → 3 |
| Within-phase | Alphabetical by module_id |
| Step numbering | Sequential, continuous across phases |
| depends_on | Sorted alphabetically |
| execution_order | Matches step sequence |
| validation_modules | Sorted alphabetically |

### Action Rules

| Phase | Action |
|-------|--------|
| Phase 1 (structural) | `generate` |
| Phase 2 (implementation) | `generate` |
| Phase 3 (cross-cutting) | `transform` |

### Dependency Rules

| Phase | depends_on |
|-------|------------|
| Phase 1 | `[]` (empty) |
| Phase 2 | All Phase 1 module_ids |
| Phase 3 | All Phase 1 + Phase 2 module_ids |

---

## Usage

```bash
./scripts/run-plan.sh <discovery_file> <context_file> [output_file]

# Example
./scripts/run-plan.sh \
    ./discovery-result.json \
    ./generation-context.json \
    ./execution-plan.json
```

---

## Example Output

For customer-api with 7 modules:

```json
{
  "version": "1.0",
  "timestamp": "2026-01-30T00:00:00Z",
  "agent": "plan",
  "service_name": "customer-api",
  "total_steps": 7,
  "phases": [
    {
      "phase": 1,
      "name": "structural",
      "description": "Foundation and architecture setup",
      "steps": [
        {
          "step": 1,
          "module_id": "mod-code-015-hexagonal-base-java-spring",
          "capability_id": "architecture.hexagonal-light",
          "action": "generate",
          "templates_path": "modules/mod-code-015-hexagonal-base-java-spring/templates",
          "depends_on": []
        },
        {
          "step": 2,
          "module_id": "mod-code-019-api-public-exposure-java-spring",
          "capability_id": "api-architecture.domain-api",
          "action": "generate",
          "templates_path": "modules/mod-code-019-api-public-exposure-java-spring/templates",
          "depends_on": []
        }
      ]
    },
    {
      "phase": 2,
      "name": "implementation",
      "description": "Persistence and integration adapters",
      "steps": [
        {
          "step": 3,
          "module_id": "mod-code-017-persistence-systemapi",
          "capability_id": "persistence.systemapi",
          "action": "generate",
          "templates_path": "modules/mod-code-017-persistence-systemapi/templates",
          "depends_on": [
            "mod-code-015-hexagonal-base-java-spring",
            "mod-code-019-api-public-exposure-java-spring"
          ]
        },
        {
          "step": 4,
          "module_id": "mod-code-018-api-integration-rest-java-spring",
          "capability_id": "integration.api-rest",
          "action": "generate",
          "templates_path": "modules/mod-code-018-api-integration-rest-java-spring/templates",
          "depends_on": [
            "mod-code-015-hexagonal-base-java-spring",
            "mod-code-019-api-public-exposure-java-spring"
          ]
        }
      ]
    },
    {
      "phase": 3,
      "name": "cross_cutting",
      "description": "Resilience patterns applied as decorators",
      "steps": [
        {
          "step": 5,
          "module_id": "mod-code-001-circuit-breaker-java-resilience4j",
          "capability_id": "resilience.circuit-breaker",
          "action": "transform",
          "transform_path": "modules/mod-code-001-circuit-breaker-java-resilience4j/transform",
          "target_layer": "adapter/out",
          "depends_on": [
            "mod-code-015-hexagonal-base-java-spring",
            "mod-code-017-persistence-systemapi",
            "mod-code-018-api-integration-rest-java-spring",
            "mod-code-019-api-public-exposure-java-spring"
          ]
        },
        {
          "step": 6,
          "module_id": "mod-code-002-retry-java-resilience4j",
          "capability_id": "resilience.retry",
          "action": "transform",
          "transform_path": "modules/mod-code-002-retry-java-resilience4j/transform",
          "target_layer": "adapter/out",
          "depends_on": [...]
        },
        {
          "step": 7,
          "module_id": "mod-code-003-timeout-java-resilience4j",
          "capability_id": "resilience.timeout",
          "action": "transform",
          "transform_path": "modules/mod-code-003-timeout-java-resilience4j/transform",
          "target_layer": "adapter/out",
          "depends_on": [...]
        }
      ]
    }
  ],
  "execution_order": [
    "mod-code-015-hexagonal-base-java-spring",
    "mod-code-019-api-public-exposure-java-spring",
    "mod-code-017-persistence-systemapi",
    "mod-code-018-api-integration-rest-java-spring",
    "mod-code-001-circuit-breaker-java-resilience4j",
    "mod-code-002-retry-java-resilience4j",
    "mod-code-003-timeout-java-resilience4j"
  ],
  "validation_modules": [
    "mod-code-001-circuit-breaker-java-resilience4j",
    "mod-code-002-retry-java-resilience4j",
    "mod-code-003-timeout-java-resilience4j",
    "mod-code-015-hexagonal-base-java-spring",
    "mod-code-017-persistence-systemapi",
    "mod-code-018-api-integration-rest-java-spring",
    "mod-code-019-api-public-exposure-java-spring"
  ]
}
```

---

## Validation Checklist

- [ ] All modules from discovery are included
- [ ] Phase ordering is 1 → 2 → 3
- [ ] Within-phase modules are alphabetically sorted
- [ ] Step numbers are sequential and continuous
- [ ] depends_on arrays are correct for each phase
- [ ] execution_order matches step sequence
- [ ] Phase 3 modules have action="transform"
