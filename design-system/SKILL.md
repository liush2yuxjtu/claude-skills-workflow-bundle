---
name: design-system
description: Build, audit, and evolve product design systems. Use when creating design systems, component libraries, design tokens, screen inventories, flows, visual QA, motion systems, or design handoff contracts.
---

# Design System Skill

## Goal

Turn an existing product or prototype into a living design system that connects:

Intent → Screens → Flows → Components → Tokens → Assets → Runtime Evidence

Do not create isolated style guides. Build a system that can guide implementation.

## Workflow

### 1. Discover current reality

Inspect:

- product screens
- user flows
- existing UI components
- CSS/design tokens
- assets
- motion behavior
- implementation constraints

Create an inventory before proposing changes.

### 2. Define system layers

Create four core layers:

1. Intent layer
   - product principles
   - user goals
   - design decisions

2. Screen and Flow layer
   - all user-visible screens
   - happy path and edge flows
   - responsive variants

3. Component layer
   - components
   - variants
   - states
   - accessibility
   - usage rules

4. Token and Asset layer
   - color
   - typography
   - spacing
   - motion
   - material
   - 3D assets

### 3. Component contract

Every component must define:

- purpose
- when to use
- variants
- props
- states
- interaction rules
- accessibility
- examples
- anti-patterns

### 4. Visual verification

Never trust documentation alone.

Produce:

- snapshots
- before/after comparison
- visual diff
- runtime verification evidence

### 5. Maintain living system

Prefer generated artifacts:

- tokens from source
- components from registry
- previews from real implementation
- audits from scripts

Avoid duplicated hand-written truth.

## Output Structure

```
design-system/
├── intent.md
├── screens/
├── flows/
├── components/
├── tokens/
├── assets/
├── motion/
├── examples/
└── validation/
```

## Special rules for game / 3D products

Add:

- camera rules
- lighting rules
- material rules
- VFX lifecycle
- animation states
- asset provenance
- engine constraints

A VFX asset is not only an image. Document:

Input → State → Animation → Trigger → Runtime Evidence

