1. Project Overview (WHAT)
This repository contains a Swift-based LZFSE command line tool implemented in `lzfse-cli.swift`.
The core functionality is:
- standard LZFSE compression/decompression (`other3`) compatible with Apple streams,
- a private high-ratio extension format (`bvx3`),
- optional Apple `Compression` framework support (`apple`),
- parallel chunked encoding and decoding,
- file and stream I/O with built-in round-trip compatibility tests.

2. Antigravity Task Scope
- Focus on the root Swift source `lzfse-cli.swift`.
- Preserve existing CLI semantics and option behavior.
- Keep changes minimal and surgical; do not refactor unrelated code.
- Only modify this repo when the user requests it.

3. Required Behavior
- `-encode` / `-decode` must remain mutually exclusive and explicit.
- `-algo other3` must remain Apple-compatible standard LZFSE output.
- `-algo bvx3` may remain a private extension with higher ratio.
- `-algo apple` should continue to use `Compression` when available.
- `-lazy2` and `-optimal` only affect `bvx3` and must preserve precedence rules.
- `-si`, `-so`, `-i`, and `-o` should continue to support stdin/stdout and file I/O.
- The built-in `-test` mode should remain available for verification.

4. Coding Guidelines
- Match existing Swift style and bilingual comment/message conventions.
- Do not introduce new dependencies.
- Do not invent new CLI flags beyond the existing documented set.
- If uncertainty arises, ask the user for clarification before changing behavior.

5. Build and Verification
- Build command: `swiftc -O lzfse-cli.swift -o lzfse`.
- Verify with the tool's `-test` option where appropriate.
- Prefer small, local validation over broad rewrites.

6. Guardrails
- Do not rewrite the existing parallel dispatch/semaphore logic unless necessary.
- Do not change the stream format compatibility guarantees.
- Do not remove or replace the `bvx$` end-of-stream marker if it is required by current logic.
- Avoid broad code cleanup; only change code directly tied to the requested task.

7. Agent Behavior
- Apply CLAUDE-style principles: think before coding, simplicity first, surgical changes, and goal-driven execution.
- Work as a developer assistant for Codex-level code editing.
- Use this file as the root guidance for any edits in this repository.