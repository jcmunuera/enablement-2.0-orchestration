#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# TRANSFORM AGENT - Enablement 2.0 (Phase 3: Cross-Cutting)
# ═══════════════════════════════════════════════════════════════════════════
# Applies cross-cutting transformations to existing generated code.
# Reads transform descriptors from KB modules and modifies files in-place.
#
# Usage:
#   ./run-transform.sh <subphase_id> <execution_plan> <generation_context> <output_dir>
#
# Inputs:
#   - subphase_id: Which subphase from execution-plan (e.g., "3.1")
#   - execution_plan: Path to execution-plan.json (from Plan Agent)
#   - generation_context: Path to generation-context.json (from Context Agent)
#   - output_dir: Directory with generated code from Phase 1 & 2
#
# Outputs:
#   - Modified files in output_dir (overwritten in-place)
#   - transform-result-{subphase_id}.json: Manifest of transformations
#
# Design (ODEC-022):
#   Currently delegates all transformation logic to LLM.
#   Individual actions may be migrated to deterministic execution later.
#   Transform descriptor format is the stable contract.
# ═══════════════════════════════════════════════════════════════════════════
set -e

SUBPHASE_ID="${1:-}"
PLAN_FILE="${2:-}"
CONTEXT_FILE="${3:-}"
OUTPUT_DIR="${4:-./generated}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="${KB_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/enablement-2.0-kb}"

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${SUBPHASE_ID}" ] || [ -z "${PLAN_FILE}" ] || [ -z "${CONTEXT_FILE}" ]; then
    echo "Usage: $0 <subphase_id> <execution_plan> <generation_context> <output_dir>"
    echo ""
    echo "Example:"
    echo "  $0 3.1 execution-plan.json generation-context.json ./generated"
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

if [ ! -d "${OUTPUT_DIR}/src" ]; then
    echo "ERROR: Output directory does not contain generated code: ${OUTPUT_DIR}"
    echo "       Run Phase 1 & 2 (run-generate.sh) first."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Extract subphase info from plan
# ─────────────────────────────────────────────────────────────────────────────
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

if [ "${ACTION}" != "transform" ]; then
    echo "ERROR: Subphase ${SUBPHASE_ID} has action='${ACTION}', not 'transform'"
    echo "       Use run-codegen.sh for generate subphases"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  TRANSFORM AGENT - Subphase ${SUBPHASE_ID} (${SUBPHASE_NAME})"
echo "═══════════════════════════════════════════════════════════════"
echo "Modules:    ${MODULE_COUNT}"
echo "Action:     ${ACTION}"
echo "Output:     ${OUTPUT_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Ensure trace directory
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}/.trace"

RESULT_FILE="${OUTPUT_DIR}/transform-result-${SUBPHASE_ID}.json"

# ─────────────────────────────────────────────────────────────────────────────
# Build prompt
# ─────────────────────────────────────────────────────────────────────────────
TEMP_PROMPT=$(mktemp)
# Cleanup on exit
trap "rm -f ${TEMP_PROMPT}" EXIT

cat >> "${TEMP_PROMPT}" << 'SYSTEM_PROMPT'
You are the Transform Agent for Enablement 2.0. Your job is to apply cross-cutting
transformations to existing Java source code. You receive:

1. TRANSFORM DESCRIPTORS - YAML files that describe WHAT to transform and HOW
2. EXISTING CODE - Java files generated in previous phases that you must MODIFY
3. SNIPPETS - Code fragments to INSERT into the existing code
4. CONTEXT - Variables for placeholder resolution

## CRITICAL RULES

1. **Preserve existing code** - Only ADD to files. Never remove or rewrite existing
   methods, fields, imports, or annotations unless the transform descriptor explicitly
   says to REPLACE something.

2. **Follow descriptors exactly** - Each transform descriptor lists specific steps
   (add_imports, add_annotation_to_methods, etc.). Execute ONLY those steps.
   Do NOT add extra resilience patterns, logging, or "improvements".

3. **Use snippets as-is** - When a step references a snippet file, use its content
   exactly, only resolving {{placeholder}} variables.

4. **Respect execution order** - Modules are listed in dependency order. When multiple
   modules target the same file, apply ALL transformations to produce the final version.
   For annotations: respect the order specified (e.g., @CircuitBreaker before @Retry).

5. **Deduplicate** - If an import, dependency, or constant already exists, do NOT add
   a duplicate. Check before adding.

6. **YAML deep merge** - When merging YAML config, add new sections without overwriting
   existing ones. Use the merge_strategy specified in the descriptor.

7. **POM dependencies** - Add dependencies only if not already present (condition: not_exists).
   Add properties only if not already present.

## OUTPUT FORMAT

Respond with a JSON object containing ALL modified files with their COMPLETE content.
Include ONLY files that were actually modified. Do NOT include unmodified files.

```json
{
  "version": "1.0",
  "agent": "transform",
  "subphase_id": "3.1",
  "modules_processed": ["mod-code-001-...", "mod-code-002-..."],
  "files": [
    {
      "path": "src/main/java/com/bank/customer/adapter/out/systemapi/CustomerSystemApiAdapter.java",
      "content": "... COMPLETE file content with transformations applied ...",
      "transformations": ["add_imports", "add_constant", "add_annotation", "add_fallback"]
    },
    {
      "path": "src/main/resources/application.yml",
      "content": "... COMPLETE merged YAML ...",
      "transformations": ["yaml_merge"]
    },
    {
      "path": "pom.xml",
      "content": "... COMPLETE pom.xml with added dependencies ...",
      "transformations": ["pom_dependencies"]
    }
  ]
}
```

IMPORTANT: Output ONLY the JSON. No preamble, no explanation, no markdown code blocks.
Include the COMPLETE content of each modified file (no truncation, no ellipsis).

{{STYLE_RULES}}
SYSTEM_PROMPT

# ─────────────────────────────────────────────────────────────────────────────
# Inject style rules (DEC-042)
# ─────────────────────────────────────────────────────────────────────────────
STACK=$(python3 -c "
import json
with open('${CONTEXT_FILE}') as f:
    ctx = json.load(f)
stack = ctx.get('service', {}).get('stack', 'java-springboot')
# Normalize stack name for style file lookup
normalized = stack.replace('springboot', 'spring').replace('java-spring-boot', 'java-spring')
if not normalized.startswith('java-'):
    normalized = 'java-spring'
print(normalized)
" 2>/dev/null || echo "java-spring")

STYLE_FILE="${KB_DIR}/runtime/codegen/styles/${STACK}.style.md"
if [ -f "${STYLE_FILE}" ]; then
    STYLE_CONTENT=$(cat "${STYLE_FILE}")
    python3 << INJECT_STYLE
with open('${TEMP_PROMPT}', 'r') as f:
    content = f.read()
style = open('${STYLE_FILE}').read()
content = content.replace('{{STYLE_RULES}}', '## CODE STYLE RULES (DEC-042)\n\n' + style)
with open('${TEMP_PROMPT}', 'w') as f:
    f.write(content)
INJECT_STYLE
    echo "  Style:  ${STACK}.style.md loaded"
else
    sed -i 's|{{STYLE_RULES}}|(No stack-specific style file found - using defaults)|g' "${TEMP_PROMPT}"
    echo "  Style:  No style file for ${STACK}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Add subphase info and context
# ─────────────────────────────────────────────────────────────────────────────
echo "" >> "${TEMP_PROMPT}"
echo "<subphase_info>" >> "${TEMP_PROMPT}"
echo "${SUBPHASE_INFO}" >> "${TEMP_PROMPT}"
echo "</subphase_info>" >> "${TEMP_PROMPT}"

echo "" >> "${TEMP_PROMPT}"
echo "<generation_context>" >> "${TEMP_PROMPT}"
cat "${CONTEXT_FILE}" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "</generation_context>" >> "${TEMP_PROMPT}"

# ─────────────────────────────────────────────────────────────────────────────
# Load transform descriptors, resolve execution order, collect target files
# ─────────────────────────────────────────────────────────────────────────────
python3 << BUILD_TRANSFORM_PROMPT
import json
import os
import glob
import yaml
import fnmatch

subphase = json.loads('''${SUBPHASE_INFO}''')
kb_dir = '${KB_DIR}'
output_dir = '${OUTPUT_DIR}'
prompt_file = '${TEMP_PROMPT}'
context_file = '${CONTEXT_FILE}'

# Load context
with open(context_file) as f:
    ctx = json.load(f)

base_pkg = ctx.get('service', {}).get('basePackage', '')
base_pkg_path = base_pkg.replace('.', '/')
service_name = ctx.get('service', {}).get('serviceName', '')
entity_name = ctx.get('domain', {}).get('entityName', '')

# ─────────────────────────────────────────────────────────────────────────
# Step 1: Load all transform descriptors for modules in subphase
# ─────────────────────────────────────────────────────────────────────────
modules = subphase['modules']
module_transforms = {}

for module in modules:
    module_id = module['module_id']
    transform_dir = os.path.join(kb_dir, 'modules', module_id, 'transform')
    
    if not os.path.isdir(transform_dir):
        print(f"  WARNING: No transform/ directory for {module_id}")
        continue
    
    # Find transform YAML
    yaml_files = [f for f in glob.glob(os.path.join(transform_dir, '*.yaml'))
                  if not os.path.basename(f).startswith('._')]
    
    if not yaml_files:
        print(f"  WARNING: No transform descriptor YAML for {module_id}")
        continue
    
    for yf in yaml_files:
        with open(yf) as f:
            descriptor = yaml.safe_load(f)
        
        transform = descriptor.get('transformation', {})
        
        # Load snippets
        snippets = {}
        snippets_dir = os.path.join(transform_dir, 'snippets')
        if os.path.isdir(snippets_dir):
            for sf in os.listdir(snippets_dir):
                if sf.startswith('._'):
                    continue
                with open(os.path.join(snippets_dir, sf)) as snippet_f:
                    snippets[sf] = snippet_f.read()
        
        module_transforms[module_id] = {
            'descriptor': transform,
            'snippets': snippets,
            'yaml_file': yf,
            'depends_on': transform.get('depends_on', [])
        }
        
        print(f"  Loaded: {module_id} ({transform.get('id', 'unknown')}) "
              f"- {len(transform.get('steps', []))} steps, {len(snippets)} snippets")

if not module_transforms:
    print("ERROR: No transform descriptors found for any module in subphase")
    exit(1)

# ─────────────────────────────────────────────────────────────────────────
# Step 2: Resolve execution order (topological sort by depends_on)
# ─────────────────────────────────────────────────────────────────────────
ordered_modules = []
remaining = dict(module_transforms)

# Simple topological sort
max_iterations = len(remaining) + 1
iteration = 0
while remaining and iteration < max_iterations:
    iteration += 1
    for mod_id in sorted(remaining.keys()):  # Alphabetical tiebreak
        deps = remaining[mod_id]['depends_on']
        # Check if all dependencies are already in ordered list
        deps_satisfied = all(
            d in [o for o in ordered_modules] or d not in remaining
            for d in deps
        )
        if deps_satisfied:
            ordered_modules.append(mod_id)
    # Remove ordered modules from remaining
    for mod_id in ordered_modules:
        remaining.pop(mod_id, None)

if remaining:
    print(f"  WARNING: Circular dependency detected for: {list(remaining.keys())}")
    # Add remaining in alphabetical order
    ordered_modules.extend(sorted(remaining.keys()))

print(f"\n  Execution order: {' → '.join([m.split('-')[-1] for m in ordered_modules])}")

# ─────────────────────────────────────────────────────────────────────────
# Step 3: Identify target files from output_dir
# ─────────────────────────────────────────────────────────────────────────
# Collect all target patterns across all transforms
all_target_files = {}  # path -> content

for mod_id in ordered_modules:
    transform = module_transforms[mod_id]['descriptor']
    targets = transform.get('targets', [])
    if not targets:
        # Check singular 'target' key (timeout uses this)
        target = transform.get('target', {})
        if target:
            targets = [target]
    
    for target in targets:
        pattern = target.get('pattern', target.get('file_pattern', ''))
        excludes = target.get('exclude', [])
        
        if not pattern:
            continue
        
        # Find matching files in output_dir
        for root, dirs, files in os.walk(output_dir):
            for fname in files:
                fpath = os.path.join(root, fname)
                rel_path = os.path.relpath(fpath, output_dir)
                
                if fnmatch.fnmatch(rel_path, pattern) or fnmatch.fnmatch(fpath, pattern):
                    # Check excludes
                    excluded = False
                    for exc in excludes:
                        if fnmatch.fnmatch(rel_path, exc):
                            excluded = True
                            break
                    
                    if not excluded and rel_path not in all_target_files:
                        with open(fpath, 'r') as tf:
                            all_target_files[rel_path] = tf.read()

# Also load application.yml and pom.xml (for yaml_merge and pom_dependencies)
for config_file in ['src/main/resources/application.yml', 'pom.xml']:
    full_path = os.path.join(output_dir, config_file)
    if os.path.exists(full_path) and config_file not in all_target_files:
        with open(full_path, 'r') as cf:
            all_target_files[config_file] = cf.read()

print(f"  Target files: {len(all_target_files)}")
for tf in sorted(all_target_files.keys()):
    print(f"    - {tf}")

# ─────────────────────────────────────────────────────────────────────────
# Step 4: Build prompt sections
# ─────────────────────────────────────────────────────────────────────────
with open(prompt_file, 'a') as pf:
    
    # --- Transform descriptors (in execution order) ---
    pf.write("\n<transform_descriptors>\n")
    pf.write(f"Apply these transformations IN ORDER to the existing code below.\n")
    pf.write(f"Execution order: {' → '.join([m.split('-')[-1] for m in ordered_modules])}\n\n")
    
    for i, mod_id in enumerate(ordered_modules, 1):
        mt = module_transforms[mod_id]
        descriptor = mt['descriptor']
        snippets = mt['snippets']
        
        pf.write(f"=== TRANSFORM {i}: {mod_id} ===\n")
        pf.write(f"ID: {descriptor.get('id', 'unknown')}\n")
        pf.write(f"Type: {descriptor.get('type', 'unknown')}\n")
        pf.write(f"Description: {descriptor.get('description', '')}\n\n")
        
        # Steps
        steps = descriptor.get('steps', [])
        if steps:
            pf.write("Steps:\n")
            for j, step in enumerate(steps, 1):
                pf.write(f"  {j}. action: {step.get('action', 'unknown')}\n")
                # Include relevant details
                for key in ['imports', 'position', 'condition', 'snippet',
                           'selector', 'annotation', 'variables', 'for_each']:
                    if key in step:
                        val = step[key]
                        if isinstance(val, dict):
                            pf.write(f"     {key}:\n")
                            for k, v in val.items():
                                pf.write(f"       {k}: {v}\n")
                        elif isinstance(val, list):
                            pf.write(f"     {key}: {', '.join(str(v) for v in val)}\n")
                        else:
                            pf.write(f"     {key}: {val}\n")
            pf.write("\n")
        
        # Modifications (timeout style)
        modifications = descriptor.get('modifications', [])
        if modifications:
            pf.write("Modifications:\n")
            for j, mod in enumerate(modifications, 1):
                pf.write(f"  {j}. type: {mod.get('type', 'unknown')}\n")
                for key in ['target', 'old_pattern', 'new_value']:
                    if key in mod:
                        pf.write(f"     {key}: {mod[key]}\n")
            pf.write("\n")
        
        # YAML merge
        yaml_merge = descriptor.get('yaml_merge', descriptor.get('yaml_config', {}))
        if yaml_merge:
            pf.write("YAML Configuration to merge:\n")
            for key in ['file', 'path', 'merge_strategy', 'content']:
                if key in yaml_merge:
                    pf.write(f"  {key}: {yaml_merge[key]}\n")
            # Include template content if referenced
            tpl_ref = yaml_merge.get('template', '')
            if tpl_ref:
                tpl_path = os.path.normpath(os.path.join(
                    kb_dir, 'modules', mod_id, 'transform', tpl_ref))
                if os.path.exists(tpl_path):
                    with open(tpl_path) as tpl_f:
                        pf.write(f"  template_content: |\n")
                        for line in tpl_f:
                            pf.write(f"    {line}")
                        pf.write("\n")
            # Include inline variables
            variables = yaml_merge.get('variables', {})
            if variables:
                pf.write("  variables:\n")
                for k, v in variables.items():
                    pf.write(f"    {k}: {v}\n")
            pf.write("\n")
        
        # POM dependencies
        pom_deps = descriptor.get('pom_dependencies', [])
        pom_props = descriptor.get('pom_properties', [])
        if pom_deps or pom_props:
            pf.write("POM Dependencies (add if not already present):\n")
            for dep in pom_deps:
                pf.write(f"  - {dep.get('groupId', '')}:{dep.get('artifactId', '')}")
                if dep.get('version'):
                    pf.write(f":{dep['version']}")
                if dep.get('condition'):
                    pf.write(f" (condition: {dep['condition']})")
                pf.write("\n")
            for prop in pom_props:
                pf.write(f"  property: {prop.get('name', '')} = {prop.get('value', '')}")
                if prop.get('condition'):
                    pf.write(f" (condition: {prop['condition']})")
                pf.write("\n")
            pf.write("\n")
        
        # Fingerprints (for reference)
        fingerprints = descriptor.get('fingerprints', [])
        if fingerprints:
            pf.write("Expected fingerprints (validation will check these):\n")
            for fp in fingerprints:
                pf.write(f"  - pattern: {fp.get('pattern', '')} in {fp.get('file', '*')}\n")
            pf.write("\n")
        
        # Snippets
        if snippets:
            pf.write("Snippets (use these EXACTLY, only resolving {{variables}}):\n\n")
            for snippet_name, snippet_content in sorted(snippets.items()):
                pf.write(f"--- snippet: {snippet_name} ---\n")
                pf.write(snippet_content)
                pf.write("\n--- end snippet ---\n\n")
    
    pf.write("</transform_descriptors>\n")
    
    # --- Existing code to transform ---
    pf.write("\n<existing_code>\n")
    pf.write("These are the files you must MODIFY. Apply the transformations above.\n")
    pf.write("Return the COMPLETE content of EACH file you modify.\n\n")
    
    for rel_path in sorted(all_target_files.keys()):
        content = all_target_files[rel_path]
        pf.write(f"=== FILE: {rel_path} ===\n")
        pf.write(content)
        pf.write(f"\n=== END FILE: {rel_path} ===\n\n")
    
    pf.write("</existing_code>\n")
    
    # --- Context variables for placeholder resolution ---
    pf.write("\n<context_variables>\n")
    pf.write(f"serviceName: {service_name}\n")
    pf.write(f"entityName: {entity_name}\n")
    pf.write(f"basePackage: {base_pkg}\n")
    pf.write(f"basePackagePath: {base_pkg_path}\n")
    pf.write("</context_variables>\n")

# Save ordered modules for result
with open(prompt_file + '.meta', 'w') as mf:
    json.dump({
        'ordered_modules': ordered_modules,
        'target_files': list(all_target_files.keys())
    }, mf)

BUILD_TRANSFORM_PROMPT

# Final instruction
echo "" >> "${TEMP_PROMPT}"
echo "---" >> "${TEMP_PROMPT}"
echo "" >> "${TEMP_PROMPT}"
echo "OUTPUT ONLY THE JSON. No preamble, no explanation, no markdown code blocks." >> "${TEMP_PROMPT}"
echo "Include the COMPLETE content of each MODIFIED file (no truncation, no ellipsis)." >> "${TEMP_PROMPT}"
echo "Only include files that were actually modified by the transformations." >> "${TEMP_PROMPT}"
echo "Ensure trailing newline on every file." >> "${TEMP_PROMPT}"

# ─────────────────────────────────────────────────────────────────────────────
# Execute LLM
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Executing Claude for transform subphase ${SUBPHASE_ID}..."

if ! cat "${TEMP_PROMPT}" | claude -p --tools "" > "${RESULT_FILE}" 2>/dev/null; then
    echo "ERROR: Claude execution failed"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Clean JSON output (same strategy as run-codegen.sh)
# ─────────────────────────────────────────────────────────────────────────────
python3 << CLEAN_JSON
import re
import json

result_file = '${RESULT_FILE}'

with open(result_file, 'r') as f:
    content = f.read()

# Strategy 1: Try as-is
try:
    json.loads(content)
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

# Strategy 3: Find JSON object in text
match = re.search(r'\{[^{}]*"files"\s*:\s*\[.*\]\s*[,}]', content, re.DOTALL)
if not match:
    match = re.search(r'(\{[\s\S]{100,}\})\s*$', content)

if match:
    start = content.rfind('{', 0, match.start() + 1)
    candidate = content[start:]
    depth = 0
    for i, ch in enumerate(candidate):
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        if depth == 0:
            try:
                json.loads(candidate[:i+1])
                with open(result_file, 'w') as f:
                    f.write(candidate[:i+1])
                print(f"Extracted JSON from position {start} ({i+1} chars)")
                exit(0)
            except json.JSONDecodeError:
                continue

print("WARNING: Could not extract valid JSON from output")
print(f"Output starts with: {content[:200]}")
exit(0)
CLEAN_JSON

# ─────────────────────────────────────────────────────────────────────────────
# Validate and write modified files
# ─────────────────────────────────────────────────────────────────────────────
if python3 -c "import json; json.load(open('${RESULT_FILE}'))" 2>/dev/null; then
    echo "✓ Valid JSON"
    
    python3 << EXTRACT_AND_WRITE
import json
import os

result_file = '${RESULT_FILE}'
output_dir = '${OUTPUT_DIR}'
meta_file = '${TEMP_PROMPT}.meta'

with open(result_file) as f:
    result = json.load(f)

# Load meta for ordered modules
ordered_modules = []
if os.path.exists(meta_file):
    with open(meta_file) as mf:
        meta = json.load(mf)
        ordered_modules = meta.get('ordered_modules', [])

files = result.get('files', [])
modules_processed = result.get('modules_processed', ordered_modules)

print(f"  Modules: {', '.join([m.split('-')[-1] for m in modules_processed])}")
print(f"  Files modified: {len(files)}")

written = 0
for file_info in files:
    path = file_info.get('path', '')
    content = file_info.get('content', '')
    transformations = file_info.get('transformations', [])
    
    if not path or not content:
        continue
    
    # Resolve full path
    full_path = os.path.join(output_dir, path)
    
    # Ensure directory exists
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    
    # Normalize trailing newline (reproducibility)
    normalized_content = content.rstrip() + '\n'
    
    # Write (overwrite existing)
    with open(full_path, 'w') as f:
        f.write(normalized_content)
    
    written += 1
    xforms = ', '.join(transformations) if transformations else 'modified'
    print(f"    ✓ {path} [{xforms}]")

# Enrich result with execution metadata
result['execution_order'] = ordered_modules
result['files_written'] = written

with open(result_file, 'w') as f:
    json.dump(result, f, indent=2)

print(f"\n  Total: {written} files written")
EXTRACT_AND_WRITE

    # Cleanup meta file
    rm -f "${TEMP_PROMPT}.meta"

else
    echo "✗ Invalid JSON"
    echo ""
    echo "First 100 lines of output:"
    head -100 "${RESULT_FILE}"
    rm -f "${TEMP_PROMPT}.meta"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "Result: ${RESULT_FILE}"
echo "═══════════════════════════════════════════════════════════════"
