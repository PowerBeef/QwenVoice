```markdown
# QwenVoice Development Patterns

> Auto-generated skill from repository analysis

## Overview

This skill teaches the core development patterns and workflows for the QwenVoice TypeScript codebase. It covers coding conventions, file organization, import/export styles, and the main project maintenance workflows, including how to update operating guides and enforcement scripts. The guide is intended for contributors seeking to maintain consistency and follow best practices within the QwenVoice repository.

## Coding Conventions

### File Naming

- Use **camelCase** for file names.
  - Example: `audioProcessor.ts`, `voiceSynthesizer.test.ts`

### Import Style

- Use **relative imports** for internal modules.
  - Example:
    ```typescript
    import { processAudio } from './audioProcessor';
    ```

### Export Style

- Use **named exports** for all modules.
  - Example:
    ```typescript
    // audioProcessor.ts
    export function processAudio(input: Buffer): Buffer { ... }
    ```

### Commit Patterns

- Commit messages are **freeform** (no enforced prefix).
- Average commit message length: ~53 characters.

## Workflows

### Operating Guide Replacement & Update

**Trigger:** When the main project operating guide is replaced or renamed (e.g., `AGENTS.md` → `CLAUDE.md`).

**Command:** `/replace-operating-guide`

**Step-by-step:**

1. **Create or expand the new operating guide file**  
   - Example: Add or update `CLAUDE.md` with the latest content, merging or rewriting as needed.
2. **Delete or deprecate the old guide**  
   - Example: Remove `AGENTS.md` from the repository.
3. **Update all documentation references**  
   - Search for all references to the old guide in documentation files (e.g., `docs/README.md`, `docs/qwen_tone.md`, etc.) and update them to point to the new guide.
   - Example:
     ```diff
     - See AGENTS.md for the operating guide.
     + See CLAUDE.md for the operating guide.
     ```
4. **Update enforcement scripts**  
   - Modify scripts like `scripts/check_project_inputs.sh` to allow or disallow references to the new/old guide as appropriate.
   - Example:
     ```bash
     # In scripts/check_project_inputs.sh
     PROHIBITED_REFERENCE_PATTERNS=("AGENTS.md")
     # Update to:
     PROHIBITED_REFERENCE_PATTERNS=("CLAUDE.md")
     ```

**Files Involved:**
- `CLAUDE.md`
- `AGENTS.md`
- `docs/README.md`
- `docs/qwen_tone.md`
- `docs/reference/current-state.md`
- `docs/reference/backend-freeze-gate.md`
- `docs/reference/frontend-backend-contract.md`
- `scripts/check_project_inputs.sh`

---

### Enforcement Script Reference Update

**Trigger:** When the set of allowed or prohibited references in the codebase changes (e.g., after adding or renaming a guide).

**Command:** `/update-reference-enforcement`

**Step-by-step:**

1. **Modify enforcement scripts**
   - Edit `scripts/check_project_inputs.sh` to update `PROHIBITED_REFERENCE_PATTERNS` or similar logic to reflect the new set of allowed/banned references.
   - Example:
     ```bash
     # Allow references to CLAUDE.md, ban AGENTS.md
     PROHIBITED_REFERENCE_PATTERNS=("AGENTS.md")
     ```
2. **Test enforcement**
   - Run the script and verify that the intended references are correctly allowed or banned.
   - Example:
     ```bash
     bash scripts/check_project_inputs.sh
     ```

**Files Involved:**
- `scripts/check_project_inputs.sh`

---

## Testing Patterns

- **Test files** follow the pattern: `*.test.*`
  - Example: `voiceSynthesizer.test.ts`
- **Testing framework:** Not explicitly detected; check test files for framework usage.
- **Test organization:** Tests are colocated with source files or in dedicated test directories.

## Commands

| Command                     | Purpose                                                        |
|-----------------------------|----------------------------------------------------------------|
| /replace-operating-guide    | Transition to a new operating guide and update all references. |
| /update-reference-enforcement | Update enforcement scripts for allowed/prohibited references.  |
```