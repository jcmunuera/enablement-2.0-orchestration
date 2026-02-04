# Changelog - Enablement 2.0 Orchestration

All notable changes to the orchestration component.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added - 2026-02-04

- **DEC-042: Stack-Specific Style Files**
  - CodeGen loads style file from KB based on detected stack
  - Style content injected into prompt (replaces hardcoded rules)
  - Improves code style consistency across generation runs

- **DEC-041: Module Variant Resolution**
  - Discovery Agent detects variant keywords from prompt
  - Context Agent resolves variants (user selection or module default)
  - Variant selections stored in `variant_selections` field
  - Config flags now include resolved variants for CodeGen filtering

- **ARCHITECTURE.md** - Comprehensive architecture document replacing placeholder DESIGN.md
  - Full agent pipeline documentation
  - Data flow diagrams
  - Key mechanisms (Config Flags, Phase Coherence, Template Manifest)
  - Trace artifacts reference
  - Decision cross-references

### Changed - 2026-02-04

- `run-discovery.sh` - Added variant_selections to output schema + variant keyword detection rules
- `run-context.sh` - Added DEC-041 variant resolution logic (MODULE_VARIANTS registry)

### Removed - 2026-02-04

- `DESIGN.md` - Replaced by ARCHITECTURE.md
- `PROJECT-CONTEXT.md` - Duplicated in KB, single source of truth there
- `DAILY-SUMMARY-2026-02-02.md` - Historical, moved to KB sessions/

---

## [1.2.0] - 2026-02-03

### Added

- **DEC-039: Reproducibility Rules** (Phase 2 improvements)
  - Trailing newline normalization: `content.rstrip() + '\n'`
  - Helper method style rules in prompt
  - ASCII-only comments (no Unicode arrows)

- **DEC-037: Enum Generation Rule**
  - CRITICAL instruction: "If ANY field uses an Enum type, you MUST generate the enum file"
  - Prevents compilation errors from missing enum definitions

- **Config Flags in CodeGen Prompt**
  - Flags from `generation-context.json` injected into prompt
  - Templates can use `{{#config.hateoas}}` conditionals

### Fixed

- **Manifest Checker Variable Resolution**
  - `{{ServiceName}}` now resolves from both `service.serviceName` and `service.name`
  - Added `{{entityName}}`, `{{entityNameLower}}`, `{{entityPlural}}` aliases
  - Skip templates with unresolved dynamic variables (`{{EnumName}}`, `{{ApiName}}`)

### Changed

- **Template Output Paths** (KB side, DEC-036)
  - All templates now use explicit paths (no `...` placeholders)
  - Enables deterministic manifest validation

---

## [1.1.0] - 2026-02-02

- **ODEC-017: Maven Dependencies via YAML**
  - Created `dependencies.yaml` in all 10 modules (KB side)
  - Context Agent reads and consolidates Maven dependencies from YAML
  - CodeGen prompt includes Maven dependency resolution instructions
  - Deprecated pom-*.xml.tpl fragments (excluded from template loading)

- **ODEC-018: Inter-Phase Coherence Model**
  - Step 1: Scope enforcement — derive allowed output paths from templates, inject into CodeGen prompt
  - Step 2a: Scope validation — post-generation filter rejects out-of-scope files
  - Step 2b: Phase catalog extractor — deterministic Python indexer for generated classes
  - Step 2c: Catalog injection — prior phase catalogs injected into next phase's prompt
  - Trace artifacts: `allowed-paths-{subphase}.json`, `phase-catalog-{subphase}.json`

### Fixed - 2026-02-02

- **Claude Code invocation**: `cat | claude -p --tools ""` prevents agentic mode / scratchpad
- **Heredoc expansion**: Unquoted delimiters with hex-escaped backticks for Python blocks
- **Catalog extractor**: Records no longer capture parentheses (`CustomerFilter(` → `CustomerFilter`)
- **Catalog scope**: Extractor only indexes files from current subphase, not entire output directory

### Changed
- **Plan Agent** - BREAKING: New subphase optimization rules (ODEC-015)
  - Default: ONE subphase per phase (not split by category)
  - Phase 2 modules grouped together for holistic generation
  - Split only when >4 modules per phase
  - Dependency-aware grouping prevents cross-reference errors
  
- **CodeGen Agent** - Holistic generation per subphase
  - All modules in subphase generated in single LLM call
  - Ensures cross-module consistency (imports, naming, references)

- **run-generate.sh** - Simplified to single responsibility
  - Generates code to specified output directory
  - Includes validation/ for immediate validation (manual mode)
  - Includes .trace/ for generation artifacts
  - Agnostic of final package structure

### Added
- **orchestrate.sh** - Full pipeline orchestration
  - Creates KB-compliant package structure
  - Runs: Discovery → Context → Plan → Generate
  - Assembles final package (input/, output/, trace/, validation/)
  - Naming convention: `gen_{service}_{YYYYMMDD_HHMMSS}`

- Dual execution modes:
  - **Manual mode**: Run agents individually, control your own output structure
  - **Orchestrated mode**: `orchestrate.sh` handles everything, KB-compliant output

### Technical Decisions
- ODEC-008: Per-module generation (all templates in one call)
- ODEC-009: Step-by-step execution (one step per script call)
- ODEC-010: Generation orchestrator manages phase iteration
- ODEC-011: Holistic subphase generation (all modules together)
- ODEC-012: Plan Agent subphase grouping by category
- ODEC-013: KB-compliant output structure (flow-generate-output.md)
- ODEC-014: Dual execution modes (manual vs orchestrated)
- ODEC-015: Subphase optimization (minimize splits, dependency-aware)
- ODEC-016: Module dependency metadata in KB (future)

### Planned
- Transform Agent - Phase 3 cross-cutting transformations
- Validation Agent - Conformance checking
- Package Agent - Final deliverable assembly

---

## [1.0.0] - 2026-01-30

### Added

#### Agents
- **Discovery Agent** (`run-discovery.sh`)
  - Analyzes OpenAPI specs and requirements
  - Detects capabilities from capability-index.yaml
  - Maps capabilities to modules
  - Groups modules into phases (structural, implementation, cross-cutting)
  - 100% deterministic output validated (5/5 runs)

- **Context Agent** (`run-context.sh`)
  - Extracts domain model from OpenAPI schemas
  - Parses System API endpoints and mappings
  - Generates field mappings (domain ↔ system)
  - Configures resilience parameters
  - 100% deterministic output validated (5/5 runs)

- **Plan Agent** (`run-plan.sh`)
  - Creates execution plan from discovery result
  - Establishes module dependencies
  - Determines action type (generate vs transform)
  - Orders steps for CodeGen execution
  - 100% deterministic output validated (5/5 runs)

#### Scripts
- `test-determinism.sh` - Validates agent output consistency across multiple runs

#### Documentation
- `agents/discovery-agent.md` - Agent specification and contract
- `agents/context-agent.md` - Agent specification and contract
- `agents/plan-agent.md` - Agent specification and contract
- `docs/DESIGN.md` - High-level architecture
- `docs/DECISION-LOG.md` - Technical decisions (ODEC-001 through ODEC-007)
- `docs/CHANGELOG.md` - This file

### Technical Decisions
- ODEC-001: Embedded prompts in scripts (not external files)
- ODEC-002: Python for markdown code block cleanup
- ODEC-003: Fixed timestamp for determinism validation
- ODEC-004: Explicit ordering rules for all arrays
- ODEC-005: Extraction rules for Context Agent
- ODEC-006: All modules included in validation_modules
- ODEC-007: Schema versioning (v1.0)

---

## [Unreleased]

### Planned
- CodeGen Agent - Template-based code generation
- Transform Agent - Phase 3 cross-cutting transformations
- Validation Agent - Conformance checking
- Package Agent - Final deliverable assembly
- Orchestrator script - Full pipeline automation

---

## Version History

| Version | Date | Agents | Determinism |
|---------|------|--------|-------------|
| 1.0.0 | 2026-01-30 | Discovery, Context, Plan | 100% (3/3) |

---

## Migration Notes

### From Chat-Based Generation

The orchestration component replaces the chat-based code generation approach used in PoCs 1-4.

**Why migrate:**
- Chat context compaction loses critical instructions
- No reproducibility across sessions
- Cannot validate intermediate outputs

**Key differences:**
| Aspect | Chat-Based | Orchestration |
|--------|------------|---------------|
| Context | Accumulates, compacts | Fresh per agent |
| Reproducibility | ~20% | 100% |
| Debugging | Difficult | Step-by-step |
| Validation | End-only | Per-agent |
