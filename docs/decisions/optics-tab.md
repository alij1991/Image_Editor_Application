# ADR: Remove `OpCategory.optics` (Phase II.5)

**Date**: 2026-04-21  
**Status**: Accepted

## Context

`OpCategory.optics` was added as a placeholder for future lens-correction
tools (barrel/pincushion distortion, chromatic aberration, vignette falloff).
No `OpSpec` was ever registered under it, so the dock's
`.where((c) => OpSpecs.forCategory(c).isNotEmpty)` filter silently hid the
tab from users.

The enum value and its associated `_tooltips`/`_icons` entries in
`tool_dock.dart` were live dead code: reachable via `OpCategory.values`
iteration but never displayed, never assigned a spec, and with no work
scheduled in Phases III–IX.

## Decision

Remove `OpCategory.optics` entirely.

- The dock filter already guarded users from seeing an empty tab.
- No op type, no shader, and no service references `optics`.
- Phases III–IX have no planned lens-correction work.
- Keeping a phantom enum value means every `switch` on `OpCategory` must
  handle a case that does nothing — the Dart exhaustiveness checker would
  surface it as noise on every future addition.

## Consequences

- `OpCategory` now has 5 values: `light`, `color`, `effects`, `detail`,
  `geometry`.
- The home-page hint line updated from "6 tool categories" to "5".
- `op_spec_test.dart` test updated to reflect the 5-category world.

## Reversal

When lens-correction work is scoped:

1. Add `optics` back to `OpCategory` in `op_spec.dart`.
2. Register the first `OpSpec` with `category: OpCategory.optics`.
3. Add `_tooltips` and `_icons` entries to `tool_dock.dart`.
4. The dock filter shows the tab automatically once the first spec is
   registered — no other wiring needed.
