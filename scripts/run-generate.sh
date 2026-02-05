#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# CODE GENERATION ORCHESTRATOR - Enablement 2.0
# ═══════════════════════════════════════════════════════════════════════════
# Generates code from templates for all subphases in execution plan.
# Produces a validatable project directory.
#
# Usage:
#   ./run-generate.sh <execution_plan> <generation_context> <output_dir>
#
# Output Structure:
#   output_dir/
#   ├── src/main/java/...           # Generated source files
#   ├── src/main/resources/...      # Config files
#   ├── src/test/java/...           # Generated tests
#   ├── pom.xml                     # Maven config
#   ├── .enablement/
#   │   └── manifest.json           # Generation metadata
#   ├── .trace/                     # Generation trace (for debugging)
#   │   ├── codegen-result-*.json
#   │   └── generation-summary.json
#   └── validation/                 # Validation scripts (from KB)
#       ├── run-all.sh
#       └── scripts/tier{1,2,3}/
#
# In orchestrated mode, the orchestrator moves artifacts to final structure.
# In manual mode, this output is directly usable and validatable.
# ═══════════════════════════════════════════════════════════════════════════
set -e

PLAN_FILE="${1:-}"
CONTEXT_FILE="${2:-}"
OUTPUT_DIR="${3:-./generated}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DIR="${KB_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)/enablement-2.0-kb}"

# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${PLAN_FILE}" ] || [ -z "${CONTEXT_FILE}" ]; then
    echo "Usage: $0 <execution_plan> <generation_context> [output_dir]"
    echo ""
    echo "Example:"
    echo "  $0 execution-plan.json generation-context.json ./generated"
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

# ─────────────────────────────────────────────────────────────────────────────
# Extract plan info
# ─────────────────────────────────────────────────────────────────────────────
SERVICE_NAME=$(python3 -c "import json; print(json.load(open('${PLAN_FILE}'))['service_name'])")
TOTAL_SUBPHASES=$(python3 -c "import json; print(json.load(open('${PLAN_FILE}'))['total_subphases'])")

echo "═══════════════════════════════════════════════════════════════════════════"
echo "  CODE GENERATION"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Service:       ${SERVICE_NAME}"
echo "Subphases:     ${TOTAL_SUBPHASES}"
echo "Output:        ${OUTPUT_DIR}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Create output structure
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}/src/main/java"
mkdir -p "${OUTPUT_DIR}/src/main/resources"
mkdir -p "${OUTPUT_DIR}/src/test/java"
mkdir -p "${OUTPUT_DIR}/.enablement"
mkdir -p "${OUTPUT_DIR}/.trace"
mkdir -p "${OUTPUT_DIR}/validation/scripts/tier1"
mkdir -p "${OUTPUT_DIR}/validation/scripts/tier2"
mkdir -p "${OUTPUT_DIR}/validation/scripts/tier3"
mkdir -p "${OUTPUT_DIR}/validation/reports"

# ─────────────────────────────────────────────────────────────────────────────
# Copy validation scripts from KB (DEC-033)
# ─────────────────────────────────────────────────────────────────────────────
echo "Assembling validation scripts from KB..."
VALIDATORS_DIR="${KB_DIR}/runtime/validators"

# Tier 1 - Universal validations (scripts are in nested subdirs)
if [ -d "${VALIDATORS_DIR}/tier-1-universal" ]; then
    find "${VALIDATORS_DIR}/tier-1-universal" -name "*.sh" ! -name "._*" -exec cp {} "${OUTPUT_DIR}/validation/scripts/tier1/" \;
    TIER1_COUNT=$(ls "${OUTPUT_DIR}/validation/scripts/tier1/"*.sh 2>/dev/null | wc -l)
    echo "  ✓ Tier 1: ${TIER1_COUNT} scripts copied"
fi

# Tier 2 - Technology validations (java-spring, nested under code-projects/)
if [ -d "${VALIDATORS_DIR}/tier-2-technology" ]; then
    find "${VALIDATORS_DIR}/tier-2-technology/code-projects/java-spring" -name "*.sh" ! -name "._*" -exec cp {} "${OUTPUT_DIR}/validation/scripts/tier2/" \; 2>/dev/null || true
    TIER2_COUNT=$(ls "${OUTPUT_DIR}/validation/scripts/tier2/"*.sh 2>/dev/null | wc -l)
    echo "  ✓ Tier 2: ${TIER2_COUNT} scripts copied"
fi

# Tier 3 - Module-specific validations
python3 << COPY_TIER3
import json
import shutil
import os

plan_file = '${PLAN_FILE}'
kb_dir = '${KB_DIR}'
tier3_dir = '${OUTPUT_DIR}/validation/scripts/tier3'

with open(plan_file) as f:
    plan = json.load(f)

modules_copied = set()
count = 0
for phase in plan.get('phases', []):
    for subphase in phase.get('subphases', []):
        for module in subphase.get('modules', []):
            module_id = module['module_id']
            if module_id in modules_copied:
                continue
            
            validation_dir = os.path.join(kb_dir, 'modules', module_id, 'validation')
            if os.path.isdir(validation_dir):
                for script in os.listdir(validation_dir):
                    if script.endswith('.sh'):
                        src = os.path.join(validation_dir, script)
                        dst = os.path.join(tier3_dir, f"{module_id}_{script}")
                        shutil.copy(src, dst)
                        count += 1
            modules_copied.add(module_id)

if count > 0:
    print(f"  ✓ Tier 3 scripts copied ({count} files)")
else:
    print(f"  - No Tier 3 scripts found")
COPY_TIER3

# Create run-all.sh
cat > "${OUTPUT_DIR}/validation/run-all.sh" << 'RUNALL'
#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Validation Suite - Enablement 2.0
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "═══════════════════════════════════════════════════════════════"
echo "  VALIDATION SUITE"
echo "═══════════════════════════════════════════════════════════════"
echo "Project: ${PROJECT_DIR}"
echo ""

PASSED=0
FAILED=0
SKIPPED=0

run_tier() {
    local tier=$1
    local tier_dir="${SCRIPT_DIR}/scripts/${tier}"
    local tier_upper=$(echo "$tier" | tr '[:lower:]' '[:upper:]')
    
    # Check for real .sh scripts (exclude macOS ._ resource forks)
    local real_scripts=$(find "${tier_dir}" -maxdepth 1 -name "*.sh" ! -name "._*" 2>/dev/null | head -1)
    
    if [ ! -d "${tier_dir}" ] || [ -z "${real_scripts}" ]; then
        echo "  ${tier}: (no scripts)"
        return
    fi
    
    echo ""
    echo "─── ${tier_upper} ───"
    
    for script in "${tier_dir}"/*.sh; do
        [ -f "$script" ] || continue
        script_name=$(basename "$script")
        # Skip macOS resource fork files
        [[ "$script_name" == ._* ]] && continue
        
        if bash "$script" "${PROJECT_DIR}" > /dev/null 2>&1; then
            echo "  ✓ ${script_name}"
            PASSED=$((PASSED + 1))
        else
            echo "  ✗ ${script_name}"
            FAILED=$((FAILED + 1))
        fi
    done
}

# Run all tiers
for tier in tier1 tier2 tier3; do
    run_tier "$tier"
done

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: ${PASSED} passed, ${FAILED} failed"
if [ $FAILED -eq 0 ]; then
    echo "  ✓ All validations passed"
    exit 0
else
    echo "  ✗ Some validations failed"
    exit 1
fi
RUNALL

chmod +x "${OUTPUT_DIR}/validation/run-all.sh"
chmod +x "${OUTPUT_DIR}/validation/scripts"/*/*.sh 2>/dev/null || true

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Process subphases
# ─────────────────────────────────────────────────────────────────────────────
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 << PROCESS_PHASES
import json
import subprocess
import sys
import os

plan_file = '${PLAN_FILE}'
context_file = '${CONTEXT_FILE}'
output_dir = '${OUTPUT_DIR}'
script_dir = '${SCRIPT_DIR}'
kb_dir = '${KB_DIR}'

with open(plan_file) as f:
    plan = json.load(f)

results = []
modules_used = []
total_files = 0
failed = 0

for phase in plan.get('phases', []):
    phase_num = phase['phase']
    phase_name = phase['name']
    subphases = phase.get('subphases', [])
    
    print(f"\n{'─' * 75}")
    print(f"  PHASE {phase_num}: {phase_name.upper()}")
    print(f"  Subphases: {len(subphases)}")
    print(f"{'─' * 75}")
    
    for subphase in subphases:
        subphase_id = subphase['id']
        subphase_name = subphase['name']
        action = subphase['action']
        modules = subphase['modules']
        module_ids = [m['module_id'] for m in modules]
        
        print(f"\n  Subphase {subphase_id}: {subphase_name}")
        print(f"  Action:  {action}")
        print(f"  Modules: {len(modules)} ({', '.join([m.split('-')[-1] for m in module_ids])})")
        
        if action == 'generate':
            script = os.path.join(script_dir, 'run-codegen.sh')
        elif action == 'transform':
            script = os.path.join(script_dir, 'run-transform.sh')
            if not os.path.exists(script):
                print(f"  ⚠ Transform agent not implemented - skipping")
                results.append({
                    'subphase_id': subphase_id,
                    'status': 'skipped',
                    'reason': 'Transform agent not implemented'
                })
                continue
        else:
            print(f"  ✗ Unknown action: {action}")
            failed += 1
            continue
        
        # Execute the agent
        try:
            cmd = [script, subphase_id, plan_file, context_file, output_dir]
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode == 0:
                # Move trace to .trace/
                result_file_src = os.path.join(output_dir, f'codegen-result-{subphase_id}.json')
                result_file_dst = os.path.join(output_dir, '.trace', f'codegen-result-{subphase_id}.json')
                
                if os.path.exists(result_file_src):
                    os.rename(result_file_src, result_file_dst)
                    with open(result_file_dst) as rf:
                        subphase_result = json.load(rf)
                        file_count = len(subphase_result.get('files', []))
                        total_files += file_count
                        
                        # Track modules
                        for m in modules:
                            modules_used.append({
                                'id': m['module_id'],
                                'capability': m['capability_id'],
                                'phase': phase_num
                            })
                        
                        print(f"  ✓ Generated {file_count} files")
                        
                        # ODEC-018 Step 2b: Extract phase catalog for inter-phase coherence
                        catalog_file = os.path.join(output_dir, '.trace', f'phase-catalog-{subphase_id}.json')
                        try:
                            catalog_classes = []
                            
                            # Get list of files generated by THIS subphase from result JSON
                            this_subphase_files = set()
                            result_json = os.path.join(output_dir, '.trace', f'codegen-result-{subphase_id}.json')
                            if os.path.exists(result_json):
                                with open(result_json) as rj:
                                    res = json.load(rj)
                                for fi in res.get('files', []):
                                    op = fi.get('output_path', '')
                                    if op:
                                        # Normalize to just the filename
                                        this_subphase_files.add(os.path.basename(op))
                            
                            # Scan all .java files in output_dir
                            for root, dirs, fnames in os.walk(output_dir):
                                for fname in sorted(fnames):
                                    if not fname.endswith('.java'):
                                        continue
                                    # Only catalog files from THIS subphase
                                    if this_subphase_files and fname not in this_subphase_files:
                                        continue
                                    fpath = os.path.join(root, fname)
                                    rel = os.path.relpath(fpath, output_dir)
                                    # Skip test files for catalog
                                    if '/test/' in rel:
                                        continue
                                    pkg = ''
                                    kind = 'class'
                                    simple_name = fname.replace('.java', '')
                                    with open(fpath, 'r') as jf:
                                        for line in jf:
                                            line = line.strip()
                                            if line.startswith('package '):
                                                pkg = line.replace('package ', '').rstrip(';').strip()
                                            # Match: public (class|interface|enum|record) Name
                                            if line.startswith('public '):
                                                for k in ['interface', 'enum', 'record', 'abstract class', 'class']:
                                                    marker = f'public {k} '
                                                    if marker in line:
                                                        kind = k.replace('abstract ', 'abstract_')
                                                        # Extract name (before extends/implements/{/()
                                                        after = line.split(marker)[1]
                                                        simple_name = after.split()[0].split('<')[0].split('{')[0].split('(')[0].strip()
                                                        break
                                            # Stop after finding class declaration
                                            if pkg and kind and line.startswith('public '):
                                                break
                                    if pkg and simple_name:
                                        catalog_classes.append({
                                            'fqcn': f'{pkg}.{simple_name}',
                                            'simple_name': simple_name,
                                            'kind': kind,
                                            'package': pkg,
                                            'source_subphase': subphase_id
                                        })
                            
                            catalog = {
                                'subphase': subphase_id,
                                'phase': phase_num,
                                'classes': catalog_classes
                            }
                            with open(catalog_file, 'w') as cf:
                                json.dump(catalog, cf, indent=2)
                            print(f"  ✓ Catalog: {len(catalog_classes)} classes indexed")
                        except Exception as e:
                            print(f"  ⚠ Catalog extraction failed: {e}")
                        
                        # ─── ODEC-020: Validate template manifest ─────────────────────
                        manifest_file = os.path.join(output_dir, '.trace', f'template-manifest-{subphase_id}.json')
                        if os.path.exists(manifest_file):
                            try:
                                with open(manifest_file) as mf:
                                    manifest = json.load(mf)
                                expected_files = {t['output'].split('/')[-1] for t in manifest.get('templates', [])}
                                generated_files = this_subphase_files
                                missing = expected_files - generated_files
                                if missing:
                                    print(f"  ⚠ Missing from manifest: {', '.join(sorted(missing))}")
                                else:
                                    print(f"  ✓ Manifest: all {len(expected_files)} templates generated")
                            except Exception as e:
                                print(f"  ⚠ Manifest validation failed: {e}")
                        
                        results.append({
                            'subphase_id': subphase_id,
                            'status': 'success',
                            'files': file_count
                        })
                else:
                    print(f"  ✓ Completed")
                    results.append({'subphase_id': subphase_id, 'status': 'success', 'files': 0})
                
                # ─── ODEC-023: Compilation Gate with Fix Loop ─────────────
                compile_script = os.path.join(script_dir, 'run-compile-fix.sh')
                if os.path.exists(compile_script):
                    print(f"\n  ── Compilation Gate ──")
                    compile_cmd = [compile_script, subphase_id, output_dir, context_file, kb_dir]
                    compile_result = subprocess.run(compile_cmd, capture_output=False)
                    if compile_result.returncode != 0:
                        print(f"  ⚠ Compilation gate failed for {subphase_id} — continuing pipeline")
                        # Update result status
                        for r in results:
                            if r['subphase_id'] == subphase_id:
                                r['compile_status'] = 'fail'
                    else:
                        for r in results:
                            if r['subphase_id'] == subphase_id:
                                r['compile_status'] = 'pass'
            else:
                print(f"  ✗ Failed (exit code: {result.returncode})")
                # Save full output to trace for debugging
                trace_file = os.path.join(output_dir, '.trace', f'error-{subphase_id}.log')
                with open(trace_file, 'w') as ef:
                    ef.write(f"=== COMMAND ===\n{' '.join(cmd)}\n\n")
                    ef.write(f"=== EXIT CODE ===\n{result.returncode}\n\n")
                    ef.write(f"=== STDOUT ===\n{result.stdout}\n\n")
                    ef.write(f"=== STDERR ===\n{result.stderr}\n")
                # Show last meaningful lines
                stdout_lines = [l for l in result.stdout.strip().split('\n') if l.strip()] if result.stdout else []
                stderr_lines = [l for l in result.stderr.strip().split('\n') if l.strip()] if result.stderr else []
                if stderr_lines:
                    for line in stderr_lines[-3:]:
                        print(f"    stderr: {line[:150]}")
                if stdout_lines:
                    for line in stdout_lines[-3:]:
                        print(f"    stdout: {line[:150]}")
                print(f"    Full trace: .trace/error-{subphase_id}.log")
                failed += 1
                results.append({
                    'subphase_id': subphase_id,
                    'status': 'error',
                    'error': result.stderr[:200] if result.stderr else 'Unknown'
                })
        except Exception as e:
            print(f"  ✗ Exception: {e}")
            failed += 1
            results.append({'subphase_id': subphase_id, 'status': 'error', 'error': str(e)})

# Write generation summary to .trace/
summary = {
    'version': '1.0',
    'timestamp': '${START_TIME}',
    'service_name': plan['service_name'],
    'total_subphases': plan.get('total_subphases', 0),
    'total_files': total_files,
    'failed': failed,
    'results': results,
    'modules_used': modules_used
}

with open(f"{output_dir}/.trace/generation-summary.json", 'w') as f:
    json.dump(summary, f, indent=2)

# Print summary
print(f"\n{'═' * 75}")
print(f"  GENERATION COMPLETE")
print(f"{'═' * 75}")
print(f"  Files generated: {total_files}")
print(f"  Failed subphases: {failed}")

sys.exit(1 if failed > 0 else 0)
PROCESS_PHASES

GENERATION_EXIT=$?

# ─────────────────────────────────────────────────────────────────────────────
# Create .enablement/manifest.json
# ─────────────────────────────────────────────────────────────────────────────
python3 << CREATE_MANIFEST
import json
import os
import uuid
from datetime import datetime, timezone

output_dir = '${OUTPUT_DIR}'
plan_file = '${PLAN_FILE}'
service_name = '${SERVICE_NAME}'

# Load summary
summary_file = f"{output_dir}/.trace/generation-summary.json"
with open(summary_file) as f:
    summary = json.load(f)

# Count java files
java_files = 0
test_files = 0
for root, dirs, files in os.walk(output_dir):
    for f in files:
        if f.endswith('.java'):
            if '/test/' in root:
                test_files += 1
            else:
                java_files += 1

manifest = {
    "generation": {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        "service_name": service_name
    },
    "enablement": {
        "version": "3.0.x",
        "domain": "code",
        "flow": "flow-generate"
    },
    "modules": summary.get('modules_used', []),
    "status": {
        "generation": "SUCCESS" if summary['failed'] == 0 else "PARTIAL",
        "validation": "PENDING"
    },
    "metrics": {
        "files_generated": java_files,
        "test_files": test_files
    }
}

with open(f"{output_dir}/.enablement/manifest.json", 'w') as f:
    json.dump(manifest, f, indent=2)
CREATE_MANIFEST

# ─────────────────────────────────────────────────────────────────────────────
# Final output
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "  Output:   ${OUTPUT_DIR}"
echo "  Validate: ${OUTPUT_DIR}/validation/run-all.sh"
echo "═══════════════════════════════════════════════════════════════════════════"

exit ${GENERATION_EXIT}
