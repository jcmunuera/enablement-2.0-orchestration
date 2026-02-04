# Context Agent

## Purpose
Extracts template variables from specifications for code generation.

## Execution
```bash
./scripts/run-context.sh <inputs_dir> <discovery_file> [output_file]
```

## Inputs
- Discovery result JSON (required)
- `prompt.md` - User requirements
- `domain-api-spec.yaml` - OpenAPI spec for domain API
- `system-api-*.yaml` - OpenAPI specs for backend APIs
- `mapping.json` - Field mapping configuration

## Output Schema
```json
{
  "version": "1.0",
  "timestamp": "ISO-8601",
  "agent": "context",
  "service": {
    "name": "service name",
    "basePackage": "base package",
    "artifactId": "artifact id",
    "groupId": "group id"
  },
  "domain": {
    "entityName": "PascalCase",
    "entityNameLower": "lowercase",
    "entityNamePlural": "plural",
    "idType": "String",
    "fields": [
      {
        "name": "field name",
        "type": "schema name for $ref, else OpenAPI type",
        "required": true|false,
        "format": null|"uuid"|"email"|"date"|"date-time"
      }
    ]
  },
  "api": {
    "basePath": "from OpenAPI",
    "endpoints": [...]
  },
  "systemApi": {
    "name": "API title",
    "baseUrl": "from servers",
    "endpoints": [...]
  },
  "mapping": {
    "domainToSystem": [...],
    "systemToDomain": [...],
    "errorMapping": [...]
  },
  "resilience": {
    "circuitBreaker": {...},
    "retry": {...},
    "timeout": {...}
  },
  "modules": ["module ids from discovery"]
}
```

## Determinism Rules
1. For field types: if $ref, use REFERENCED SCHEMA NAME (e.g., "CustomerStatus")
2. For paths: copy EXACTLY from OpenAPI - never modify
3. Maintain array ordering from source documents
4. modules array must match discovery result order
