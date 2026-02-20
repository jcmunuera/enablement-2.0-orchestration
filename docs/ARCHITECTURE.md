# Enablement 2.0 - Orchestration Architecture

**Version:** 2.0  
**Last Updated:** 2026-02-04  
**Status:** Production (E2E Validated)

---

## 1. Overview

### 1.1 Purpose

The orchestration system coordinates AI agents to generate enterprise Java microservices from high-level requirements. It solves the fundamental problems of chat-based code generation:

| Problem in Chat | Orchestration Solution |
|-----------------|------------------------|
| Context compaction destroys instructions | Each agent has fresh, minimal context |
| Textual instructions ignored | Behavior controlled programmatically |
| Variable code structure | Templates + post-generation validation |
| Compilation errors not correctable | Scope enforcement + phase coherence |
| Improvised scripts | Deterministic copy from KB |

### 1.2 Design Principles

1. **Minimal Context** - Each agent receives ONLY what it needs
2. **Single Responsibility** - One agent = one well-defined task
3. **Clear Interfaces** - Input/Output explicit in JSON/files
4. **Determinism** - Same input -> same output (verified)
5. **Traceability** - All intermediate artifacts saved to `.trace/`

---

## 2. Agent Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ORCHESTRATOR                                    │
│                    (orchestrate.sh / run-generate.sh)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                        │
│  │  DISCOVERY  │──>│   CONTEXT   │──>│    PLAN     │                        │
│  │    AGENT    │   │    AGENT    │   │    AGENT    │                        │
│  │             │   │             │   │             │                        │
│  │ Capabilities│   │  Variables  │   │  Execution  │                        │
│  │   Modules   │   │  Mappings   │   │    Order    │                        │
│  │   Phases    │   │   Flags     │   │  Subphases  │                        │
│  └─────────────┘   └─────────────┘   └─────────────┘                        │
│         │                 │                 │                                │
│         v                 v                 v                                │
│  discovery-result   generation-context   execution-plan                     │
│      .json              .json              .json                            │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    CODE GENERATION LOOP                               │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
│  │  │  For each subphase (1.1, 2.1, 3.1, ...):                        │ │   │
│  │  │                                                                  │ │   │
│  │  │  1. Load prior phase catalogs                                   │ │   │
│  │  │  2. Build template manifest (ODEC-020)                          │ │   │
│  │  │  3. Derive allowed output paths (ODEC-018)                      │ │   │
│  │  │  4. Call CodeGen Agent                                          │ │   │
│  │  │  5. Validate scope (reject out-of-scope files)                  │ │   │
│  │  │  6. Extract phase catalog for next phase                        │ │   │
│  │  │  7. Normalize files (trailing newlines)                         │ │   │
│  │  └─────────────────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌─────────────┐   ┌─────────────┐                                          │
│  │ VALIDATION  │──>│  PACKAGER   │──> gen_{service}_{timestamp}/           │
│  │  ASSEMBLER  │   │   (script)  │                                          │
│  │  (script)   │   │             │                                          │
│  └─────────────┘   └─────────────┘                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Agent Specifications

### 3.1 Discovery Agent

**Script:** `run-discovery.sh`  
**Responsibility:** Analyze inputs and determine required capabilities/modules.

| Aspect | Detail |
|--------|--------|
| **Input** | `prompt.md`, `*-spec.yaml`, `mapping.json` |
| **Output** | `discovery-result.json` |
| **KB Context** | `capability-index.yaml`, `discovery-guidance.md` |
| **Context Size** | ~70KB |
| **Determinism** | 100% (validated 5/5 runs) |

**Output Schema:**
```json
{
  "version": "1.0",
  "service_name": "customer-api",
  "stack": "java-springboot",
  "detected_capabilities": [
    {
      "capability_id": "architecture.hexagonal-light",
      "module_id": "mod-code-015-hexagonal-base-java-spring",
      "phase": 1,
      "detection_reason": "foundational"
    }
  ],
  "phases": {
    "1_structural": ["mod-code-015", "mod-code-019"],
    "2_implementation": ["mod-code-017"],
    "3_cross_cutting": ["mod-code-001", "mod-code-002", "mod-code-003"]
  },
  "config_flags": {
    "transactional": false,
    "idempotent": false
  }
}
```

---

### 3.2 Context Agent

**Script:** `run-context.sh`  
**Responsibility:** Extract all template variables from specs and aggregate config.

| Aspect | Detail |
|--------|--------|
| **Input** | `discovery-result.json`, specs, `mapping.json` |
| **Output** | `generation-context.json` |
| **KB Context** | `dependencies.yaml` from each module (ODEC-017) |
| **Context Size** | ~30KB |
| **Determinism** | 100% (validated 5/5 runs) |

**Key Features:**
- Extracts domain model from OpenAPI schemas
- Parses System API endpoints
- Generates field mappings (domain <-> system)
- **Collects config_flags from capability publishers** (DEC-035)
- **Consolidates Maven dependencies** from module YAML files (ODEC-017)

**Output includes:**
```json
{
  "service": { "name": "customer-api", "basePackage": "com.bank.customer" },
  "domain": { "entityName": "Customer", "fields": [...] },
  "systemApi": { "baseUrl": "...", "endpoints": [...] },
  "mapping": { "domainToSystem": [...], "systemToDomain": [...] },
  "resilience": { "circuitBreaker": {...}, "retry": {...}, "timeout": {...} },
  "config_flags": { "hateoas": true, "pagination": true },
  "maven_dependencies": { "dependencies": [...], "properties": {...} }
}
```

---

### 3.3 Plan Agent

**Script:** `run-plan.sh`  
**Responsibility:** Generate execution plan with subphases.

| Aspect | Detail |
|--------|--------|
| **Input** | `discovery-result.json` |
| **Output** | `execution-plan.json` |
| **KB Context** | Module metadata only |
| **Context Size** | ~10KB |
| **Determinism** | 100% (validated 5/5 runs) |

**Subphase Optimization (ODEC-015):**
- Default: ONE subphase per phase
- Split only when >4 modules per phase
- Dependency-aware grouping

---

### 3.4 CodeGen Agent

**Script:** `run-codegen.sh`  
**Responsibility:** Generate code for ONE subphase.

| Aspect | Detail |
|--------|--------|
| **Input** | `generation-context.json`, `execution-plan.json`, prior catalogs |
| **Output** | Generated source files |
| **KB Context** | MODULE.md + templates for modules in THIS subphase only |
| **Context Size** | ~40-80KB per subphase |

**Key Features (ODEC-018, ODEC-020, DEC-035 to DEC-039):**

1. **Scope Enforcement** - Derives allowed output paths from templates
2. **Template Manifest** - Explicit list of files that MUST be generated
3. **Phase Catalog Injection** - Prior phase classes injected for coherence
4. **Config Flags** - Template conditionals based on active features
5. **Enum Generation Rule** - Mandatory enum file for enum types
6. **Reproducibility Rules** - Trailing newlines, helper methods, ASCII comments

**Execution per subphase:**
```
1. Load MODULE.md + templates for subphase modules
2. Build template manifest with expected outputs
3. Inject prior phase catalogs (classes, interfaces, records)
4. Inject config_flags for conditional generation
5. Call Claude API with full prompt
6. Parse JSON response, extract files
7. Validate scope (reject out-of-scope)
8. Normalize trailing newlines
9. Save to output directory
10. Extract phase catalog for next subphase
```

---

### 3.5 Validation Assembler

**Script:** `assemble-validation.sh` (in KB)  
**Responsibility:** Copy validation scripts to generated project.

| Aspect | Detail |
|--------|--------|
| **Input** | Discovery result (modules list) |
| **Output** | `validation/` directory with scripts |
| **Is LLM?** | No (deterministic script) |

**Validation Tiers:**
- Tier 0: Conformance (template structure)
- Tier 1: Universal (traceability, project structure)
- Tier 2: Domain (code-specific)
- Tier 3: Module (per-module checks)

---

## 4. Data Flow

```
┌─────────────┐
│   INPUTS    │
│ prompt.md   │
│ specs.yaml  │
│ mapping.json│
└──────┬──────┘
       │
       v
┌──────────────┐    ┌─────────────────────────┐
│  Discovery   │───>│  discovery-result.json  │
│    Agent     │    │  - capabilities         │
└──────────────┘    │  - modules by phase     │
                    │  - config_flags (basic) │
                    └───────────┬─────────────┘
                                │
       ┌────────────────────────┴────────────────────────┐
       │                                                  │
       v                                                  v
┌──────────────┐    ┌─────────────────────────┐   ┌──────────────┐
│   Context    │───>│ generation-context.json │   │    Plan      │
│    Agent     │    │  - service metadata     │   │    Agent     │
└──────────────┘    │  - domain model         │   └──────┬───────┘
                    │  - mappings             │          │
                    │  - config_flags (full)  │          v
                    │  - maven_dependencies   │   ┌─────────────────────┐
                    └───────────┬─────────────┘   │ execution-plan.json │
                                │                  │  - subphases        │
                                │                  │  - dependencies     │
                                └────────┬─────────┴──────┬──────────────┘
                                         │                │
                                         v                v
                              ┌────────────────────────────────────┐
                              │           CodeGen Agent            │
                              │      (per subphase: 1.1, 2.1...)   │
                              └────────────────┬───────────────────┘
                                               │
                     ┌─────────────────────────┴─────────────────────────┐
                     │                                                    │
                     v                                                    v
              ┌─────────────┐                                    ┌──────────────┐
              │  .trace/    │                                    │    src/      │
              │  manifest   │                                    │   main/java  │
              │  catalog    │                                    │   test/java  │
              │  allowed    │                                    │   resources  │
              └─────────────┘                                    └──────────────┘
```

---

## 5. Key Mechanisms

### 5.1 Config Flags Pub/Sub (DEC-035)

Enables cross-module influence without tight coupling:

```yaml
# Publisher (capability-index.yaml)
api-architecture:
  features:
    domain-api:
      module: mod-code-019-api-public-exposure-java-spring
      publishes_flags:
        hateoas: true
        pagination: true

# Subscriber (MODULE.md in mod-015)
subscribes_to_flags:
  - flag: hateoas
    affects: [Response.java.tpl]
    behavior: "true -> class extends RepresentationModel"
```

**Flow:**
1. Discovery detects capabilities with `publishes_flags`
2. Context Agent aggregates flags into `config_flags`
3. CodeGen injects flags into prompt
4. Templates use `{{#config.hateoas}}` conditionals

---

### 5.2 Inter-Phase Coherence (ODEC-018)

Solves the problem of phases not knowing about each other:

**Phase Catalog Example:**
```json
{
  "subphase": "1.1",
  "classes": [
    {
      "fqcn": "com.bank.customer.domain.model.Customer",
      "simple_name": "Customer",
      "kind": "class",
      "construction": "Entity.reconstitute(...) - PRIVATE constructor, NO setters"
    },
    {
      "fqcn": "com.bank.customer.domain.model.CustomerId",
      "simple_name": "CustomerId",
      "kind": "record"
    }
  ]
}
```

**Injected into Phase 2 prompt:**
```
<prior_phases_catalog>
IMPORTANT: Domain entities have PRIVATE constructors, NO setters.
Use Entity.reconstitute(...) for instances from persistence.

Phase 1.1 classes:
- Customer (class) [PRIVATE constructor]
- CustomerId (record)
- CustomerRepository (interface) [uses CustomerId, not String]
</prior_phases_catalog>
```

---

### 5.3 Template Manifest (ODEC-020)

Ensures 100% template coverage:

```markdown
## MANDATORY TEMPLATE MANIFEST

You MUST generate ALL of the following files:

| Module | Template | Expected Output |
|--------|----------|-----------------|
| mod-015 | Entity.java.tpl | com/bank/customer/domain/model/Customer.java |
| mod-015 | EntityId.java.tpl | com/bank/customer/domain/model/CustomerId.java |
| mod-019 | ControllerTest-hateoas.java.tpl | .../CustomerControllerHateoasTest.java |

**Total: 27 files MUST be generated.**
```

---

### 5.4 Reproducibility Rules (DEC-039)

Ensures consistent output across runs:

1. **Trailing Newlines** - Post-process: `content.rstrip() + '\n'`
2. **Helper Methods** - Prompt rule: "ALWAYS use toUpperCase(), toLowerCase() helpers"
3. **ASCII Comments** - Templates + prompt: No Unicode arrows

---

## 6. Trace Artifacts

Every generation produces trace artifacts in `.trace/`:

| Artifact | Purpose |
|----------|---------|
| `discovery-result.json` | Detected capabilities and modules |
| `generation-context.json` | All template variables |
| `execution-plan.json` | Subphase order and dependencies |
| `template-manifest-{subphase}.json` | Expected files for subphase |
| `allowed-paths-{subphase}.json` | Scope validation paths |
| `phase-catalog-{subphase}.json` | Classes for next phase injection |
| `codegen-prompt-{subphase}.txt` | Full prompt sent to LLM |
| `codegen-response-{subphase}.json` | Raw LLM response |

---

## 7. Execution Modes

### 7.1 Manual Mode (Step-by-Step)

```bash
# Run each agent individually
./run-discovery.sh inputs/ discovery-result.json
./run-context.sh inputs/ discovery-result.json generation-context.json
./run-plan.sh discovery-result.json execution-plan.json
./run-codegen.sh 1.1 execution-plan.json generation-context.json output/
./run-codegen.sh 2.1 execution-plan.json generation-context.json output/
```

### 7.2 Orchestrated Mode (Full Pipeline)

```bash
# Run complete pipeline
./orchestrate.sh inputs/ output/
# or
./run-generate.sh inputs/ output/
```

---

## 8. Validation Results

As of 2026-02-03 (3 independent E2E runs):

| Metric | Result |
|--------|--------|
| File structure | 100% reproducible (34/34 files) |
| Phase 1 content | 100% identical |
| Phase 2/3 content | Functional with minor cosmetic variations |
| Compilation | ✅ All pass |
| Tests | ✅ All pass |
| Tier validation | ✅ All pass |

---

## 9. Future Enhancements

### Planned
- **Fixer Agent** - Compile-fix-retry loop for error correction
- **Compilation Gate** - mvn compile after each phase
- **Static Template Lint** - Pre-generation template validation (ODEC-019)

### Not Planned
- LangGraph migration (current bash scripts sufficient)
- Separate Test Agent (tests generated with code)

---

## Appendix A: Decision References

| ID | Decision | Document |
|----|----------|----------|
| ODEC-001 | Embedded prompts in scripts | DECISION-LOG.md |
| ODEC-015 | Subphase optimization | DECISION-LOG.md |
| ODEC-017 | Maven dependencies via YAML | DECISION-LOG.md |
| ODEC-018 | Inter-phase coherence | DECISION-LOG.md |
| ODEC-020 | Template manifest | DECISION-LOG.md |
| DEC-035 | Config Flags Pub/Sub | KB DECISION-LOG.md |
| DEC-036 | Explicit template paths | KB DECISION-LOG.md |
| DEC-037 | Enum generation rule | KB DECISION-LOG.md |
| DEC-039 | Reproducibility rules | KB DECISION-LOG.md |

---

## Appendix B: File Reference

```
enablement-2.0-orchestration/
├── scripts/
│   ├── run-discovery.sh      # Discovery Agent
│   ├── run-context.sh        # Context Agent  
│   ├── run-plan.sh           # Plan Agent
│   ├── run-codegen.sh        # CodeGen Agent
│   ├── run-generate.sh       # Full generation (all phases)
│   ├── orchestrate.sh        # Complete pipeline with packaging
│   └── test-determinism.sh   # Reproducibility validation
├── agents/
│   ├── discovery-agent.md    # Agent specification
│   ├── context-agent.md      # Agent specification
│   ├── plan-agent.md         # Agent specification
│   └── codegen-agent.md      # Agent specification
└── docs/
    ├── ARCHITECTURE.md       # This document
    ├── DECISION-LOG.md       # ODEC decisions
    └── CHANGELOG.md          # Version history
```
