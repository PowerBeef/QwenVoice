```markdown
# QwenVoice Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches best practices and conventions for contributing to the QwenVoice codebase, a TypeScript project with no detected framework. You'll learn about file naming, import/export styles, commit patterns, and how to write and run tests. This guide also provides suggested commands for common workflows.

## Coding Conventions

### File Naming
- Use **kebab-case** for all file names.
  - Example:  
    ```
    audio-processor.ts
    voice-utils.ts
    ```

### Imports
- Use **relative imports** for internal modules.
  - Example:
    ```typescript
    import { processAudio } from './audio-processor';
    ```

### Exports
- Use **named exports** rather than default exports.
  - Example:
    ```typescript
    // In audio-processor.ts
    export function processAudio(input: Buffer): Buffer { ... }

    // In another file
    import { processAudio } from './audio-processor';
    ```

### Commit Patterns
- Commit messages are **freeform** (no strict prefixes).
- Average commit message length: **51 characters**.
  - Example:
    ```
    Add support for new voice modulation options
    ```

## Workflows

### Adding a New Feature
**Trigger:** When you want to introduce a new capability to the codebase  
**Command:** `/add-feature`

1. Create a new file using kebab-case (e.g., `new-feature.ts`).
2. Implement your feature using named exports.
3. Import your feature in relevant modules using relative paths.
4. Write corresponding tests in a file named `new-feature.test.ts`.
5. Commit your changes with a clear, descriptive message.
6. Open a pull request for review.

### Refactoring Existing Code
**Trigger:** When you need to improve or restructure existing code  
**Command:** `/refactor`

1. Identify the code to refactor.
2. Update file names to kebab-case if needed.
3. Ensure all imports/exports follow the conventions.
4. Update or add tests to cover refactored code.
5. Commit with a message describing the refactor.
6. Submit your changes for review.

### Writing and Running Tests
**Trigger:** When you add or modify code that needs verification  
**Command:** `/test`

1. Create or update test files using the pattern `*.test.ts`.
2. Write tests for all public functions and features.
3. Run the test suite using the project's test runner (framework unknown; check project scripts).
4. Fix any failing tests before committing.

## Testing Patterns

- Test files follow the `*.test.ts` naming convention.
- Testing framework is **unknown**; check the project for setup details.
- Place tests alongside or in a dedicated test directory.
- Example test file:
  ```typescript
  // audio-processor.test.ts
  import { processAudio } from './audio-processor';

  describe('processAudio', () => {
    it('should process audio correctly', () => {
      // test implementation
    });
  });
  ```

## Commands
| Command      | Purpose                                         |
|--------------|-------------------------------------------------|
| /add-feature | Start the workflow for adding a new feature     |
| /refactor    | Begin the process for refactoring code          |
| /test        | Run or write tests for the codebase             |
```
