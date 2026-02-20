#!/bin/bash
# =============================================================================
# run-context.sh - Execute Context Agent
# =============================================================================
# Usage: ./run-context.sh <inputs_dir> <discovery_file> [output_file]
# =============================================================================
set -e

INPUTS_DIR="${1:-}"
DISCOVERY_FILE="${2:-}"
OUTPUT_FILE="${3:-generation-context.json}"

# Resolve KB_DIR relative to script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="${KB_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/enablement-2.0-kb}"

if [ -z "${INPUTS_DIR}" ] || [ -z "${DISCOVERY_FILE}" ]; then
    echo "Usage: $0 <inputs_dir> <discovery_file> [output_file]"
    exit 1
fi

[ ! -d "${INPUTS_DIR}" ] && echo "ERROR: Directory not found: ${INPUTS_DIR}" && exit 1
[ ! -f "${DISCOVERY_FILE}" ] && echo "ERROR: Discovery file not found: ${DISCOVERY_FILE}" && exit 1

echo "═══════════════════════════════════════════════════════════════"
echo "  CONTEXT AGENT"
echo "═══════════════════════════════════════════════════════════════"
echo "Inputs:    ${INPUTS_DIR}"
echo "Discovery: ${DISCOVERY_FILE}"
echo "Output:    ${OUTPUT_FILE}"
echo ""

TEMP_PROMPT=$(mktemp)
trap "rm -f ${TEMP_PROMPT}" EXIT

# =============================================================================
# SYSTEM PROMPT - EMBEBIDO PARA DETERMINISMO
# =============================================================================
cat >> "${TEMP_PROMPT}" << 'SYSTEM_PROMPT'
You are the Context Agent for Enablement 2.0.

## Task
Extract all template variables from the provided specifications and produce a JSON context for code generation.

## Critical Rules

1. **Output ONLY valid JSON** - No explanations, no markdown code blocks, no commentary before or after
2. **Extract from specs, don't invent** - Only include data present in inputs
3. **Use exact values** - Don't modify or interpret values
4. **Be deterministic** - Given the same inputs, always produce the same output

## EXACT Output Schema

You MUST produce EXACTLY this JSON structure. No variations. No extra fields. No wrapper objects.

{
  "version": "1.0",
  "timestamp": "{{ISO-8601 timestamp}}",
  "agent": "context",
  "service": {
    "name": "{{service name from discovery}}",
    "basePackage": "{{base package from prompt}}",
    "artifactId": "{{artifact id, usually same as name}}",
    "groupId": "{{group id from package, e.g., 'com.bank'}}"
  },
  "domain": {
    "entityName": "{{PascalCase entity name}}",
    "entityNameLower": "{{lowercase entity name}}",
    "entityNamePlural": "{{plural lowercase}}",
    "idType": "String",
    "fields": [
      {
        "name": "{{field name}}",
        "type": "{{type - use schema name for $ref, else OpenAPI type}}",
        "required": {{true or false}},
        "format": {{null or "uuid" or "email" or "date" or "date-time"}}
      }
    ]
  },
  "api": {
    "basePath": "{{from OpenAPI servers or first path segment}}",
    "endpoints": [
      {
        "method": "{{HTTP method uppercase}}",
        "path": "{{EXACT path from OpenAPI}}",
        "operationId": "{{operationId}}",
        "requestBody": {{null or "RequestTypeName"}},
        "responseType": "{{response schema name}}",
        "pathParams": [],
        "queryParams": []
      }
    ]
  },
  "systemApi": {
    "name": "{{API title from spec}}",
    "baseUrl": "{{from servers}}",
    "endpoints": [
      {
        "method": "{{HTTP method}}",
        "path": "{{EXACT path}}",
        "operationId": "{{operationId}}"
      }
    ]
  },
  "mapping": {
    "domainToSystem": [
      {
        "domainField": "{{domain field}}",
        "systemField": "{{system field}}",
        "transformation": "{{transformation expression}}"
      }
    ],
    "systemToDomain": [
      {
        "systemField": "{{system field}}",
        "domainField": "{{domain field}}",
        "transformation": "{{transformation expression}}"
      }
    ],
    "errorMapping": [
      {
        "systemCode": "{{code}}",
        "httpStatus": {{status number}},
        "domainCode": {{null or "ERROR_CODE"}}
      }
    ]
  },
  "resilience": {
    "circuitBreaker": {
      "failureRateThreshold": {{number}},
      "waitDurationInOpenState": "{{duration}}",
      "slidingWindowSize": {{number}}
    },
    "retry": {
      "maxAttempts": {{number}},
      "waitDuration": "{{duration}}",
      "exponentialBackoff": {{true or false}}
    },
    "timeout": {
      "duration": "{{duration}}"
    }
  },
  "modules": ["{{module ids from discovery, same order}}"]
}

## EXTRACTION RULES (for determinism)

1. For field types: if property has $ref, use the REFERENCED SCHEMA NAME (e.g., "CustomerStatus"), not primitive
2. For paths: copy EXACTLY from OpenAPI - never modify
3. Maintain array ordering from source documents
4. modules array must match discovery result order
5. For api.basePath: extract ONLY the version prefix (e.g., "/api/v1") - do NOT include resource names like "/customers"

---

Extract context from these inputs:

SYSTEM_PROMPT

# Add discovery result
echo "" >> "${TEMP_PROMPT}"
echo "<discovery_result>" >> "${TEMP_PROMPT}"
cat "${DISCOVERY_FILE}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</discovery_result>" >> "${TEMP_PROMPT}"

# Add prompt
echo "" >> "${TEMP_PROMPT}"
echo "<prompt>" >> "${TEMP_PROMPT}"
cat "${INPUTS_DIR}/prompt.md" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</prompt>" >> "${TEMP_PROMPT}"

# Add domain API spec
echo "" >> "${TEMP_PROMPT}"
echo "<domain_api_spec>" >> "${TEMP_PROMPT}"
if [ -f "${INPUTS_DIR}/domain-api-spec.yaml" ]; then
    cat "${INPUTS_DIR}/domain-api-spec.yaml" >> "${TEMP_PROMPT}"
else
    echo "(not provided)" >> "${TEMP_PROMPT}"
fi
echo "" >> "${TEMP_PROMPT}"
echo "</domain_api_spec>" >> "${TEMP_PROMPT}"

# Add system API specs
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

# Add mapping
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

    # ─────────────────────────────────────────────────────────────────────────
    # Consolidate Maven Dependencies (DETERMINISTIC - no LLM)
    # Reads dependencies.yaml from each discovered module and merges them
    # into a single maven_dependencies section in generation-context.json
    # See ODEC-017 in DECISION-LOG.md
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo "Consolidating Maven dependencies..."
    python3 << CONSOLIDATE_DEPS
import json
import os
import sys

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False
    print("  WARNING: PyYAML not available, skipping Maven dependency consolidation")
    print("  Install with: pip3 install pyyaml")
    sys.exit(0)

context_file = '${OUTPUT_FILE}'
kb_dir = '${KB_DIR}'
print(f"  KB_DIR: {kb_dir}")
print(f"  KB_DIR exists: {os.path.isdir(kb_dir)}")
print(f"  modules dir exists: {os.path.isdir(os.path.join(kb_dir, 'modules'))}")

# Load current context
with open(context_file) as f:
    context = json.load(f)

# Read modules list from context
modules = context.get('modules', [])
if not modules:
    print("  WARNING: No modules in context, skipping dependency consolidation")
    sys.exit(0)

# Consolidate: deduplicate by groupId:artifactId, merge properties
all_deps = {}          # key: "groupId:artifactId" → dep dict
all_props = {}         # key: property name → value
all_dep_mgmt = {}      # key: "groupId:artifactId" → dep dict

for module_id in modules:
    deps_file = os.path.join(kb_dir, 'modules', module_id, 'dependencies.yaml')
    if not os.path.exists(deps_file):
        print(f"  - {module_id}: not found at {deps_file}")
        continue
    
    print(f"  + {module_id}: found")
    
    with open(deps_file) as f:
        data = yaml.safe_load(f)
    
    if not data:
        continue
    
    maven = data.get('maven', {})
    
    # Dependencies
    for dep in maven.get('dependencies', []):
        key = f"{dep['groupId']}:{dep['artifactId']}"
        if key not in all_deps:
            all_deps[key] = dep
    
    # Properties
    for k, v in maven.get('properties', {}).items():
        if k in all_props and str(all_props[k]) != str(v):
            print(f"  WARNING: Property conflict for '{k}': {all_props[k]} vs {v} (keeping latest)")
        all_props[k] = v
    
    # Dependency management (BOMs)
    for dep in maven.get('dependency_management', []):
        key = f"{dep['groupId']}:{dep['artifactId']}"
        if key not in all_dep_mgmt:
            all_dep_mgmt[key] = dep

# Build consolidated section
maven_dependencies = {
    'dependencies': list(all_deps.values()),
    'properties': all_props
}

# Only include dependency_management if non-empty
if all_dep_mgmt:
    maven_dependencies['dependency_management'] = list(all_dep_mgmt.values())

# Inject into context
context['maven_dependencies'] = maven_dependencies

# Write back
with open(context_file, 'w') as f:
    json.dump(context, f, indent=2)

print(f"  ✓ Dependencies: {len(all_deps)} unique (from {len(modules)} modules)")
print(f"  ✓ Properties:   {len(all_props)}")
if all_dep_mgmt:
    print(f"  ✓ Dep Mgmt:     {len(all_dep_mgmt)} BOMs")
CONSOLIDATE_DEPS

    # ─────────────────────────────────────────────────────────────────────────
    # Collect Config Flags (DEC-035: Pub/Sub Pattern)
    # Reads publishes_flags from capability-index.yaml for each active feature
    # and merges them into a config_flags section in generation-context.json
    # Templates use {{#config.flagName}} conditionals to react to these flags
    # ─────────────────────────────────────────────────────────────────────────
    echo ""
    echo "Collecting config flags (DEC-035)..."
    python3 << COLLECT_FLAGS
import json
import os
import sys

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False
    print("  WARNING: PyYAML not available, skipping config flag collection")
    sys.exit(0)

context_file = '${OUTPUT_FILE}'
kb_dir = '${KB_DIR}'
discovery_file = '${DISCOVERY_FILE}'

# Load context and discovery
with open(context_file) as f:
    context = json.load(f)

with open(discovery_file) as f:
    discovery = json.load(f)

# DEC-042: Propagate stack from discovery to context
# This allows CodeGen to load stack-specific style files
stack = discovery.get('stack', 'java-spring')
context['stack'] = stack

# Load capability-index
cap_index_path = os.path.join(kb_dir, 'runtime', 'discovery', 'capability-index.yaml')
if not os.path.exists(cap_index_path):
    print(f"  WARNING: capability-index.yaml not found at {cap_index_path}")
    sys.exit(0)

with open(cap_index_path) as f:
    cap_index = yaml.safe_load(f)

# Get detected capabilities from discovery
detected = discovery.get('detected_capabilities', [])
if not detected:
    print("  WARNING: No detected capabilities in discovery result")
    sys.exit(0)

# Collect all publishes_flags from active features
config_flags = {}
flags_sources = []

capabilities = cap_index.get('capabilities', {})

for cap in detected:
    cap_id = cap.get('capability_id', '')
    feature_name = cap.get('feature', '')
    
    # Parse capability_id (e.g., "api-architecture.domain-api")
    parts = cap_id.split('.')
    if len(parts) >= 2:
        cap_name = parts[0]
        feat_name = parts[1]
    else:
        cap_name = cap_id
        feat_name = feature_name
    
    # Navigate to the feature in capability-index
    cap_def = capabilities.get(cap_name, {})
    features = cap_def.get('features', {})
    feat_def = features.get(feat_name, {})
    
    # Check for publishes_flags
    pub_flags = feat_def.get('publishes_flags', {})
    if pub_flags:
        for flag_name, flag_value in pub_flags.items():
            config_flags[flag_name] = flag_value
            flags_sources.append(f"{cap_id}:{flag_name}={flag_value}")

# ═══════════════════════════════════════════════════════════════════════════════
# DEC-041: Module Variant Resolution
# ═══════════════════════════════════════════════════════════════════════════════
# 1. Read variant_selections from discovery result (user overrides via prompt keywords)
# 2. For each module, check MODULE.md for variants definition
# 3. Apply selection or use default
# 4. Add resolved variant to config_flags for CodeGen filtering

variant_selections = discovery.get('variant_selections', {})
modules_dir = os.path.join(kb_dir, 'modules')

# Known module variants (hardcoded for now, could be dynamic by parsing MODULE.md)
MODULE_VARIANTS = {
    'mod-code-017-persistence-systemapi': {
        'http_client': {
            'default': 'restclient',
            'options': ['restclient', 'feign', 'resttemplate']
        }
    }
}

for module_id in context.get('modules', []):
    if module_id in MODULE_VARIANTS:
        for variant_name, variant_def in MODULE_VARIANTS[module_id].items():
            # Check if user specified via discovery
            selection_key = f"{module_id}.{variant_name}"
            # Also check short form: "mod-017.http_client"
            short_key = f"mod-{module_id.split('-')[2]}.{variant_name}"
            
            selected = variant_selections.get(selection_key) or variant_selections.get(short_key)
            
            if selected and selected in variant_def['options']:
                config_flags[variant_name] = selected
                flags_sources.append(f"variant:{module_id}.{variant_name}={selected} (user)")
            else:
                # Use module default
                config_flags[variant_name] = variant_def['default']
                flags_sources.append(f"variant:{module_id}.{variant_name}={variant_def['default']} (default)")

# Inject into context
context['config_flags'] = config_flags

# Write back
with open(context_file, 'w') as f:
    json.dump(context, f, indent=2)

if config_flags:
    print(f"  ✓ Config flags collected: {len(config_flags)}")
    for src in flags_sources:
        print(f"    - {src}")
else:
    print("  ✓ No config flags published by active features")
COLLECT_FLAGS

    echo ""
    python3 << PYSCRIPT
import json
with open('${OUTPUT_FILE}') as f:
    d = json.load(f)
    svc = d.get('service', {})
    print(f"Service:     {svc.get('serviceName', svc.get('name', 'N/A'))}")
    print(f"Package:     {svc.get('basePackage', 'N/A')}")
    domain = d.get('domain', d.get('entities', [{}]))
    if isinstance(domain, dict):
        print(f"Entity:      {domain.get('entityName', 'N/A')}")
        print(f"Fields:      {len(domain.get('fields', []))}")
    elif isinstance(domain, list) and domain:
        print(f"Entity:      {domain[0].get('name', 'N/A')}")
        print(f"Fields:      {len(domain[0].get('fields', []))}")
    api = d.get('api', {})
    print(f"Endpoints:   {len(api.get('endpoints', []))}")
    print(f"Modules:     {len(d.get('modules', []))}")
    mvn = d.get('maven_dependencies', {})
    print(f"Maven deps:  {len(mvn.get('dependencies', []))}")
    print(f"Maven props: {len(mvn.get('properties', {}))}")
    flags = d.get('config_flags', {})
    if flags:
        print(f"Config flags: {len(flags)} ({', '.join(f'{k}={v}' for k,v in flags.items())})")
    else:
        print(f"Config flags: 0")
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
