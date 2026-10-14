# Agent Instructions

These instructions apply to AI agents working in this repository. Follow
task-specific requirements, repository contracts, and safety constraints
wherever they are more specific or restrictive.

## Canonical Coding Standard

For all coding, debugging, refactoring, and code-review tasks, **read and
apply**:

**[Karpathy–Manning–DTNorris
Guidelines](https://github.com/dtnorris/agent-skills/blob/main/skills/karpathy-manning-dtnorris-guidelines/SKILL.md)**

This is the canonical, centrally maintained coding standard. Do not duplicate
or independently modify it in this repository.

Read the complete skill before proposing or implementing changes. If
inaccessible, disclose that limitation; do not claim to have applied an unread
skill. For reproducible work, record the skill revision used when relevant.

## Working Principles

1. **Inspect before changing.** Verify the exact repository, current Git HEAD,
   working-tree state, and relevant source files. Do not infer local execution
state from GitHub. Refresh after concurrent changes.

2. **Think before coding.** Surface material assumptions, ambiguities,
   tradeoffs, and simpler alternatives. Define verifiable success criteria
before implementation.

3. **Keep changes surgical.** Make the smallest change that satisfies the
   request. Preserve existing conventions and contracts. Avoid speculative
features, unrelated refactoring, and unnecessary abstractions.

4. **Document appropriately.** Follow the canonical skill's documentation
   requirements while preserving project-specific conventions and authoritative
documentation.

5. **Verify behavior.** Reproduce reported defects when practical. Run focused
   tests and relevant negative cases. Preserve existing coverage, performance,
safety, and acceptance gates. Never weaken validation merely to obtain a
passing result.

6. **Report evidence accurately.** Distinguish tested behavior from
   assumptions, unexecuted tests, environmental blockers, and pre-existing
failures. Disclose unrelated changes.

## Git and Handoff Safety

- Do not commit, push, merge, create PRs, or modify GitHub unless explicitly
  authorized.
- Prefer non-destructive local handoffs: reviewable patches for substantive
  changes and fail-closed scripts for narrow mechanical edits.
- Validate generated patches or scripts against the exact inspected source
  whenever possible.
- Do not overwrite unrelated local work or silently expand task scope.

## Production and Cost Safety

Before consequential execution, verify the actual local execution root, Git
state, and required provenance.

Do not create or expand paid resources without explicit authorization and
independently enforced finite spending or runtime limits that survive
orchestrator failure. Preserve existing production safeguards.

## Precedence

Explicit task requirements, safety constraints, production contracts, and
acceptance criteria take precedence over these general guidelines. Report
conflicts rather than silently resolving them by weakening a requirement.
