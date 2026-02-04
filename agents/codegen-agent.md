# CodeGen Agent

**Version:** 1.0  
**Purpose:** Generate source code files from templates for a single execution step

---

## Overview

The CodeGen Agent processes one step from the execution plan at a time, generating source files by applying generation context to module templates. It only handles steps with `action="generate"` (Phase 1 and Phase 2).

**Key Principle:** Template fidelity is absolute. The agent MUST follow templates exactly without improvisation, enhancements, or creativity (DEC-025 compliance).

---

## Input Contract

### Required Inputs

1. **step_number** - Which step from execution plan to process (1, 2, 3...)
2. **execution-plan.json** - Output from Plan Agent
3. **generation-context.json** - Output from Context Agent
4. **output_dir** - Directory for generated files

### Step Requirements

- Step must have `action: "generate"`
- For `action: "transform"` steps, use Transform Agent

---

## Output Contract

### Files Generated

Source files written to `<output_dir>/src/main/java/<package_path>/`

### Result Manifest

`codegen-result-{step}.json`:

```json
{
  "version": "1.0",
  "timestamp": "2026-01-30T00:00:00Z",
  "agent": "codegen",
  "step": 1,
  "module_id": "mod-code-015-hexagonal-base-java-spring",
  "files": [
    {
      "template": "domain/Entity.java.tpl",
      "output_path": "com/bank/customer/domain/model/Customer.java",
      "content": "package com.bank.customer.domain.model;\n\nimport java.util.UUID;..."
    }
  ]
}
```

---

## Template Processing

### Placeholder Syntax

| Syntax | Meaning | Example |
|--------|---------|---------|
| `{{variable}}` | Simple replacement | `{{Entity}}` → `Customer` |
| `{{#array}}...{{/array}}` | Loop over array | `{{#entityFields}}...{{/entityFields}}` |
| `{{^last}}...{{/last}}` | If not last item | `{{^last}}, {{/last}}` |
| `{{.}}` | Current item in loop | `import {{.}};` |

### Variable Resolution

| Placeholder | Source in Context |
|-------------|-------------------|
| `{{Entity}}` | domain.entityName |
| `{{entity}}` | domain.entityNameLower |
| `{{entities}}` | domain.entityNamePlural |
| `{{basePackage}}` | service.basePackage |
| `{{basePackagePath}}` | basePackage with `.` → `/` |
| `{{entityFields}}` | domain.fields |
| `{{fieldName}}` | field.name |
| `{{fieldType}}` | field.type (mapped) |
| `{{fieldNamePascal}}` | field.name capitalized |

### Type Mapping

| Context Type | Java Type |
|--------------|-----------|
| String | String |
| String (format: uuid) | String |
| String (format: date) | LocalDate |
| String (format: date-time) | LocalDateTime |
| Integer | Integer |
| Long | Long |
| Boolean | Boolean |
| Number | BigDecimal |
| Custom (e.g., CustomerStatus) | As-is (enum) |

---

## Usage

```bash
./scripts/run-codegen.sh <step> <plan> <context> <output_dir>

# Example: Generate step 1 (hexagonal-base)
./scripts/run-codegen.sh 1 \
    execution-plan.json \
    generation-context.json \
    ./generated

# Example: Generate step 2 (api-public-exposure)
./scripts/run-codegen.sh 2 \
    execution-plan.json \
    generation-context.json \
    ./generated
```

---

## Execution Flow

```
Step 1: Extract step info from plan
        ↓
Step 2: Validate action="generate"
        ↓
Step 3: Load all .tpl files from module/templates
        ↓
Step 4: Build prompt with templates + context
        ↓
Step 5: Execute Claude
        ↓
Step 6: Parse JSON result
        ↓
Step 7: Write files to output_dir
        ↓
Step 8: Save codegen-result-{step}.json
```

---

## DEC-025 Compliance Rules

The agent enforces strict template fidelity:

| Rule | Description |
|------|-------------|
| No additions | Do not add methods, fields, annotations not in template |
| No removals | Do not skip sections or simplify |
| No improvements | Even "better" code must follow template |
| Exact structure | Comments, whitespace, order must match |
| All templates | Process every .tpl file in module |

---

## Determinism Rules

1. Process templates in ALPHABETICAL order by path
2. Maintain field order from context (domain.fields)
3. Use exact Java type mappings (no variations)
4. Include ALL templates (no skipping)

---

## Example: Step 1 (Hexagonal Base)

**Input:**
- Step 1 from execution plan
- generation-context.json with Customer entity

**Templates processed:**
```
Application.java.tpl
adapter/RestController.java.tpl
application/ApplicationService.java.tpl
application/dto/CreateRequest.java.tpl
application/dto/Response.java.tpl
application/dto/UpdateRequest.java.tpl
config/application.yml.tpl
config/pom.xml.tpl
domain/DomainService.java.tpl
domain/Entity.java.tpl
domain/EntityId.java.tpl
domain/Enum.java.tpl
domain/NotFoundException.java.tpl
domain/Repository.java.tpl
infrastructure/ApplicationConfig.java.tpl
infrastructure/CorrelationIdFilter.java.tpl
infrastructure/GlobalExceptionHandler.java.tpl
test/ControllerTest.java.tpl
test/DomainServiceTest.java.tpl
test/EntityIdTest.java.tpl
test/EntityTest.java.tpl
```

**Output:**
```
generated/
└── src/main/java/
    └── com/bank/customer/
        ├── CustomerApiApplication.java
        ├── adapter/
        │   └── in/
        │       └── CustomerController.java
        ├── application/
        │   ├── CustomerApplicationService.java
        │   └── dto/
        │       ├── CreateCustomerRequest.java
        │       ├── CustomerResponse.java
        │       └── UpdateCustomerRequest.java
        ├── domain/
        │   ├── model/
        │   │   ├── Customer.java
        │   │   ├── CustomerId.java
        │   │   └── CustomerStatus.java
        │   ├── CustomerDomainService.java
        │   ├── CustomerNotFoundException.java
        │   └── CustomerRepository.java
        └── infrastructure/
            ├── ApplicationConfig.java
            ├── CorrelationIdFilter.java
            └── GlobalExceptionHandler.java
```

---

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| Step not found | Invalid step number | Check execution-plan.json |
| Action not generate | Step is transform | Use run-transform.sh |
| Templates not found | KB_DIR incorrect | Set KB_DIR environment variable |
| Invalid JSON output | Claude formatting | Automatic cleanup applied |

---

## Integration with Pipeline

```bash
# Full pipeline example
./run-discovery.sh inputs/ discovery-result.json
./run-context.sh inputs/ discovery-result.json generation-context.json
./run-plan.sh discovery-result.json generation-context.json execution-plan.json

# Generate Phase 1 (structural)
./run-codegen.sh 1 execution-plan.json generation-context.json ./generated
./run-codegen.sh 2 execution-plan.json generation-context.json ./generated

# Generate Phase 2 (implementation)
./run-codegen.sh 3 execution-plan.json generation-context.json ./generated
./run-codegen.sh 4 execution-plan.json generation-context.json ./generated

# Phase 3 uses Transform Agent (not CodeGen)
./run-transform.sh 5 execution-plan.json generation-context.json ./generated
./run-transform.sh 6 execution-plan.json generation-context.json ./generated
./run-transform.sh 7 execution-plan.json generation-context.json ./generated
```

---

## Validation

After generation, verify:

1. All expected files exist
2. Package declarations match paths
3. Imports are valid
4. No placeholder syntax remaining (`{{...}}`)
5. Code compiles (optional: `mvn compile`)
