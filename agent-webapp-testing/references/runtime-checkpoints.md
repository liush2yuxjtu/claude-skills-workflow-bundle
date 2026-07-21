# Runtime checkpoints

Runtime checkpoints are real persisted Agent state, not recorded SSE. They let a test continue from the last valid state after the application bug that interrupted it is fixed.

## Contract

- Save checkpoints through the application's real persistence API during every live test.
- Keep the latest checkpoint in `.agent/agent-webapp-runtime/latest.json`; `.agent/` must be gitignored.
- Store the source thread ID, prompt hash, visible state, capture time, and opaque API checkpoint payload.
- Capture atomically so an interrupted write cannot replace the last valid checkpoint.
- Treat checkpoint contents as sensitive runtime data: never commit, publish, or attach them as QA evidence.
- Resume through the application's real restore/resume API and normal thread URL. Never use `page.route()` or replay SSE.
- Accept a restored checkpoint only when the prompt and runtime state schema remain compatible.
- Treat an explicit incompatibility response (`409`, `410`, or `422`) as unavailable and start fresh. Surface authentication and server failures instead of hiding them.
- After a resumed flow reaches `completed`, run one new from-scratch live flow.

## Template adapter

Copy `templates/test_agent_flow.py` and set:

- `AGENT_WEBAPP_URL`: normal thread URL containing `{thread_id}`.
- `AGENT_RUNTIME_CHECKPOINT_URL`: real endpoint containing `{thread_id}` that returns the latest persisted checkpoint as JSON.
- `AGENT_RUNTIME_RESUME_URL`: real endpoint that accepts `{"checkpoint": <opaque payload>}` and returns `{"thread_id": "..."}`.
- `AGENT_PROMPT` and `AGENT_ANSWER_ID`: deterministic scenario input and stable domain answer ID.

If the project uses different HTTP methods or response fields, adapt only `save_runtime_checkpoint()` and `resume_runtime_checkpoint()`. Do not add a fixture transport or synthetic event format.
