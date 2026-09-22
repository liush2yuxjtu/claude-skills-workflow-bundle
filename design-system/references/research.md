# Design System Skill Research

## Sources reviewed

- Anthropic knowledge-work-plugins design-handoff skill
- Claude community design-system skills
- Claude Code skill repositories

## Common patterns found

### Anthropic style

The official design handoff pattern emphasizes:

- exact visual specifications
- design token references
- component variants
- interaction states
- responsive behavior
- edge cases
- accessibility

The key principle: developers should not guess missing design decisions.

### Community design-system skills

Community implementations commonly include:

- DESIGN.md generation
- living component library pages
- token synchronization
- component documentation
- governance rules

## Adaptation for our workflow

The missing layer in many design-system skills is product intent and runtime evidence.

Our extension:

Intent
↓
Screens
↓
Flows
↓
Components
↓
Tokens
↓
Assets
↓
Runtime verification

This matches the requirement for playable prototypes and production evidence.

## References

- https://github.com/anthropics/knowledge-work-plugins/tree/main/design
- https://github.com/franciscobeccaria/claude-skill-design-system
- https://github.com/rampstackco/claude-skills/tree/main/skills/design-system
