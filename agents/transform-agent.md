# Transform Agent

**Version:** 1.0  
**Purpose:** Apply cross-cutting transformations to existing generated code (Phase 3)

---

## Overview

The Transform Agent processes subphases with `action="transform"` from the execution plan. Unlike the CodeGen Agent (which generates new files from templates), the Transform Agent **modifies existing code** by applying cross-cutting concerns defined in transform descriptors.

**Key Principle:** Transform descriptors are the contract. The agent reads existing code, applies ONLY the transformations described in the descriptor, and writes the modified files back. It must NOT alter any code outside the scope of the transformation.

**Design Note (ODEC-022):** This agent currently delegates all transformation logic to the LLM. Individual actions (`add_imports`, `add_annotation_to_methods`, etc.) may be migrated to deterministic script-based execution in the future without changing the transform descriptor format.

---

## Input Contract

### Required Inputs

1. **subphase_id** - Which subphase from execution plan (e.g., "3.1")
2. **execution-plan.json** - Output from Plan Agent
3. **generation-context.json** - Output from Context Agent
4. **output_dir** - Directory with previously generated code (from Phase 1 & 2)

### Subphase Requirements

- Subphase must have `action: "transform"`
- All files targeted by transforms must already exist in output_dir
- For `action: "generate"` subphases, use CodeGen Agent

---

## Output Contract

### Modified Files

Modified source files are written back to their original locations in `output_dir/`.

### Result Manifest

`transform-result-{subphase_id}.json`:

```json
{
  "version": "1.0",
  "timestamp": "2026-02-05T00:00:00Z",
  "agent": "transform",
  "subphase_id": "3.1",
  "modules_processed": ["mod-code-001-...", "mod-code-002-..."],
  "execution_order": ["mod-code-001-...", "mod-code-002-...", "mod-code-003-..."],
  "files_modified": [
    {
      "path": "src/main/java/com/bank/customer/adapter/out/systemapi/CustomerSystemApiAdapter.java",
      "module_id": "mod-code-001-circuit-breaker-java-resilience4j",
      "transformations_applied": ["add_imports", "add_constant", "add_annotation_to_methods", "add_fallback_methods"]
    }
  ],
  "yaml_merged": [
    {
      "path": "src/main/resources/application.yml",
      "sections_added": ["resilience4j.circuitbreaker", "resilience4j.retry"]
    }
  ],
  "pom_dependencies_added": [
    {
      "groupId": "io.github.resilience4j",
      "artifactId": "resilience4j-spring-boot3"
    }
  ]
}
```

---

## Transform Descriptor Format

Each cross-cutting module defines a transform descriptor in `modules/{module-id}/transform/`:

```yaml
transformation:
  id: unique-transform-id
  type: annotation | modification | merge
  phase: 3
  description: "What this transformation does"
  
  depends_on:                    # Execution order (optional)
    - module-id-that-runs-first
  
  targets:                       # Which files to modify
    - pattern: "**/adapter/out/**/*Adapter.java"
      generated_by: [module-ids]
      exclude: ["**/persistence/**"]
  
  steps:                         # Transformations to apply
    - action: add_imports
    - action: add_constant
    - action: add_annotation_to_methods
    - action: add_fallback_methods
  
  yaml_merge:                    # Config to merge into application.yml
  pom_dependencies:              # Maven dependencies to add
  fingerprints:                  # Patterns for post-validation
```

---

## Execution Flow

```
Step 1: Extract subphase info from plan (validate action="transform")
        ↓
Step 2: Load transform descriptors for all modules in subphase
        ↓
Step 3: Resolve execution order via depends_on (topological sort)
        ↓
Step 4: Read target files from output_dir (code generated in Phase 1 & 2)
        ↓
Step 5: Load snippets from each module's transform/snippets/
        ↓
Step 6: Build prompt with:
        - Transform descriptors (as instructions)
        - Existing code (as input to modify)
        - Snippets (as reference material)
        - Context variables (for placeholder resolution)
        - Style rules (from stack-specific style file)
        ↓
Step 7: Execute LLM (single call for entire subphase, holistic)
        ↓
Step 8: Parse JSON result
        ↓
Step 9: Write modified files back to output_dir (overwrite originals)
        ↓
Step 10: Save transform-result-{subphase_id}.json
```

---

## Holistic Execution

All transforms in a subphase are applied in a **single LLM call** (same pattern as CodeGen's holistic subphase generation, per ODEC-011). This ensures:

- Consistent annotation ordering across all target files
- No conflicting modifications between modules
- Single pass: circuit-breaker + retry + timeout applied together

The LLM receives ALL transform descriptors ordered by dependency, and applies them in sequence to each target file.

---

## Execution Order Rules

Within a subphase, modules are ordered by their `depends_on` declarations:

| Module | depends_on | Order |
|--------|-----------|-------|
| mod-001 (circuit-breaker) | none | 1st |
| mod-002 (retry) | mod-001 | 2nd |
| mod-003 (timeout) | none | 3rd (alphabetical tiebreak) |

**Rule:** Topological sort by depends_on, alphabetical tiebreak for independent modules.

---

## Scope Rules

The Transform Agent MUST:

| Rule | Description |
|------|-------------|
| Only modify targets | Do NOT touch files outside the target patterns |
| Preserve existing code | Only ADD to files (imports, annotations, methods), never remove |
| Follow snippets exactly | Use snippet content as-is, only resolving {{variables}} |
| Respect depends_on order | Apply circuit-breaker before retry |
| Merge YAML additively | Deep merge, never overwrite existing config |
| Deduplicate dependencies | Only add POM deps if not already present |

---

## Usage

```bash
./scripts/run-transform.sh <subphase_id> <execution_plan> <generation_context> <output_dir>

# Example: Apply resilience transforms
./scripts/run-transform.sh 3.1 \
    execution-plan.json \
    generation-context.json \
    ./generated
```

---

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| Subphase not found | Invalid subphase_id | Check execution-plan.json |
| Action not transform | Subphase is generate | Use run-codegen.sh |
| No transform descriptor | Module missing transform/ | Check KB module structure |
| Target files not found | Phase 1/2 not executed | Run CodeGen first |
| Snippet not found | Missing snippets/ directory | Check KB module structure |

---

## Future: Hybrid Execution Model

The transform descriptor's `steps` use typed actions (`add_imports`, `add_annotation_to_methods`, etc.). This enables a future hybrid model:

```
For each step in descriptor:
  if step.action has deterministic implementation:
    → Execute via script (100% reproducible)
  else:
    → Delegate to LLM (flexible but variable)
```

The descriptor format is the stable contract; the execution engine is interchangeable per action type. This migration can happen incrementally, one action type at a time, without KB changes.

---

## Integration with Pipeline

```bash
# Full pipeline
./run-discovery.sh inputs/ discovery-result.json
./run-plan.sh discovery-result.json execution-plan.json
./run-context.sh inputs/ discovery-result.json execution-plan.json generation-context.json

# Phase 1 & 2 (generate)
./run-generate.sh execution-plan.json generation-context.json ./generated

# Phase 3 (transform) - called by run-generate.sh automatically
# Or manually:
./run-transform.sh 3.1 execution-plan.json generation-context.json ./generated
```
