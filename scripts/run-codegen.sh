#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# CODEGEN AGENT - Enablement 2.0
# ═══════════════════════════════════════════════════════════════════════════
# Generates code files from templates for a SUBPHASE (holistic generation)
#
# Usage:
#   ./run-codegen.sh <subphase_id> <execution_plan> <generation_context> <output_dir>
#
# Inputs:
#   - subphase_id: Which subphase from execution-plan (e.g., "1.1", "2.1")
#   - execution_plan: JSON from Plan Agent (execution-plan.json)
#   - generation_context: JSON from Context Agent (generation-context.json)
#   - output_dir: Directory to write generated files
#
# Output:
#   - Generated source files in output_dir
#   - codegen-result-{subphase_id}.json: Manifest of generated files
#
# HOLISTIC GENERATION:
#   All modules in the subphase are generated TOGETHER in a single LLM call.
#   This ensures consistency (imports, naming, references) across related modules.
#
# Note: Only processes subphases with action="generate" (Phase 1 & 2)
#       For action="transform" (Phase 3), use run-transform.sh
# ═══════════════════════════════════════════════════════════════════════════
set -e

SUBPHASE_ID="${1:-}"
PLAN_FILE="${2:-}"
CONTEXT_FILE="${3:-}"
OUTPUT_DIR="${4:-./generated}"

# Resolve KB_DIR relative to script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="${KB_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/enablement-2.0-kb}"

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${SUBPHASE_ID}" ] || [ -z "${PLAN_FILE}" ] || [ -z "${CONTEXT_FILE}" ]; then
    echo "Usage: $0 <subphase_id> <execution_plan> <generation_context> <output_dir>"
    echo ""
    echo "Example:"
    echo "  $0 1.1 execution-plan.json generation-context.json ./generated"
    exit 1
fi

if [ ! -f "${PLAN_FILE}" ]; then
    echo "ERROR: Execution plan not found: ${PLAN_FILE}"
    exit 1
fi

if [ ! -f "${CONTEXT_FILE}" ]; then
    echo "ERROR: Generation context not found: ${CONTEXT_FILE}"
    exit 1
fi

# Extract subphase info from plan
SUBPHASE_INFO=$(python3 << EXTRACT_SUBPHASE
import json
import sys

with open('${PLAN_FILE}') as f:
    plan = json.load(f)

subphase_id = '${SUBPHASE_ID}'
for phase in plan['phases']:
    for subphase in phase.get('subphases', []):
        if subphase['id'] == subphase_id:
            print(json.dumps(subphase))
            sys.exit(0)

print('null')
sys.exit(1)
EXTRACT_SUBPHASE
)

if [ "${SUBPHASE_INFO}" = "null" ]; then
    echo "ERROR: Subphase ${SUBPHASE_ID} not found in execution plan"
    exit 1
fi

# Parse subphase details
ACTION=$(echo "${SUBPHASE_INFO}" | python3 -c "import json,sys; print(json.load(sys.stdin)['action'])")
SUBPHASE_NAME=$(echo "${SUBPHASE_INFO}" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
MODULE_COUNT=$(echo "${SUBPHASE_INFO}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['modules']))")

if [ "${ACTION}" != "generate" ]; then
    echo "ERROR: Subphase ${SUBPHASE_ID} has action='${ACTION}', not 'generate'"
    echo "       Use run-transform.sh for transform subphases"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  CODEGEN AGENT - Subphase ${SUBPHASE_ID} (${SUBPHASE_NAME})"
echo "═══════════════════════════════════════════════════════════════"
echo "Modules:    ${MODULE_COUNT}"
echo "Action:     ${ACTION}"
echo "Output:     ${OUTPUT_DIR}"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# DEC-042: Load stack-specific style file
# ─────────────────────────────────────────────────────────────────────────────
# Style files contain code conventions that the LLM must follow.
# They are loaded based on the detected stack (from discovery/context).
# Normalize stack names: java-springboot -> java-spring
STACK_RAW=$(python3 -c "import json; print(json.load(open('${CONTEXT_FILE}')).get('stack', 'java-spring'))" 2>/dev/null || echo "java-spring")
# Normalize: java-springboot -> java-spring
STACK=$(echo "${STACK_RAW}" | sed 's/springboot/spring/g')
STYLE_FILE="${KB_DIR}/runtime/codegen/styles/${STACK}.style.md"

if [ -f "${STYLE_FILE}" ]; then
    STYLE_CONTENT=$(cat "${STYLE_FILE}")
    echo "Style file: ${STACK}.style.md loaded"
else
    STYLE_CONTENT=""
    echo "Style file: Not found for stack '${STACK}' (using defaults)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build prompt with EMBEDDED system prompt
# ─────────────────────────────────────────────────────────────────────────────
TEMP_PROMPT=$(mktemp)
RESULT_FILE="${OUTPUT_DIR}/codegen-result-${SUBPHASE_ID}.json"
trap "rm -f ${TEMP_PROMPT}" EXIT

cat >> "${TEMP_PROMPT}" << 'SYSTEM_PROMPT'
You are the CodeGen Agent for Enablement 2.0.

## Task

Generate Java source files by applying generation context to module templates. You are generating code for MULTIPLE MODULES in a single subphase - this is HOLISTIC generation.

**HOLISTIC means:** All modules in this subphase are generated TOGETHER. You can see all templates and must ensure consistency across files (imports, naming, type references).

## Critical Rules (DEC-025 Compliance)

1. **Template fidelity is ABSOLUTE** - Copy template structure exactly
2. **Only replace placeholders** - Everything else stays verbatim
3. **No additions** - Do not add methods, fields, annotations, or comments not in template
4. **No removals** - Do not skip sections or simplify
5. **No "improvements"** - Even if you think something is better, follow the template
6. **Cross-module consistency** - Ensure imports and references match between files

## Placeholder Syntax

Templates use Mustache-like placeholders:

| Syntax | Meaning | Example |
|--------|---------|---------|
| `{{variable}}` | Simple replacement | `{{Entity}}` → `Customer` |
| `{{#array}}...{{/array}}` | Loop over array | `{{#entityFields}}...{{/entityFields}}` |
| `{{^last}}...{{/last}}` | If not last item | `{{^last}}, {{/last}}` |
| `{{.}}` | Current item in loop | In imports: `import {{.}};` |

## Variable Resolution

Use values from generation-context.json:

| Placeholder | Source in Context |
|-------------|-------------------|
| `{{Entity}}` | domain.entityName |
| `{{entity}}` | domain.entityNameLower |
| `{{entities}}` | domain.entityNamePlural |
| `{{basePackage}}` | service.basePackage |
| `{{basePackagePath}}` | service.basePackage with dots replaced by slashes |
| `{{serviceName}}` | service.serviceName |
| `{{serviceNamePascal}}` | service.serviceNamePascal |
| `{{springBootVersion}}` | service.springBootVersion |
| `{{javaVersion}}` | service.javaVersion |
| `{{entityFields}}` | domain.fields (iterate) |
| `{{fieldName}}` | field.name |
| `{{fieldType}}` | field.type (map to Java types) |
| `{{fieldNamePascal}}` | field.name with first letter uppercase |

## Config Flags (DEC-035)

The generation context may include a `config_flags` section with flags published by active features.
These flags affect how certain templates should be generated.

**Template syntax:**
- `{{#config.flagName}}...{{/config.flagName}}` - Render if flag is true
- `{{^config.flagName}}...{{/config.flagName}}` - Render if flag is false or not present

**Example flags:**
| Flag | Source | Effect |
|------|--------|--------|
| `hateoas` | mod-019 (domain-api) | Response.java: use class with RepresentationModel instead of record |
| `pagination` | mod-019 (domain-api) | Controller: include pagination parameters |

**IMPORTANT:** Check template headers for "⚠️ VARIANT SELECTION" notes. When a feature module 
(e.g., mod-019 HATEOAS) is active and publishes flags, use ITS template version instead of 
the base module's version for the affected files.

## Maven Dependencies (pom.xml generation)

The generation context includes a `maven_dependencies` section with consolidated
dependencies from ALL discovered modules (deduplicated by Context Agent).

When processing `pom.xml.tpl` from mod-015:
1. Use `maven_dependencies.properties` to generate `<properties>` entries
2. Use `maven_dependencies.dependencies` to generate `<dependency>` entries
   - Only include `<version>` tag if the dependency has an explicit version field
   - Only include `<scope>` tag if scope is NOT "compile" (compile is Maven default)
3. Use `maven_dependencies.dependency_management` (if present) for `<dependencyManagement>`
4. The output_path for pom.xml must be exactly "pom.xml" (project root)

Example maven_dependencies in context:
```json
{
  "maven_dependencies": {
    "dependencies": [
      {"groupId": "org.springframework.boot", "artifactId": "spring-boot-starter-web"},
      {"groupId": "io.github.resilience4j", "artifactId": "resilience4j-spring-boot3", "version": "${resilience4j.version}"},
      {"groupId": "org.projectlombok", "artifactId": "lombok", "scope": "provided"}
    ],
    "properties": {
      "resilience4j.version": "2.2.0",
      "mapstruct.version": "1.5.5.Final"
    }
  }
}
```

## Type Mapping

| OpenAPI/Context Type | Java Type |
|---------------------|-----------|
| String | String |
| String (format: uuid) | String |
| String (format: date) | LocalDate |
| String (format: date-time) | LocalDateTime |
| Integer | Integer |
| Long | Long |
| Boolean | Boolean |
| Number | BigDecimal |
| Custom (e.g., CustomerStatus) | Use as-is (enum) |

## Output Format

Output a SINGLE JSON object with ALL files from ALL modules in this subphase:

```json
{
  "version": "1.0",
  "timestamp": "2026-01-30T00:00:00Z",
  "agent": "codegen",
  "subphase_id": "<subphase_id>",
  "subphase_name": "<subphase_name>",
  "modules_processed": ["<module_id>", ...],
  "files": [
    {
      "module_id": "<which module this file belongs to>",
      "template": "<template_relative_path>",
      "output_path": "<resolved_output_path>",
      "content": "<full_generated_content>"
    }
  ],
  "total_files": <count>
}
```

## Output Path Resolution

Each template has an output path comment:
```
// Output: {{basePackagePath}}/domain/model/{{Entity}}.java
```

Resolve placeholders to get actual path:
```
com/bank/customer/domain/model/Customer.java
```

## CRITICAL: Output Path Rules

**ABSOLUTE RULES for file placement:**

| File Type | Output Path | Example |
|-----------|-------------|---------|
| Java source (.java) | `src/main/java/{package_path}/` | `src/main/java/com/bank/customer/domain/model/Customer.java` |
| Java test (*Test.java) | `src/test/java/{package_path}/` | `src/test/java/com/bank/customer/adapter/out/systemapi/CustomerSystemApiAdapterTest.java` |
| Resources (.yml, .yaml, .properties, .xml) | `src/main/resources/` | `src/main/resources/application.yml` |
| Test resources | `src/test/resources/` | `src/test/resources/application-test.yml` |
| pom.xml | Root directory | `pom.xml` |

**NEVER place:**
- .yml files inside src/main/java/
- *Test.java files inside src/main/java/
- Java files directly in src/ (always need full package path)

## CRITICAL: Entity Field Rules

**The entity's ID field is SPECIAL:**
- Use `CustomerId` type (Value Object) from the template
- Do NOT duplicate with a `String id` field
- The fields from context are BUSINESS fields, not the ID

**Example - CORRECT:**
```java
public class Customer {
    private CustomerId id;        // From template - Value Object
    private String firstName;     // From context fields
    private String lastName;      // From context fields
}
```

**Example - WRONG (duplicates):**
```java
public class Customer {
    private CustomerId id;        // ❌ Duplicated
    private String id;            // ❌ Duplicated
    private String firstName;
}
```

**Rule:** When iterating `{{#entityFields}}`, SKIP any field named "id" - it's already handled by the template's CustomerId.

## CRITICAL: Enum Generation

**If ANY field uses an Enum type (e.g., CustomerStatus, OrderType), you MUST generate the enum file.**

Use the `Enum.java.tpl` template from mod-015 to generate each enum:
- Output path: `{{basePackagePath}}/domain/model/{{EnumName}}.java`
- Example: If `Customer` has a field `status` of type `CustomerStatus`, generate `CustomerStatus.java`

**Enum values:** Extract from OpenAPI spec or context. Common patterns:
- `status` field → `ACTIVE, INACTIVE, SUSPENDED, PENDING`
- If values not specified, use sensible defaults based on field name

**Example - CORRECT:**
```java
// CustomerStatus.java MUST be generated if used
public enum CustomerStatus {
    ACTIVE,
    INACTIVE,
    SUSPENDED,
    PENDING
}
```

**Rule:** Never reference an enum type without generating its definition file.

## CRITICAL: Code Style Rules (DEC-042)

**The following style rules are loaded from the stack-specific style file and MUST be followed:**

{{STYLE_RULES}}

## CRITICAL: No Literal Placeholders in Output

**NEVER output literal placeholder syntax in generated code:**
- ❌ `com/bank/customer/.../` (literal "...")
- ❌ `{{Entity}}` in output
- ❌ `{{basePackage}}` in output

ALL placeholders must be resolved to actual values.

## EXACT Process

1. Read ALL .tpl files from ALL modules in this subphase
2. For each template, find the `// Output:` comment to determine target path
3. Replace ALL placeholders with context values
4. Include the complete file content (no truncation)
5. Output as JSON with ALL files together

## Determinism Rules

1. Process modules in order provided (already sorted alphabetically)
2. Within each module, process templates in ALPHABETICAL order by path
3. For field loops, maintain order from context (domain.fields order)
4. Use exact Java type mappings (no variations)
5. Include ALL templates from ALL modules (no skipping)

## Cross-Module Consistency

When generating multiple modules together:
- Entity class from module A must match imports in module B
- Package names must be consistent
- Type references must resolve correctly
- No duplicate classes

---

Generate code for this subphase:

SYSTEM_PROMPT

# ─────────────────────────────────────────────────────────────────────────────
# DEC-042: Inject style rules into prompt
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${STYLE_CONTENT}" ]; then
    # Replace {{STYLE_RULES}} marker with actual style content
    sed -i "s|{{STYLE_RULES}}|${STYLE_CONTENT//$'\n'/\\n}|g" "${TEMP_PROMPT}" 2>/dev/null || \
    python3 << INJECT_STYLE
import re
with open('${TEMP_PROMPT}', 'r') as f:
    content = f.read()

style_content = '''${STYLE_CONTENT}'''
content = content.replace('{{STYLE_RULES}}', style_content)

with open('${TEMP_PROMPT}', 'w') as f:
    f.write(content)
INJECT_STYLE
else
    # Remove marker if no style file
    sed -i 's|{{STYLE_RULES}}|(No stack-specific style file found - using template defaults)|g' "${TEMP_PROMPT}"
fi

# Add subphase info
echo "" >> "${TEMP_PROMPT}"
echo "<subphase_info>" >> "${TEMP_PROMPT}"
echo "${SUBPHASE_INFO}" >> "${TEMP_PROMPT}"
echo "</subphase_info>" >> "${TEMP_PROMPT}"

# Add generation context
echo "" >> "${TEMP_PROMPT}"
echo "<generation_context>" >> "${TEMP_PROMPT}"
cat "${CONTEXT_FILE}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</generation_context>" >> "${TEMP_PROMPT}"

# ─── ODEC-018 Step 2c: Inject prior phase catalogs ──────────────────────────
python3 << INJECT_CATALOG
import json
import os
import glob

output_dir = '${OUTPUT_DIR}'
prompt_file = '${TEMP_PROMPT}'
current_subphase = '${SUBPHASE_ID}'

# Find all phase catalogs from previous subphases
catalog_files = sorted(glob.glob(os.path.join(output_dir, '.trace', 'phase-catalog-*.json')))

# Filter: only catalogs from subphases BEFORE current
prior_catalogs = []
for cf in catalog_files:
    with open(cf) as f:
        cat = json.load(f)
    cat_subphase = cat.get('subphase', '')
    # Compare subphase IDs: "1.1" < "2.1" etc.
    if cat_subphase < current_subphase:
        prior_catalogs.append(cat)

if prior_catalogs:
    with open(prompt_file, 'a') as pf:
        pf.write("\n<prior_phases_catalog>\n")
        pf.write("The following classes were generated in PREVIOUS phases.\n")
        pf.write("When referencing these classes, use EXACTLY these names and packages.\n")
        pf.write("Do NOT create duplicates or alternatives for these classes.\n")
        pf.write("Import them using their exact FQCN.\n\n")
        pf.write("IMPORTANT CONSTRUCTION RULES:\n")
        pf.write("- Domain entity classes have PRIVATE constructors and NO setters.\n")
        pf.write("  Use Entity.reconstitute(...) to create instances from external data.\n")
        pf.write("  Do NOT use new Entity() or Entity.builder() or any setXxx() methods.\n")
        pf.write("- Repository interfaces use EntityId (value object), NOT String, for ID parameters.\n")
        pf.write("  e.g., findById(CustomerId id), NOT findById(String id).\n\n")
        
        for cat in prior_catalogs:
            pf.write(f"Phase {cat.get('subphase', '?')}:\n")
            for cls in cat.get('classes', []):
                line = f"  - {cls['fqcn']} ({cls['kind']})"
                # Add construction note for domain entities
                if '.domain.model.' in cls['fqcn'] and cls['kind'] == 'class':
                    line += " [PRIVATE constructor - use reconstitute() factory method, NO setters]"
                elif '.domain.repository.' in cls['fqcn'] and cls['kind'] == 'interface':
                    line += " [uses EntityId parameters, NOT String]"
                pf.write(line + "\n")
            pf.write("\n")
        
        pf.write("</prior_phases_catalog>\n")
    
    total_classes = sum(len(c.get('classes', [])) for c in prior_catalogs)
    print(f"  Catalog: injected {total_classes} classes from {len(prior_catalogs)} prior phase(s)")
INJECT_CATALOG

# Add templates from ALL modules in subphase
# Also derive ALLOWED_PATHS for scope enforcement (ODEC-018 Step 1)
echo "" >> "${TEMP_PROMPT}"

# ─── ODEC-018: Derive scope + add templates ─────────────────────────────────
ALLOWED_PATHS_FILE="${OUTPUT_DIR}/.trace/allowed-paths-${SUBPHASE_ID}.json"

python3 << ADD_TEMPLATES
import json
import os
import glob
import re

subphase = json.loads('''${SUBPHASE_INFO}''')
kb_dir = '${KB_DIR}'
prompt_file = '${TEMP_PROMPT}'
context_file = '${CONTEXT_FILE}'
allowed_paths_file = '${ALLOWED_PATHS_FILE}'

# Load context for basePackage resolution
with open(context_file) as f:
    ctx = json.load(f)

base_pkg = ctx.get('service', {}).get('basePackage', '')
base_pkg_path = base_pkg.replace('.', '/')

# DEC-040: Get http_client variant for template filtering
config_flags = ctx.get('config_flags', {})
http_client_variant = config_flags.get('http_client', 'restclient')  # Default: restclient

# Collect allowed directory patterns from template Output headers
allowed_dirs = set()
all_templates_content = []

with open(prompt_file, 'a') as pf:
    pf.write("\n<templates>\n")
    
    for module in subphase['modules']:
        module_id = module['module_id']
        templates_path = module.get('templates_path', f"modules/{module_id}/templates")
        templates_dir = os.path.join(kb_dir, templates_path)
        
        pf.write(f"\n=== MODULE: {module_id} ===\n")
        
        if not os.path.isdir(templates_dir):
            pf.write(f"WARNING: Templates directory not found: {templates_dir}\n")
            continue
        
        # Find all .tpl files, sorted
        # EXCLUDE deprecated pom-*.xml.tpl fragments (ODEC-017)
        tpl_files = sorted(glob.glob(os.path.join(templates_dir, '**/*.tpl'), recursive=True))
        tpl_files = [f for f in tpl_files 
                     if not os.path.basename(f).startswith('._')
                     and not (os.path.basename(f).startswith('pom-') and f.endswith('.xml.tpl'))]
        
        # DEC-040: Filter templates by variant
        skipped_variants = 0
        included_count = 0
        
        for tpl_file in tpl_files:
            rel_path = os.path.relpath(tpl_file, templates_dir)
            
            with open(tpl_file, 'r') as tf:
                content = tf.read()
            
            # DEC-040: Check for Variant header
            variant_match = re.search(r'(?://|<!--|#)\s*Variant:\s*(\w+)', content, re.MULTILINE)
            if variant_match:
                template_variant = variant_match.group(1).strip().lower()
                # Skip templates that don't match the selected variant
                if template_variant != http_client_variant.lower():
                    skipped_variants += 1
                    continue  # Skip this template
            
            included_count += 1
            
            # Extract Output header to derive allowed paths
            output_match = re.search(r'(?://|<!--|#)\s*Output:\s*(.+?)(?:\s*-->)?\s*$', content, re.MULTILINE)
            if output_match:
                output_path = output_match.group(1).strip()
                # Normalize: replace template vars with concrete values
                normalized = output_path
                normalized = normalized.replace('{{basePackagePath}}', base_pkg_path)
                normalized = normalized.replace('{{basePackage}}', base_pkg_path)
                # Extract directory (remove filename)
                if '/' in normalized:
                    dir_part = '/'.join(normalized.split('/')[:-1])
                    # Clean up .../... patterns to just the known prefix
                    dir_part = re.sub(r'/\.\.\./?', '/', dir_part)
                    dir_part = dir_part.rstrip('/')
                    if dir_part:
                        # Determine if it's src/main, src/test, or root (pom.xml)
                        if 'test/' in rel_path.lower() or 'Test.java' in output_path:
                            prefix = f"src/test/java/{dir_part}"
                        elif output_path.endswith('.yml') or output_path.endswith('.yaml'):
                            prefix = "src/main/resources"
                        else:
                            prefix = f"src/main/java/{dir_part}"
                        allowed_dirs.add(prefix)
                else:
                    # Root file like pom.xml
                    allowed_dirs.add(normalized)
            
            pf.write(f"\n--- TEMPLATE: {rel_path} ---\n")
            pf.write(content)
            pf.write("\n")
        
        # Report included and skipped
        if skipped_variants > 0:
            print(f"  {module_id}: {included_count} templates (skipped {skipped_variants} non-{http_client_variant} variants)")
        else:
            print(f"  {module_id}: {included_count} templates")
    
    pf.write("\n</templates>\n")

# Save allowed paths for post-generation validation (S2a)
allowed_list = sorted(allowed_dirs)
with open(allowed_paths_file, 'w') as f:
    json.dump({"subphase": subphase.get('id', ''), "allowed_paths": allowed_list}, f, indent=2)

# ─── ODEC-020: Build template manifest ────────────────────────────────────────
# List ALL templates that MUST be generated with their expected output paths
template_manifest = []

# Entity name - try entities array first, then domain object for backwards compat
entities = ctx.get('entities', [])
if entities and len(entities) > 0:
    entity_name = entities[0].get('name', 'Entity')
    entity_lower = entities[0].get('nameLower', entity_name.lower())
else:
    # Fallback to domain object (older context format)
    entity_name = ctx.get('domain', {}).get('entityName', 'Entity')
    entity_lower = ctx.get('domain', {}).get('entityNameLower', 'entity')

# Extract service name for {{ServiceName}} variable (PascalCase)
# Try multiple keys: serviceName, name (Context Agent uses different keys)
service_obj = ctx.get('service', {})
service_name = service_obj.get('serviceName') or service_obj.get('name') or 'service'

# Use pre-calculated PascalCase if available, otherwise convert
service_name_pascal = service_obj.get('serviceNamePascal', None)
if not service_name_pascal:
    # Convert kebab-case to PascalCase: customer-api -> CustomerApi
    service_name_pascal = ''.join(word.capitalize() for word in service_name.replace('-', ' ').replace('_', ' ').split())

for module in subphase['modules']:
    module_id = module['module_id']
    templates_path = module.get('templates_path', f"modules/{module_id}/templates")
    templates_dir = os.path.join(kb_dir, templates_path)
    
    if not os.path.isdir(templates_dir):
        continue
    
    tpl_files = sorted(glob.glob(os.path.join(templates_dir, '**/*.tpl'), recursive=True))
    tpl_files = [f for f in tpl_files 
                 if not os.path.basename(f).startswith('._')
                 and not (os.path.basename(f).startswith('pom-') and f.endswith('.xml.tpl'))]
    
    for tpl_file in tpl_files:
        rel_path = os.path.relpath(tpl_file, templates_dir)
        with open(tpl_file, 'r') as tf:
            content = tf.read()
        
        # DEC-041: Check for Variant header - skip non-matching variants
        variant_match = re.search(r'(?://|<!--|#)\s*Variant:\s*(\w+)', content, re.MULTILINE)
        if variant_match:
            template_variant = variant_match.group(1).strip().lower()
            if template_variant != http_client_variant.lower():
                continue  # Skip this template - wrong variant
        
        output_match = re.search(r'(?://|<!--|#)\s*Output:\s*(.+?)(?:\s*-->)?\s*$', content, re.MULTILINE)
        if output_match:
            output_path = output_match.group(1).strip()
            
            # Resolve template variables
            resolved = output_path
            resolved = resolved.replace('{{basePackagePath}}', base_pkg_path)
            resolved = resolved.replace('{{basePackage}}', base_pkg_path)  # Some use dots, normalize to path
            resolved = resolved.replace('{{Entity}}', entity_name)
            resolved = resolved.replace('{{entity}}', entity_lower)
            resolved = resolved.replace('{{entityName}}', entity_name)      # Alias for {{Entity}}
            resolved = resolved.replace('{{entityNameLower}}', entity_lower) # Alias for {{entity}}
            resolved = resolved.replace('{{entityPlural}}', entity_lower + 's')  # Simple plural
            resolved = resolved.replace('{{ServiceName}}', service_name_pascal)  # For Application.java
            
            # Skip templates with unresolved dynamic variables (e.g., {{EnumName}}, {{ApiName}})
            # These are conditionally generated based on context and may not apply
            if '{{' in resolved:
                # This template has variables we can't resolve statically
                # Don't add to manifest - it's conditionally generated
                continue
            
            template_manifest.append({
                'module': module_id,
                'template': rel_path,
                'output': resolved
            })

# Inject scope restriction into prompt BEFORE templates
# We need to prepend it, so we read/rewrite the prompt
with open(prompt_file, 'r') as f:
    current_prompt = f.read()

scope_section = "\n## SCOPE RESTRICTION (MANDATORY - ODEC-018 / DEC-025)\n\n"
scope_section += "You may ONLY generate files whose output_path starts with one of these prefixes:\n"
for p in allowed_list:
    scope_section += f"- {p}\n"
scope_section += "\nDO NOT generate files outside these paths.\n"
scope_section += "DO NOT generate files for modules or layers not in this subphase.\n"
scope_section += "Any file outside the allowed paths will be REJECTED and deleted.\n"
scope_section += "If context references systems/APIs from other phases, do NOT implement them.\n"
scope_section += "Focus ONLY on the templates provided.\n\n"

# ─── ODEC-020: Add template manifest to prompt ────────────────────────────────
scope_section += "## MANDATORY TEMPLATE MANIFEST (ODEC-020)\n\n"
scope_section += "You MUST generate ALL of the following files. This is a COMPLETE list.\n"
scope_section += "DO NOT skip any template. Every template below MUST produce exactly one output file.\n\n"
scope_section += "| Module | Template | Expected Output |\n"
scope_section += "|--------|----------|----------------|\n"
for item in template_manifest:
    scope_section += f"| {item['module'].replace('mod-code-', '')} | {item['template']} | {item['output']} |\n"
scope_section += f"\n**Total: {len(template_manifest)} files MUST be generated.**\n\n"

# ─── Template Variant Priority Rule ────────────────────────────────────────────
scope_section += "## TEMPLATE VARIANT SELECTION (DEC-035)\n\n"
scope_section += "Some templates have VARIANTS based on config flags (pub/sub pattern):\n"
scope_section += "- Check template headers for '⚠️ VARIANT SELECTION' notes\n"
scope_section += "- If a feature module (e.g., mod-019 HATEOAS) is active, use ITS template version\n"
scope_section += "- Example: When mod-019 is active, use Response-hateoas.java.tpl (class with RepresentationModel)\n"
scope_section += "  instead of mod-015's Response.java.tpl (simple record)\n"
scope_section += "- The template headers explicitly state which module should be used in each case\n\n"

# Insert scope section just before <templates>
insertion_point = current_prompt.find('<templates>')
if insertion_point > 0:
    current_prompt = current_prompt[:insertion_point] + scope_section + current_prompt[insertion_point:]

with open(prompt_file, 'w') as f:
    f.write(current_prompt)

# Save manifest for post-generation validation (ODEC-020)
manifest_file = allowed_paths_file.replace('allowed-paths-', 'template-manifest-')
with open(manifest_file, 'w') as mf:
    json.dump({"subphase": subphase.get('id', ''), "templates": template_manifest}, mf, indent=2)

print(f"  Scope: {len(allowed_list)} allowed path prefixes")
print(f"  Manifest: {len(template_manifest)} templates MUST be generated")
ADD_TEMPLATES

# Final instruction
echo "" >> "${TEMP_PROMPT}"
echo "---" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "OUTPUT ONLY THE JSON. No preamble, no explanation, no markdown code blocks." >> "${TEMP_PROMPT}"
echo "Include the COMPLETE content of each generated file (no truncation, no ellipsis)." >> "${TEMP_PROMPT}"
echo "Generate ALL files from ALL modules in this subphase." >> "${TEMP_PROMPT}"

# ─────────────────────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Executing Claude for subphase ${SUBPHASE_ID}..."

if ! cat "${TEMP_PROMPT}" | claude -p --tools "" > "${RESULT_FILE}" 2>/dev/null; then
    echo "ERROR: Claude execution failed"
    exit 1
fi

# Clean markdown code blocks if present and extract JSON
python3 << CLEAN_JSON
import re
import json

result_file = '${RESULT_FILE}'

with open(result_file, 'r') as f:
    content = f.read()

# Strategy 1: Try as-is (already valid JSON)
try:
    json.loads(content)
    # Already valid, nothing to do
    exit(0)
except json.JSONDecodeError:
    pass

# Strategy 2: Strip markdown code blocks
cleaned = re.sub(r'^\s*\x60\x60\x60json?\s*\n', '', content)
cleaned = re.sub(r'\n\s*\x60\x60\x60\s*$', '', cleaned)
try:
    json.loads(cleaned)
    with open(result_file, 'w') as f:
        f.write(cleaned)
    exit(0)
except json.JSONDecodeError:
    pass

# Strategy 3: Find JSON object in text (LLM wrote explanation around it)
# Look for the outermost { ... } that contains "files"
match = re.search(r'\{[^{}]*"files"\s*:\s*\[.*\]\s*[,}]', content, re.DOTALL)
if not match:
    # Try finding any large JSON block
    match = re.search(r'(\{[\s\S]{100,}\})\s*$', content)

if match:
    # Find the start of this JSON - walk back to find matching brace
    start = content.rfind('{', 0, match.start() + 1)
    candidate = content[start:]
    # Try progressively shorter suffixes to find valid JSON
    depth = 0
    for i, ch in enumerate(candidate):
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        if depth == 0:
            try:
                obj = json.loads(candidate[:i+1])
                with open(result_file, 'w') as f:
                    f.write(candidate[:i+1])
                print(f"Extracted JSON from position {start} ({i+1} chars)")
                exit(0)
            except json.JSONDecodeError:
                continue

print("WARNING: Could not extract valid JSON from output")
print(f"Output starts with: {content[:200]}")
exit(0)  # Don't fail here, let the validation below handle it
CLEAN_JSON

# ─────────────────────────────────────────────────────────────────────────────
# Validate and Extract Files
# ─────────────────────────────────────────────────────────────────────────────
if python3 -c "import json; json.load(open('${RESULT_FILE}'))" 2>/dev/null; then
    echo "✓ Valid JSON"
    
    # Extract files from result with SCOPE VALIDATION (ODEC-018 Step 2a)
    python3 << EXTRACT_SCRIPT
import json
import os

with open('${RESULT_FILE}') as f:
    result = json.load(f)

output_dir = '${OUTPUT_DIR}'
allowed_paths_file = '${ALLOWED_PATHS_FILE}'
files = result.get('files', [])
modules = result.get('modules_processed', [])

# Load allowed paths
allowed_paths = []
if os.path.exists(allowed_paths_file):
    with open(allowed_paths_file) as f:
        allowed_paths = json.load(f).get('allowed_paths', [])

print(f"  Modules: {', '.join(modules) if modules else 'N/A'}")
print(f"  Files:   {len(files)}")

accepted = 0
rejected = 0
rejected_list = []

for file_info in files:
    output_path = file_info.get('output_path', '')
    content = file_info.get('content', '')
    module_id = file_info.get('module_id', 'unknown')
    
    if not output_path or not content:
        continue
    
    # NORMALIZE: Remove common prefixes that LLM might include
    prefixes_to_remove = [
        'src/main/java/',
        'src/test/java/',
        'src/main/resources/',
        'src/test/resources/'
    ]
    
    normalized_path = output_path
    for prefix in prefixes_to_remove:
        if normalized_path.startswith(prefix):
            normalized_path = normalized_path[len(prefix):]
            break
    
    # Determine target directory based on file type
    if 'Test.java' in output_path or '/test/' in output_path:
        full_path = os.path.join(output_dir, 'src/test/java', normalized_path)
        scope_path = f"src/test/java/{normalized_path}"
    elif output_path.endswith(('.yml', '.yaml', '.properties', '.xml')) and not output_path.endswith('pom.xml'):
        filename = os.path.basename(normalized_path)
        full_path = os.path.join(output_dir, 'src/main/resources', filename)
        scope_path = "src/main/resources"
    elif output_path.endswith('pom.xml') or normalized_path == 'pom.xml':
        full_path = os.path.join(output_dir, 'pom.xml')
        scope_path = "pom.xml"
    else:
        full_path = os.path.join(output_dir, 'src/main/java', normalized_path)
        scope_path = f"src/main/java/{normalized_path}"
    
    # SCOPE VALIDATION (ODEC-018)
    if allowed_paths:
        in_scope = False
        for allowed in allowed_paths:
            if scope_path.startswith(allowed) or scope_path == allowed:
                in_scope = True
                break
        
        if not in_scope:
            rejected += 1
            rejected_list.append(scope_path)
            continue
    
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    
    # Ensure content ends with exactly one newline (reproducibility)
    normalized_content = content.rstrip() + '\n'
    
    with open(full_path, 'w') as f:
        f.write(normalized_content)
    accepted += 1

if rejected > 0:
    print(f"  Scope:   {accepted} accepted, {rejected} REJECTED (out-of-scope)")
    for rp in rejected_list:
        print(f"    REJECTED: {rp}")
else:
    print(f"  Scope:   {accepted} accepted (all in scope)")

print("")
EXTRACT_SCRIPT

else
    echo "✗ Invalid JSON"
    echo ""
    echo "First 100 lines of output:"
    head -100 "${RESULT_FILE}"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "Result: ${RESULT_FILE}"
echo "═══════════════════════════════════════════════════════════════"
