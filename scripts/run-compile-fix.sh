#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# run-compile-fix.sh — Compilation Gate with LLM Fix Loop
# ═══════════════════════════════════════════════════════════════════════════════
# ODEC-023: Autonomous compile-fix cycle invoked after each generation/transform
#           subphase. Runs mvn compile + test, and if failures occur, sends
#           errors to LLM for correction (max 3 iterations).
#
# Usage:
#   ./run-compile-fix.sh <subphase_id> <output_dir> <context_file> <kb_dir>
#
# Exit codes:
#   0 = compilation + tests pass
#   1 = still failing after max iterations
#   2 = usage/setup error
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Arguments ────────────────────────────────────────────────────────────────

SUBPHASE_ID="${1:?Usage: $0 <subphase_id> <output_dir> <context_file> <kb_dir>}"
OUTPUT_DIR="$(cd "${2:?Missing output_dir}" && pwd)"  # Convert to absolute path
CONTEXT_FILE="$(cd "$(dirname "${3:?Missing context_file}")" && pwd)/$(basename "$3")"
KB_DIR="$(cd "${4:?Missing kb_dir}" && pwd)"

MAX_ITERATIONS=3
TRACE_DIR="${OUTPUT_DIR}/.trace"

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  COMPILATION GATE — Subphase ${SUBPHASE_ID}"
echo "  └─────────────────────────────────────────────────────────────┘"

# ─── Verify pom.xml exists ────────────────────────────────────────────────────

if [ ! -f "${OUTPUT_DIR}/pom.xml" ]; then
    echo "  ⚠ No pom.xml found — skipping compilation gate"
    echo "  (pom.xml is generated in Phase 1, subsequent phases inherit it)"
    exit 0
fi

# ─── Verify Maven is available ────────────────────────────────────────────────

if ! command -v mvn &>/dev/null; then
    echo "  ⚠ Maven not available — skipping compilation gate"
    exit 0
fi

# ─── Load style file for fix context (DEC-042) ───────────────────────────────

STACK=$(python3 -c "import json; print(json.load(open('${CONTEXT_FILE}')).get('stack', 'java-spring'))" 2>/dev/null || echo "java-spring")
STACK=$(echo "$STACK" | sed 's/java-springboot/java-spring/; s/springboot/java-spring/')
STYLE_FILE="${KB_DIR}/runtime/codegen/styles/${STACK}.style.md"
STYLE_CONTENT=""
if [ -f "${STYLE_FILE}" ]; then
    STYLE_CONTENT=$(cat "${STYLE_FILE}")
fi

# ─── Compile + Test function ──────────────────────────────────────────────────

run_compile_test() {
    local iteration=$1
    local log_file="${TRACE_DIR}/compile-${SUBPHASE_ID}-iter${iteration}.log"

    cd "${OUTPUT_DIR}"

    # Run compile + test, capture output
    mvn clean compile test 2>&1 | tee "${log_file}" > /dev/null 2>&1 || true

    # Check result from log
    if grep -q "BUILD SUCCESS" "${log_file}"; then
        return 0
    else
        return 1
    fi
}

# ─── Extract errors from Maven log ───────────────────────────────────────────
# (Inline in main loop — no separate function needed)

# ─── Read source files that have errors ───────────────────────────────────────

collect_error_files() {
    local log_file=$1

    python3 /dev/stdin "${log_file}" "${OUTPUT_DIR}" << 'COLLECT'
import re
import os
import sys
import json

log_file = sys.argv[1]
output_dir = sys.argv[2]

with open(log_file, 'r') as f:
    content = f.read()

# Find all Java files mentioned in errors
error_files = set()
for match in re.finditer(r'/([^\s]+\.java)', content):
    filepath = match.group(1)
    filename = filepath.split('/')[-1]
    error_files.add(filename)

# Find and read those files from output_dir
file_contents = {}
for root, dirs, files in os.walk(output_dir):
    for fname in files:
        if fname in error_files and fname.endswith('.java'):
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, output_dir)
            with open(fpath, 'r') as f:
                file_contents[rel] = f.read()

# Output as JSON
print(json.dumps(file_contents, indent=2))
COLLECT
}

# ─── LLM Fix Call ─────────────────────────────────────────────────────────────

call_llm_fix() {
    local iteration=$1
    local errors=$2
    local error_files_json=$3

    local prompt_file="${TRACE_DIR}/compile-fix-prompt-${SUBPHASE_ID}-iter${iteration}.txt"
    local response_file="${TRACE_DIR}/compile-fix-response-${SUBPHASE_ID}-iter${iteration}.json"

    # Build the fix prompt
    cat > "${prompt_file}" << PROMPT_HEADER
You are a compilation fix agent for a Java/Spring Boot project.

## YOUR TASK

Fix the compilation and test errors below. Return ONLY the corrected files as a JSON array.

## COMPILATION ERRORS

${errors}

## FILES WITH ERRORS (current content)

${error_files_json}

PROMPT_HEADER

    # Add style rules if available
    if [ -n "${STYLE_CONTENT}" ]; then
        cat >> "${prompt_file}" << STYLE_SECTION

## CODE STYLE RULES (MUST follow)

${STYLE_CONTENT}

STYLE_SECTION
    fi

    # Add fix instructions
    cat >> "${prompt_file}" << 'FIX_INSTRUCTIONS'

## CRITICAL RULES

1. Fix ONLY the errors listed above. Do NOT refactor or change working code.
2. If a type/class/enum is referenced but does not exist, CREATE the missing file.
3. If a class is missing an import, add the specific import needed.
4. If a type mismatch exists, fix the type to match what the rest of the code expects.
5. Do NOT rename classes, methods, or fields.
6. Follow the package structure pattern from existing files.
7. Follow the Code Style Rules above if provided.

## RESPONSE FORMAT

Respond with ONLY a JSON array. No markdown, no explanation, no text before or after:

[
  {
    "path": "src/main/java/com/bank/customer/domain/model/Customer.java",
    "content": "package com.bank.customer...\n... full file content ..."
  }
]

You can include:
- Modified files (with corrections)
- NEW files (if a missing class/enum/interface needs to be created)

Do NOT include unchanged files.
FIX_INSTRUCTIONS

    # Call Claude via Claude Code CLI
    if ! cat "${prompt_file}" | claude -p --tools "" > "${response_file}" 2>/dev/null; then
        echo "FIX_ERROR: Claude execution failed"
        return 1
    fi

    # Parse response and apply fixes
    python3 /dev/stdin "${response_file}" "${OUTPUT_DIR}" << 'APPLY_FIX'
import json
import sys
import re
import os

response_file = sys.argv[1]
output_dir = sys.argv[2]

try:
    with open(response_file, 'r') as f:
        text = f.read()

    # Strategy 1: Try to find JSON array in text (handles text before/after JSON)
    # Look for [ ... ] pattern that spans multiple lines
    json_match = re.search(r'\[\s*\{.*?\}\s*\]', text, re.DOTALL)
    
    if json_match:
        json_text = json_match.group(0)
    else:
        # Strategy 2: Clean markdown fences and try full text
        json_text = re.sub(r'```json?\s*\n?', '', text)
        json_text = re.sub(r'\n?```', '', json_text)
        json_text = json_text.strip()

    # Parse the fix array
    fixes = json.loads(json_text)

    applied = 0
    created = 0
    for fix in fixes:
        path = fix.get('path', '')
        content = fix.get('content', '')
        if not path or not content:
            continue

        full_path = os.path.join(output_dir, path)
        
        # Normalize trailing newline
        if not content.endswith('\n'):
            content += '\n'
        
        # Create parent directories if needed
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        
        is_new = not os.path.exists(full_path)
        with open(full_path, 'w') as f:
            f.write(content)
        
        if is_new:
            created += 1
            print(f"CREATED: {path}")
        else:
            applied += 1
            print(f"FIXED: {path}")

    print(f"TOTAL_FIXED: {applied}")
    print(f"TOTAL_CREATED: {created}")

except Exception as e:
    print(f"FIX_ERROR: {e}")
    sys.exit(1)
APPLY_FIX
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN: Compile-Fix Loop
# ═══════════════════════════════════════════════════════════════════════════════

mkdir -p "${TRACE_DIR}"

for iteration in $(seq 1 $((MAX_ITERATIONS + 1))); do

    if [ "$iteration" -gt "$MAX_ITERATIONS" ]; then
        # Final attempt — just compile to report status
        echo "  ✗ Max iterations (${MAX_ITERATIONS}) reached — compilation still failing"
        echo "  See traces: .trace/compile-${SUBPHASE_ID}-iter*.log"
        exit 1
    fi

    if [ "$iteration" -eq 1 ]; then
        echo "  Compiling (initial)..."
    else
        echo "  Compiling (after fix iteration $((iteration - 1)))..."
    fi

    # Run compile + test
    log_file="${TRACE_DIR}/compile-${SUBPHASE_ID}-iter${iteration}.log"
    cd "${OUTPUT_DIR}"
    mvn clean compile test > "${log_file}" 2>&1 || true
    cd - > /dev/null

    # Check result
    if grep -q "BUILD SUCCESS" "${log_file}"; then
        if [ "$iteration" -eq 1 ]; then
            echo "  ✓ BUILD SUCCESS (clean pass)"
        else
            echo "  ✓ BUILD SUCCESS (fixed in iteration $((iteration - 1)))"
        fi
        # Record result in trace
        echo "{\"subphase\": \"${SUBPHASE_ID}\", \"status\": \"pass\", \"iterations\": $((iteration - 1))}" \
            > "${TRACE_DIR}/compile-gate-${SUBPHASE_ID}.json"
        exit 0
    fi

    # Extract errors
    echo "  ✗ BUILD FAILURE — extracting errors..."
    errors=$(python3 /dev/stdin "${log_file}" << 'EXTRACT'
import re
import sys

with open(sys.argv[1], 'r') as f:
    content = f.read()

errors = []
for match in re.finditer(r'\[ERROR\]\s+(/[^\s]+\.java):\[(\d+),(\d+)\]\s+(.*)', content):
    filepath, line, col, message = match.groups()
    filename = filepath.split('/')[-1]
    errors.append(f"{filename}:{line} — {message}")
for match in re.finditer(r'\[ERROR\].*cannot find symbol.*', content):
    errors.append(match.group(0).strip())
for match in re.finditer(r'\[ERROR\].*package .* does not exist.*', content):
    errors.append(match.group(0).strip())

seen = set()
for e in errors:
    if e not in seen:
        seen.add(e)
        print(e)
EXTRACT
    )

    error_count=$(echo "${errors}" | wc -l)
    echo "  Found ${error_count} error(s)"

    # Collect files with errors
    error_files_json=$(collect_error_files "${log_file}")

    # Call LLM to fix
    echo "  Requesting LLM fix (iteration ${iteration}/${MAX_ITERATIONS})..."

    fix_output=$(call_llm_fix "${iteration}" "${errors}" "${error_files_json}")

    # Count fixes applied
    fixed_count=$(echo "${fix_output}" | grep "^FIXED:" | wc -l)
    fix_error=$(echo "${fix_output}" | grep "^FIX_ERROR:" || true)

    if [ -n "${fix_error}" ]; then
        echo "  ⚠ Fix failed: ${fix_error}"
        # Continue to next iteration anyway — maybe partial fix helps
    elif [ "${fixed_count}" -eq 0 ]; then
        echo "  ⚠ LLM returned no fixes"
    else
        echo "  Applied ${fixed_count} fix(es)"
        echo "${fix_output}" | grep "^FIXED:" | sed 's/^/    /'
    fi

done
