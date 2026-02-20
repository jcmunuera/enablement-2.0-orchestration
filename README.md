# Enablement 2.0 - Orchestration

Scripts de orquestación agéntica con prompts embebidos para determinismo.

## Scripts

```
scripts/
├── run-discovery.sh     # Discovery Agent (prompt embebido)
├── run-context.sh       # Context Agent (prompt embebido)
└── test-determinism.sh  # Validador de determinismo
```

## Uso

```bash
# Discovery
./scripts/run-discovery.sh <inputs_dir> [output_file]

# Context (requiere discovery primero)
./scripts/run-context.sh <inputs_dir> <discovery_result> [output_file]

# Test determinismo
./scripts/test-determinism.sh discovery ./inputs 5
./scripts/test-determinism.sh context ./inputs 5
```

## Requisitos

- Claude CLI (`claude --print`)
- Python 3
- Bash

## Nota sobre Determinismo

Los prompts están **embebidos directamente** en los scripts (no en archivos separados).
Esto es intencional - la extracción dinámica de prompts causa variaciones en el output.
