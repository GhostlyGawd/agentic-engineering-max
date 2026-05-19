### BUILDING PRINCIPLES

## Global Best Practices
- After every round of changes, push a PR to Github. If no repo exists yet, create one. You don't have to ask the user's permission to push pr's.

## Dogfooding

# Dogfooding - Principles
- **The repo IS the system.** Build artifacts (skills, hooks, scripts, tests, conventions) live in `bin/`, `hooks/`, `tests/`, and the live `~/.claude/{skills,hooks,commands}/` mirrors — the planning files document why. The repo and the workspace it operates in are the same thing.
- **Every learning loops back into the system.** When using the system reveals a bug, gap, friction, or improvement, the fix goes into the repo — not into a one-off operator workaround, not into a memory entry, not into a comment we'll fix later. Operator-only fixes (memory notes, mental reminders, "I'll remember to do X next time") are anti-patterns whenever a structural fix is possible. Memory might help one operator on one machine for one session; the repo helps every operator on every clone in every session.
- **Use it on itself.** The build system (PM + worker + reviewer + unblock cycle, state-surface discipline, plan interviewer, etc.) is exercised on its own waves and on every project the workspace hosts. Bugs that only appear under real use are the bugs that matter; manual one-shot verification does not substitute for live usage.
- **Failure modes get patched at the structural layer.** When a discipline fails (e.g., operator forgets to bump plan-state after a ledger edit), the fix is enforcement (e.g., a pre-commit hook), not "remember to do better next time." The 2026-05-17 pre-commit-hook PR (#25) is the canonical example: the gap was caught by the existing post-fact drift hook, the fix was a pre-fact enforcement hook in the repo, and the regression test (PR #26) locked the contract in code.
- **The dogfooding loop is the integration test for what we ship.** Unit tests in `tests/` cover specific scripts. The integration test is using the system — every wave, every bug fix, every escalation cycle is a live trial of the build's discipline. When it breaks, the break is signal: capture the root cause in a ledger entry and patch it structurally in the same PR.
- **Workspace-wide convention adoptions get a ledger entry** under `planning/state-surface-discipline/plan-ledger.md` (the home for cross-project conventions, per precedent set by the 2026-05-17 testing-convention entry). This keeps the convention's rationale, alternatives considered, and adoption date discoverable to anyone using the system later — including future-you.

## Planning

# Planning - Principles
- Ask clarifying questions using a scientific method. Develop a scoring criteria across multiple fields that gate you from being able to move on until you have validated understanding of the user's intention. It must reach 100% understanding before you can move on.
-- Never make assumptions. Never assume you know what they are talking about.
- As you gain confirmed understanding, log it to a planning file with clear timestamps and versioning. This is the v1 foundation of understanding you will carry forward about the concept to develop your specs, PRD's, and any other plan documents using the confirmed information you've aligned on with the user along with the timestamped date it occurred and the version.
-- Versioning is useful for when plans change. Sometimes the user will change preference or an original assumption they confirmed was incorrect. This is when you strike out the original entry and create a new version below it. This gives a paper trail ledger of project evolution and keeps everything up to date.

# Planning - State surface vs ledger
- Every project has TWO state-tracking files in its planning directory: `plan-state.md` (mutable, overwritten on every phase transition) and `plan-ledger.md` (append-only, strikethrough-versioned). Plus a public state surface at the repo root (`README.md`) that mirrors `plan-state.md` for fresh-session orientation.
- Ledger discipline (strikethrough on supersede, ISO-dated `v1.x (YYYY-MM-DD)` headers) applies ONLY to `plan-ledger.md` entries. State-surface files (`plan-state.md`, `README.md`) are overwritten in place with current state, never strikethrough-versioned.
- Phase-owning agents (Plan Interviewer, PRD Writer, Spec Writer, Wave Closer) MUST update both state surfaces as part of their Definition of Done before declaring complete. Enforcement lives in the agent specs, not here.
- A Stop hook at `~/.claude/hooks/state-drift-check.ps1` synchronously detects drift between ledger and state on every turn end and surfaces the gap via `hookSpecificOutput.additionalContext`. Allowlist-scoped; quietly no-ops outside the allowlist.

# Planning - Finalizing Plans
- Once a plan has reached 100% understanding, it's time to write a PRD and Spec for the implementation plan. 
- PRD: the interviewer never starts work on this until it has 100% understanding of the plan. the plan in detail turned into a clear engineering document. It is not a spec writer. It doesn't break out tasks for a team. The goal of the PRD is to create a clear, detailed brief that can be provided to the spec writer to communicate the 100% understanding gathered in the interviewing process and keep everyone aligned on the plan. As with everything, the PRD should be timestamped and versioned. This is a living doc. It is to be handed off to the spec writer.
- Spec sheet: This should have clearly scoped tasks with proper dependencies that can be handed off to other agents. It should follow the best practices engineering documentation that is robust and clear to align an entire team on a build.

# Planning - Agents
- Plan Interviewer:
-- If this role doesn't currently exist, you should create the agent to be called upon later. It's instructions should reiterate the process I outlined above. It should be written by Opus 4.7 with any relevant agent creation skills loaded up for best performance.
-- The interviewer thinks before it responds. Following the scientific approach, thinking through from all angles before replying next. It always evaluates the scorecard criteria and updates the relevant metric based on the user's reply.
-- For reasoning, each time it thinks through a problem, it considers it from 4 epistemic stances. If no epistemic subagents have been created yet, it should create them and store them for future use.
--- It generates 3 ideas -> Provides to an adversarial stanced team of different positions, then synthesizes a final recommendation.
-- When the interviewer reaches 100% understanding, it's job is done.
- Plan Maintainer:
-- On-demand structural janitor for planning files. NOT an ambient or polling agent.
-- Invoked manually when a planning directory's information categories have drifted out of structural shape (categories conflated, TOC stale, sections out of logical order). The Stop hook at `~/.claude/hooks/state-drift-check.ps1` handles drift detection between `plan-state.md` and `plan-ledger.md`; the Plan Maintainer no longer owns that role.
-- When invoked, follows this sequential process: review current state -> check that information categories are coherent -> reorganize if applicable -> check table-of-contents router -> update if applicable -> final sweep -> stop.
- PRD Writer:
-- Writes the PRD. Spawned by the interviewer
- Spec Writer:
-- The spec writer. Writes clearly scoped out specs with proper dependencies that can be handed off to other agents to implement. If this agent doesnt' exist, it shoudl be created.
-- It should follow a best practices engineering design documentation that is robust and clear to align an entire team on a build.
-- The spec writer should write it's specs to maximize parallelization. If a task can be broken down in a way where concurrent agents can work on it, opt for that build versus one that is sequential. This is on an if-possible basis. 
-- Every task should have a clear success criteria that is able to be validated by the AI agents to complete the task

## Implementing

# Implementing - Principles
- Once the Spec has been written, the implementation phase begins.
- There are three departments of implementation: Project Management, Build Management, and Critical Review
--- Project Management: Creates a shared task list board for the implementation team to work from concurrently. Keeps the project progress and status on track globally. The project board is blocked out based on the spec sheet and carries all of the dependencies and details directly from the spec into each task that is linked back to the spec sheet. Only one worker can claim a task. Each task on the board should have all schema required for proper management including date created, worker assigned, status (open, in progress, ready for review, in review, needs fixing, done), number of review iterations, blocked by, and anything else. The Project Management runs in a loop in it's own chat and is always on, checking the board and keeping it maintained and up to date. Making sure things are looking good. In addition to the shared task board, each individual task gets it's own task.md in a sub-file that's exclusive to that task only.
--- Build Management: The worker teams that implement the tasks on the board. Only one worker at a time can atomic claim a task. When a worker claims a task and begins work, it is in progress. The worker adds their ID to the task when they claim it. The worker adds its ID to the ID list along with it's claude code session. The claude code session is the hard link to the worker ID. When the worker finishes a task and commits it, it sets the task to in-review and removes the atomic lock. This then leads to the review team. If the review team finds flaws, a worker then picks up the review feedback (added to the the task sub file) and implements the fixes. It continues the process of iteration until the review team finds no errors. When the worker picks up a needs fixing task (the indicator the review team has completed it's review and feedback) it sets the task back to in progress until it's ready for review again.
--- Critical Review: The code review team. Implements a team of code review agents that use different best practice code review philosophies to review implementation from multiple angles. Each agent provides a report which is then synthesized into a final feedback fix. If no errors are found, that's fine, just list why. If there are errors found, list why. They don't ever make assumptions. When the review team starts, it follows the same ID process as the worker team. It also atomics claims tasks in the reviewer field and releases once complete.
- All three departments run on a loop. Enabling multiple sessions to be spawned simultaneously for maximum efficient concurrent work. Claiming what is available. The only one that is one chat is the PM team.
- Context RULE: there must be a watchful eye on context. After 5 loops of iteration, the orchestrator needs to stop the loop altogether in that chat and write a handoff document for the next team to pick up where they left off. A loop ends when the task is done and not before. But after the 5th loop is done, it should end. Any agent doing atomic locks should ensure it removed all locks before retiring.

# Implementing - Agents
- Each of these three departments needs agents. Dispatching agents is a key pillar of the philosophy here. Once created, they need to be saved for future use.

## Testing

# Testing - Principles
- **Every bug fix lands with a regression test.** When a defect is identified and patched, the same commit (or PR) adds a test that would have caught the original bug. The test is the proof the fix holds and the guardrail against the same defect re-emerging during future refactors. Adopted 2026-05-17 after dogfooding caught the operator-direct ledger-edit failure mode (see `planning/state-surface-discipline/plan-ledger.md` 2026-05-17 entry).
- **No retroactive Pester adoption for small scripts.** Targeted, high-signal regression tests beat broad framework coverage for this codebase's current shape (single-developer cadence, small scripts, live dogfooding loop). Tests live in `tests/` at repo root and are plain `.ps1` scripts that exit 0 on pass, 1 on fail — runnable directly without a framework dependency.
- **Integration-level smoke tests of the build system are tracked work, not background hope.** End-to-end coverage of PM → worker → reviewer → unblock cycle is the kind of test that catches what manual one-shot verification misses; deferred to the orchestrator-and-build-system Wave 3 backlog (`tasks/task-W3-003.md`).
- Test scripts should mirror real production invocation paths (e.g., the pre-commit hook test invokes real `git commit`, not the `.ps1` directly) so that bugs in adapter layers (bash shims, escape soup, argument binding) are caught alongside logic bugs. 