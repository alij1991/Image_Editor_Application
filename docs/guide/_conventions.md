# Writing conventions

Every chapter in `docs/guide/` follows the same shape so the reader can navigate predictably.

## Audience & tone

- **Audience**: a Flutter/Dart engineer reading the codebase for the first time.
- **Tone**: engineering. No marketing copy, no "delightful user experience." Describe what the code does.
- **Assumed knowledge**: Flutter widgets, Riverpod, Freezed, Dart isolates. Do not re-explain these.
- **Not assumed**: the project's own vocabulary (pipeline, op, pass, memento, seeder). Define these the first time they appear in a chapter.

## Chapter template

Each chapter uses these sections, in order. Omit a section only when it is genuinely empty.

```markdown
# NN — Chapter Title

## Purpose
Two or three sentences. What system does this chapter cover, and why does it exist in the architecture?

## Data model
The key types and where they live. One paragraph or a short table. File:line pointers.

## Flow
Step-by-step walk of the runtime behaviour. Numbered list. Each step cites the file:line of the code that implements it. A Mermaid diagram goes here if the flow has branching or ≥5 steps.

## Key code paths
A short list of the 3–8 entry points a reader should know. Each is a `[file.dart:line](relative/path.dart:line)` link with a one-line description.

## Tests
Where the behaviour is verified. `[test_name.dart](test/path.dart)` links. If a surface has no tests, say so explicitly — that is a finding.

## Known limits & improvement candidates
Bulleted. Each bullet is phrased as the problem (not the fix), with enough context that it can be pulled into `IMPROVEMENTS.md` standalone. Tag with `[perf]`, `[correctness]`, `[ux]`, `[maintainability]`, `[test-gap]`.
```

## File:line pointers

- Use markdown links relative to the current doc, with a `:line` suffix on the label: `[edit_pipeline.dart:25](../../lib/engine/pipeline/edit_pipeline.dart:25)`. The `../../` prefix walks `docs/guide/*.md` back to the repo root so GitHub renders the link correctly.
- Point at the line that *defines* the thing (function signature, class header) — not at an arbitrary interior line.
- When the line number can drift easily, point at the stable enclosing symbol and say "inside `foo()`".
- Re-verify pointers during Phase 7 polish.

## Diagrams

- Use Mermaid fenced code blocks. Prefer them when ≥5 steps or ≥2 branches.
- Keep node labels short (≤4 words). Put long explanations in the prose below the diagram, not in labels.
- Skip diagrams where a numbered list is clearer. Not every chapter needs one.

## Code samples

- Include Dart snippets only when the prose cannot describe the shape without them (e.g. a non-obvious generic signature, a subtle lifecycle rule).
- ≤15 lines. If a longer read is warranted, link to the file instead.
- Strip docstrings and imports from snippets to keep focus.

## Improvement candidates

- **In-chapter**: list them flatly under *Known limits & improvement candidates*. No "we could also…" musings — each bullet must be concrete enough to action.
- **Roll-up**: during Phase 6 we gather all bullets into `IMPROVEMENTS.md`, deduplicate, and rank impact × effort.
- Do **not** fix issues during Phase 1–5 — just document them. The whole point of the separate phase is to see the full picture before touching code.

## Cross-references

- Link between chapters with relative paths: `[Parametric Pipeline](02-parametric-pipeline.md)`.
- The first time a chapter mentions a foundation concept, link to the Phase 1 chapter that defines it. After the first mention in the same chapter, use the bare term.
