# Orchestration Decision Log (ODEC)

Este documento registra las decisiones de diseño del sistema de orquestación de Enablement 2.0.

**Convención de IDs:** ODEC-NNN (secuencial)

---

## Índice

- [ODEC-001](#odec-001) - Embedded prompts in shell scripts
- [ODEC-009](#odec-009) - Step-by-step CodeGen execution
- [ODEC-011](#odec-011) - Holistic subphase generation
- [ODEC-012](#odec-012) - Plan Agent subphase grouping
- [ODEC-015](#odec-015) - Subphase optimization model
- [ODEC-017](#odec-017) - Maven dependencies via dependencies.yaml
- [ODEC-018](#odec-018) - Inter-Phase Coherence Model
- [ODEC-020](#odec-020) - Template Manifest for Determinism
- [ODEC-021](#odec-021) - Phase 2 Reproducibility Rules

---

## ODEC-001: Embedded Prompts in Shell Scripts {#odec-001}

**Fecha:** 2026-01-29  
**Estado:** ✅ Aprobado

**Contexto:**  
Los agentes (Discovery, Context, Plan, CodeGen) necesitan prompts complejos con instrucciones detalladas.

**Opciones:**
- A) Prompts en archivos externos (.md)
- B) Prompts embebidos como heredocs en shell scripts

**Decisión:** Opción B - Heredocs en shell scripts

**Justificación:**
- Un solo archivo por agente (script = prompt + ejecución)
- Variables de shell se expanden in-place
- Facilita debugging (todo visible en un lugar)
- Sin archivos adicionales que sincronizar

---

## ODEC-009: Step-by-Step CodeGen Execution {#odec-009}

**Fecha:** 2026-01-30  
**Estado:** ✅ Aprobado

**Contexto:**  
CodeGen podría generar todo de una vez o por pasos.

**Decisión:** Generación paso a paso con trazabilidad.

**Justificación:**
- Permite checkpoint y recovery
- Facilita debugging de errores específicos
- Trace files para cada paso

---

## ODEC-011: Holistic Subphase Generation {#odec-011}

**Fecha:** 2026-01-30  
**Estado:** ✅ Aprobado

**Contexto:**  
Dentro de una subphase, ¿se genera módulo por módulo o todos juntos?

**Decisión:** Todos los módulos de una subphase se generan en un solo LLM call.

**Justificación:**
- Consistency: imports, naming, references coherentes
- Eficiencia: una llamada vs N llamadas
- Context sharing: el LLM ve todos los templates relacionados

---

## ODEC-012: Plan Agent Subphase Grouping {#odec-012}

**Fecha:** 2026-01-30  
**Estado:** ✅ Aprobado

**Contexto:**  
¿Cómo agrupar módulos en subphases?

**Decisión:** Máximo 4 módulos por subphase, agrupados por phase y dependencias.

**Justificación:**
- Context window limits (~100K tokens útiles)
- Balance entre coherencia y tamaño de prompt
- Módulos relacionados siempre juntos

---

## ODEC-015: Subphase Optimization Model {#odec-015}

**Fecha:** 2026-01-30  
**Estado:** ✅ Aprobado

**Contexto:**  
El Plan Agent optimiza el grouping de módulos.

**Decisión:** Algoritmo determinista basado en fase, dependencias, y tamaño estimado.

**Justificación:**
- Reproducibilidad: mismo input → mismo plan
- Predictabilidad para debugging

---

## ODEC-017: Maven Dependencies via dependencies.yaml {#odec-017}

**Fecha:** 2026-02-02  
**Estado:** ✅ Implementado

**Contexto:**  
Los módulos tenían `pom-*.xml.tpl` fragments incompatibles con la arquitectura CodeGen. El pom.xml se genera en Phase 1 pero necesita dependencias de módulos de Phase 2 y 3.

**Problema:**
- Fragments XML no se pueden consolidar fácilmente
- CodeGen solo ve templates de su fase actual
- Duplicación de dependencias entre módulos

**Opciones:**
- A) Mantener pom-*.xml.tpl y consolidar en CodeGen
- B) dependencies.yaml por módulo → Context Agent consolida

**Decisión:** Opción B - dependencies.yaml

**Implementación:**
1. Cada módulo define `dependencies.yaml` con sus dependencias
2. Context Agent lee todos los YAML y consolida en `maven_dependencies`
3. CodeGen usa un solo `pom.xml.tpl` que itera sobre `maven_dependencies`

**Archivos modificados:**
- 10 `dependencies.yaml` creados (uno por módulo)
- `run-context.sh`: lectura y consolidación YAML
- `run-codegen.sh`: instrucciones de pom.xml
- `pom.xml.tpl` en mod-015: consume consolidated dependencies

---

## ODEC-018: Inter-Phase Coherence Model {#odec-018}

**Fecha:** 2026-02-02  
**Estado:** ✅ Implementado

**Contexto:**  
La generación por fases (DEC-003) resuelve context window limits pero rompe la coherencia entre fases:
- Phase 1 generaba código de Phase 2 (out-of-scope)
- Phase 2 no conocía los nombres exactos de Phase 1
- Naming inconsistencies: `CustomerDto` vs `CustomerSystemApiResponse`

**El problema existencial:**
```
Phase 1: Genera Customer.java, CustomerRepository.java
         |
         v (no state sharing)
Phase 2: ¿Cómo sabe que debe usar CustomerId, no String?
         ¿Cómo sabe que Customer tiene private constructor?
```

**Opciones evaluadas:**
- A) Generación holística (todo en un call) — No viable (context limits)
- B) Generación aislada (fases independientes) — No viable (incoherencia)
- C) Strict Scoping + Catalog — ELEGIDA

**Decisión:** Opción C - Scope Enforcement + Phase Catalog

**Implementación en 4 pasos:**

### Step 1 — Scope Enforcement (pre-generation)
```python
# Derive allowed paths from templates
allowed_paths = extract_output_paths(templates)
# Inject into prompt
"ALLOWED OUTPUT PATHS: {allowed_paths}
 REJECT files outside these paths"
```

### Step 2a — Scope Validation (post-generation)
```python
for file in generated_files:
    if not matches_any(file.path, allowed_paths):
        log_warning(f"Out of scope: {file.path}")
        skip_file(file)
```

### Step 2b — Phase Catalog Extraction (post-generation)
```python
catalog = []
for java_file in generated_java_files:
    catalog.append({
        'fqcn': extract_fqcn(java_file),
        'simple_name': extract_class_name(java_file),
        'kind': 'class' | 'interface' | 'record' | 'enum',
        'package': extract_package(java_file)
    })
save_json(f'phase-catalog-{subphase_id}.json', catalog)
```

### Step 2c — Catalog Injection (pre-generation)
```python
prior_catalogs = load_catalogs(subphases_before_current)
inject_into_prompt(f"""
<prior_phases_catalog>
IMPORTANT CONSTRUCTION RULES:
- Domain entities have PRIVATE constructors, NO setters.
  Use Entity.reconstitute(...) for instances from persistence.
- Repository interfaces use EntityId (value object), NOT String.

Phase 1.1:
  - com.bank.customer.domain.model.Customer (class) [PRIVATE constructor]
  - com.bank.customer.domain.model.CustomerId (record)
  - com.bank.customer.domain.repository.CustomerRepository (interface) [uses EntityId]
</prior_phases_catalog>
""")
```

**Archivos modificados:**
- `run-codegen.sh`: Steps 1, 2c (scope + catalog injection)
- `run-generate.sh`: Steps 2a, 2b (validation + extraction)

**Resultados:**
| Metric | Before ODEC-018 | After ODEC-018 |
|--------|-----------------|----------------|
| Out-of-scope files | 9 | 0 |
| Compilation errors | 30 | 0* |
| Naming inconsistencies | Many | 0 |

*After template fixes (KB tar 11)

---

## Pending Decisions

### ODEC-018 Step 3: Compilation Gate (not yet implemented)

**Propuesta:**
```bash
# After each phase completes
mvn compile -f ${OUTPUT_DIR}/pom.xml
if [ $? -ne 0 ]; then
    echo "Phase ${phase} compilation failed"
    exit 1
fi
```

**Status:** Diseñado, pendiente implementación.

---

### ODEC-019: Static Template Lint (proposed)

**Problema:** Template bugs caused 80% of compilation errors. LLM faithfully executes broken templates.

**Propuesta:** Pre-generation validation script that:
1. Parses all `.tpl` files in selected modules
2. Extracts output declarations and imports
3. Validates cross-module references
4. Reports inconsistencies before any LLM call

**Status:** Propuesto, no implementado.

---

## ODEC-020: Template Manifest for Determinism {#odec-020}

**Fecha:** 2026-02-03  
**Estado:** ✅ Implementado

**Contexto:**  
En pruebas de reproducibilidad (2026-02-02), el LLM no generó `CustomerControllerHateoasTest.java` en 1 de 3 runs, aunque el template existe. El prompt decía "Include ALL templates" pero esto es texto que el LLM puede ignorar.

**Problema:**
- Varianza del 33% en generación de tests
- Prompt instructivo no es suficientemente determinista
- No hay validación de que todos los templates fueron procesados

**Solución:**
Generar un **manifest explícito** de templates que el LLM DEBE generar:

1. **Pre-generación (run-codegen.sh):**
   - Construir lista de todos los templates con sus output paths resueltos
   - Inyectar manifest como tabla Markdown en el prompt
   - Guardar manifest en `.trace/template-manifest-{subphase}.json`

2. **Post-generación (run-generate.sh):**
   - Comparar archivos generados contra manifest
   - Reportar warning si falta algún archivo

**Ejemplo de manifest en prompt:**
```
## MANDATORY TEMPLATE MANIFEST (ODEC-020)

You MUST generate ALL of the following files. This is a COMPLETE list.
DO NOT skip any template.

| Module | Template | Expected Output |
|--------|----------|----------------|
| 019-... | test/ControllerTest-hateoas.java.tpl | ...CustomerControllerHateoasTest.java |
| ... | ... | ... |

**Total: 25 files MUST be generated.**
```

**Archivos modificados:**
- `run-codegen.sh`: Build and inject manifest, save to trace
- `run-generate.sh`: Validate generated files against manifest

**Resultado esperado:**
- 100% de templates generados en cada run
- Warning visible si falta algún archivo
- Determinismo completo en la generación

---

## ODEC-021: Phase 2 Reproducibility Rules {#odec-021}

**Fecha:** 2026-02-03  
**Estado:** ✅ Implementado

**Contexto:**  
Análisis de 3 runs E2E mostró variaciones cosméticas en Phase 2:

| Variación | Ejemplo | Impacto |
|-----------|---------|---------|
| Trailing newlines | Run06 sin `\n` final | Cosmético |
| Helper methods | `toUppercase()` vs inline null checks | Estructural |
| Unicode en comentarios | `↔` vs `<->` | Cosmético |

**Decisión:** Implementar tres mejoras:

### 1. Post-Procesado de Newlines
```python
# En run-codegen.sh, al escribir archivos
normalized_content = content.rstrip() + '\n'
```

### 2. Reglas de Estilo en Prompt
```markdown
## CRITICAL: Code Style Consistency

### Helper Methods Style
- ALWAYS create private helper methods for null-safe transformations
- Use EXACT names: toUpperCase(), toLowerCase(), toProperCase()
- Do NOT inline null checks in method calls

### ASCII Only in Comments
- Use <-> for bidirectional arrows, NOT ↔
- Use -> for single direction, NOT →
```

### 3. Templates ASCII-Only (KB side)
- Reemplazados todos los Unicode arrows en templates
- `↔` -> `<->`
- `→` -> `->`

**Archivos modificados:**
- `run-codegen.sh`: Normalización de newlines + reglas de estilo
- KB templates: Unicode -> ASCII

**Resultado esperado:**
- Trailing newlines: 100% consistente
- Helper methods: 100% consistente
- Comentarios: 100% ASCII

---

## Pending Decisions
