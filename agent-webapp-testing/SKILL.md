---
name: agent-webapp-testing
description: Test AI-featured web apps with Playwright Python, including streaming, smart selectors, durable runtime checkpoints, resume, completion, and recovery.
---

# Agent Web App Testing

Reuse Anthropic `webapp-testing` for browser interaction, logs, screenshots, and assertions.

Test Agent UI as a state machine: `running -> streaming -> waiting_user -> running -> completed`.

Use `templates/test_agent_flow.py`. Fail after 15 seconds without visible text or state change.

Use the smart-selector contract: locate behavior with stable `data-agent-state`, `data-testid`, and `data-answer-id`, never generated text, CSS classes, or position. Read `references/selector-contract.md`.

By default, every live test saves the latest valid runtime checkpoint through the application's real persistence API.

After a bug interrupts a test, preserve that checkpoint. After the fix, use `templates/test_agent_flow.py` to resume from the latest compatible checkpoint and continue through `completed`. If none is valid, start fresh.

Read `references/runtime-checkpoints.md`. Do not capture, synthesize, intercept, or replay SSE fixtures.

After resumed verification, keep one complete from-scratch live test. Save trace, screenshots, final response, and HTML QA evidence.

Every live UAT records unedited WebM through Playwright. Start recording before prompt submission, stop after terminal state, and keep video evidence for both pass and failure under `uat-artifacts/`.
