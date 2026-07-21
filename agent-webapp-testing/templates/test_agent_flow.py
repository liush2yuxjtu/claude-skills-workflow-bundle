from __future__ import annotations

import hashlib
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from playwright.sync_api import Locator, Page, expect

MAX_SILENCE = 15
SAVE_INTERVAL = 5
LATEST = Path(".agent/agent-webapp-runtime/latest.json")


def required(name: str) -> str:
    value = os.environ.get(name)
    assert value, f"Set {name} to the application's real runtime API"
    return value


def snapshot(agent: Locator) -> tuple[str, str]:
    return agent.get_attribute("data-agent-state") or "", agent.inner_text()


def wait_change(page: Page, agent: Locator, previous: tuple[str, str]):
    deadline = time.monotonic() + MAX_SILENCE
    while time.monotonic() < deadline:
        current = snapshot(agent)
        if current[0] == "error":
            raise AssertionError(current[1][-300:])
        if current != previous:
            return current
        page.wait_for_timeout(250)
    raise AssertionError("No visible Agent progress for 15 seconds")


def prompt_hash(prompt: str) -> str:
    return hashlib.sha256(prompt.encode()).hexdigest()


def save_runtime_checkpoint(
    page: Page, thread_id: str, prompt: str, state: str
) -> None:
    response = page.request.get(
        required("AGENT_RUNTIME_CHECKPOINT_URL").format(thread_id=thread_id)
    )
    assert response.ok, f"Runtime checkpoint save failed: {response.status}"
    record = {
        "recorded_from": "runtime_api",
        "source_thread_id": thread_id,
        "prompt_sha256": prompt_hash(prompt),
        "expected_state": state,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "checkpoint": response.json(),
    }
    LATEST.parent.mkdir(parents=True, exist_ok=True)
    temporary = LATEST.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, ensure_ascii=False, indent=2))
    temporary.replace(LATEST)


def load_runtime_checkpoint(prompt: str) -> dict | None:
    if not LATEST.exists():
        return None
    record = json.loads(LATEST.read_text())
    if (
        record.get("recorded_from") != "runtime_api"
        or record.get("prompt_sha256") != prompt_hash(prompt)
        or record.get("expected_state") == "completed"
    ):
        return None
    return record


def resume_runtime_checkpoint(page: Page, record: dict) -> str | None:
    response = page.request.post(
        required("AGENT_RUNTIME_RESUME_URL"),
        data={"checkpoint": record["checkpoint"]},
    )
    if response.status in {409, 410, 422}:
        return None
    assert response.ok, f"Runtime checkpoint resume failed: {response.status}"
    thread_id = response.json()["thread_id"]
    page.goto(required("AGENT_WEBAPP_URL").format(thread_id=thread_id))
    agent = page.locator("[data-agent-state]")
    expect(agent).to_have_count(1)
    expect(agent).to_have_attribute(
        "data-agent-state", record["expected_state"], timeout=15_000
    )
    return thread_id


def run_flow(page: Page, prompt: str, checkpoint: dict | None = None) -> bool:
    thread_id = checkpoint and resume_runtime_checkpoint(page, checkpoint)
    resumed = bool(thread_id)
    if not thread_id:
        thread_id = str(uuid4())
        page.goto(required("AGENT_WEBAPP_URL").format(thread_id=thread_id))
        page.locator("[data-testid='agent-prompt']").fill(prompt)
        page.locator("[data-testid='agent-send']").click()

    agent = page.locator("[data-agent-state]")
    expect(agent).to_have_count(1)
    current = snapshot(agent)
    saved_at = 0.0
    saved_state = ""

    while current[0] != "completed":
        if current[0] == "waiting_user":
            answer_id = required("AGENT_ANSWER_ID")
            answer = agent.locator(
                f"[data-testid='agent-answer-option'][data-answer-id='{answer_id}']"
            )
            expect(answer).to_have_count(1)
            answer.click()

        current = wait_change(page, agent, current)
        now = time.monotonic()
        if current[0] != saved_state or now - saved_at >= SAVE_INTERVAL:
            save_runtime_checkpoint(page, thread_id, prompt, current[0])
            saved_at, saved_state = now, current[0]

    save_runtime_checkpoint(page, thread_id, prompt, "completed")
    assert current[1].strip(), "Completed Agent must show final response"
    return resumed


def test_agent_flow(page: Page):
    prompt = os.environ.get(
        "AGENT_PROMPT", "Run a task that requires one clarification"
    )
    resumed = run_flow(page, prompt, load_runtime_checkpoint(prompt))
    if resumed:
        run_flow(page.context.new_page(), prompt)
