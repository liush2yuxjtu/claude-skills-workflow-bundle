# Smart-selector contract

Smart selectors identify behavior, not model-generated wording.

## Required DOM contract

- Put `data-agent-state` on one stable Agent root.
- Put `data-testid` on interactive roles such as prompt, send, question, and answer option.
- Put `data-answer-id` on each answer option using a stable domain ID.
- Scope question and answer locators under the Agent root.

```html
<section data-agent-state="waiting_user">
  <div data-testid="agent-question">
    <button data-testid="agent-answer-option" data-answer-id="approve">
      Confirm and continue
    </button>
  </div>
</section>
```

```python
agent = page.locator("[data-agent-state]")
question = agent.locator("[data-testid='agent-question']")
question.locator(
    "[data-testid='agent-answer-option'][data-answer-id='approve']"
).click()
```

Do not use generated display text, translated labels, CSS presentation classes, or positional selectors such as `nth(2)` as identity. If several elements share a test ID, add a stable domain ID instead of choosing the first match.
