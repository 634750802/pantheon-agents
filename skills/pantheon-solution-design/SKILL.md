---
name: pantheon-solution-design
description: "Iterative design phase using Claude (drafter) + Codex (reviewer) in Pantheon sandbox. Up to 3 rounds of draft-review iteration to produce a verified solution design before any code is written."
---

# Pantheon Solution Design

## Overview

An iterative design-first workflow that produces a verified solution design before any code is written. Uses Claude (drafter) and Codex (reviewer) in up to **3 rounds** of design iteration to converge on a high-quality design.

The final approved design is posted as a GitHub issue comment and its URL is passed to the fixing skill (`pantheon-issue-resolve`).

## Golden Rule

> Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

This rule applies to ALL prompts in this skill.

## Prerequisites

### Terminology

- **Pantheon branch**: A long-running sandbox environment (takes hours to complete)
- **Design round**: One Claude draft + one Codex review
- **Baseline branch**: The starting Pantheon branch from which all design explorations branch

### Waiting/Polling Mechanism

**After every `parallel_explore` call**, you must wait for completion:

1. Poll `functions.mcp__pantheon__get_branch(branch_id)` until status is one of:
   - **Terminal states**: `failed`, `succeed`, `finished`
   - **Output-ready states**: `manifesting`, `ready_for_manifest`

2. When status is terminal or output-ready, call `functions.mcp__pantheon__branch_output(branch_id, full_output=true)` to retrieve results.

3. If status is not ready, sleep for 600 seconds (10 minutes), then poll again.
   - **Critical**: Do NOT start overlapping sleeps or other tool calls during the wait
   - No background sleeps (`sleep ... &`)
   - Treat "Waiting for background terminal" messages as exclusive waits

4. **Note**: `manifesting` and `ready_for_manifest` mean the run is complete; you can fetch output and proceed (no need to wait for `succeed`/`finished`).

### Constraints

- **Always use `num_branches=1`** with `parallel_explore`
- **One active exploration at a time** – Never start a second exploration while the first is running
- **Pantheon branches are long-running** (hours) – Don't treat them as quick tasks; be patient
- **Read branch_output before any decision** – Impatience creates wasted work

## Inputs & Setup

**Parse the `task_description` to extract:**

1. `issue_link` (required): GitHub issue URL or identifier

2. **Required Pantheon context** (from AGENTS.md runtime):
   - `parent_branch_id`: Starting Pantheon branch ID (sandbox baseline)

**Initialize workflow variables:**
```python
# Input
issue_link = <extracted from task>

# Branch tracking
baseline_branch_id = parent_branch_id  # Never changes; all design drafts branch from here
design_branch_id = None  # Set after each design draft

# Iteration tracking
round_number = 0
max_rounds = 3

# Output
design_status = None  # APPROVED, CONSENSUS, or NO_ACTION_NEEDED
design_comment_url = None  # URL of the GitHub comment containing the final design
```

## Workflow Observability

The orchestrator (you, following this skill) **must post a status comment on the GitHub issue after every step completes**. This ensures the workflow is fully traceable from the issue thread alone.

**Status comment format:**

```bash
gh issue comment {issue_number} --body-file - <<'STATUS_EOF'
<!-- pantheon-design-status:step-{step_name}:round-{round_number} -->

**Pantheon Design Workflow — {step_name}** (Round {round_number}/{max_rounds})

- **Branch ID**: `{branch_id}`
- **Agent**: {agent_type}
- **Outcome**: {outcome summary}
- **Next**: {what happens next}
STATUS_EOF
```

**Why**: If a Pantheon agent fails to post its own comment (e.g., `gh` unavailable in sandbox), the orchestrator's status comment still provides a trace. After the review step, the orchestrator must also **verify** the reviewer posted its comment — if not, note it in the status.

---

## Workflow

### Step 1: Design Draft (Claude)

**Purpose**: Sync code, analyze deeply, and produce a solution design.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"claude_code"`
- `num_branches`: `1`
- `parent_branch_id`: `baseline_branch_id`

**Prompt** (Round 1):

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

=== PHASE 1: SYNC CODE ===

Pull the latest code from master branch.

=== PHASE 2: DEEP ANALYSIS ===

Analyze issue: {issue_link}

Apply scientific rigor. Default stance: every claim may be invalid until evidence proves otherwise.

1. Restate the issue claim precisely (expected vs actual, triggering inputs/config)
2. Locate relevant code paths and exact conditions to reach them
3. Determine reachability under default/common production configs
4. Identify root cause with code-causal chain (why this, not alternatives)
5. Search for counter-evidence (feature gates, guards, fallbacks, test-only paths, unreachable branches)
6. Assess impact and blast radius (unavailability, correctness, data safety, security, performance)
7. Check for broader systemic issues (same pattern elsewhere, shared abstractions)
8. If the report mentions a failing test, identify the minimal failing case and rerun it on current HEAD to confirm repro (or prove non-repro)

=== PHASE 3: SOLUTION DESIGN ===

If no action is needed, output:
VERDICT=NO_ACTION_NEEDED
REASON=<brief explanation: not a bug / already fixed / duplicate / out of scope / test-only>

Otherwise, produce a comprehensive design:
VERDICT=NEED_DESIGN_REVIEW

BEGIN_SOLUTION_DESIGN
root_cause: <precise root cause with code-causal chain>
severity: <P0 / P1 / P2 / feature>
approach: <clear solution architecture — what to change, why, and how components interact>
files_to_change:
  - <exact file path 1>: <what changes and why>
  - <exact file path 2>: <what changes and why>
edge_cases:
  - <edge case 1 and how design handles it>
  - <edge case 2 and how design handles it>
test_strategy: <how to verify the fix — specific tests to add/modify/run>
risks:
  - <risk 1 and mitigation>
  - <risk 2 and mitigation>
alternatives_rejected:
  - <rejected approach 1 and why>
  - <rejected approach 2 and why>
END_SOLUTION_DESIGN

=== PHASE 4: POST TO GITHUB ===

Post the design as a comment on the issue:

gh issue comment {issue_number} --body-file - <<'DESIGN_EOF'
<!-- pantheon-design-draft:round-1 -->

## Solution Design (Round 1)

<paste the full SOLUTION_DESIGN content here, formatted as markdown>
DESIGN_EOF

=== OUTPUT ===

Output exactly ONE of:

--- No action needed ---
VERDICT=NO_ACTION_NEEDED
REASON=<explanation>

--- Design ready for review ---
VERDICT=NEED_DESIGN_REVIEW
<full SOLUTION_DESIGN block>
```

**Wait for completion** (see Waiting/Polling), then:

1. Parse output
2. Set `design_branch_id = <branch_id from this step>`
3. **Post orchestrator status comment** on the issue:
   - Step: `design-draft`
   - Branch ID: `design_branch_id`
   - Agent: `claude_code`
   - Outcome: `VERDICT` value
   - Next: what follows (review or stop)
4. If `VERDICT=NO_ACTION_NEEDED`:
   - Set `design_status = "NO_ACTION_NEEDED"`
   - **Stop workflow** — output:
     ```
     DESIGN_STATUS=NO_ACTION_NEEDED
     ```
5. If `VERDICT=NEED_DESIGN_REVIEW`:
   - Extract `SOLUTION_DESIGN` block
   - Set `round_number = 1`
   - Proceed to Step 2

---

### Step 2: Design Review (Codex)

**Purpose**: Review the design against the actual codebase for correctness and completeness.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `design_branch_id`

**Prompt**:

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

=== CONTEXT ===

Review the following solution design for issue: {issue_link}
This is design review round {round_number} of max {max_rounds}.

=== DESIGN TO REVIEW ===

{paste entire SOLUTION_DESIGN block from the latest draft}

=== REVIEW CRITERIA ===

Review this design against the actual codebase with scientific rigor:

1. **Reasonableness**: Does the approach make sense architecturally? Is there a simpler way?
2. **Root cause accuracy**: Is the stated root cause correct? Verify against actual code.
3. **File paths**: Do all listed files exist? Are the right files targeted?
4. **Completeness**: Are there missing edge cases, error paths, or interaction effects?
5. **Wrong assumptions**: Does the design assume things that aren't true in the codebase?
6. **Overengineering**: Is the design doing more than necessary? Could it be simpler?
7. **Patch/workaround detection**: Does the design patch symptoms instead of fixing root cause? REJECT if so.
8. **Test strategy**: Is the test strategy realistic and sufficient?

=== POST REVIEW TO GITHUB (MANDATORY) ===

You MUST post your review as a comment on the issue. This is a CRITICAL requirement — the workflow depends on this comment being visible in the issue thread for observability. If `gh` fails, retry once. If it still fails, include the full review text in your output so the orchestrator can post it.

gh issue comment {issue_number} --body-file - <<'REVIEW_EOF'
<!-- pantheon-design-review:round-{round_number} -->

## Design Review (Round {round_number})

**Verdict**: DESIGN_APPROVED or DESIGN_NEEDS_REVISION

<your detailed review findings, formatted as markdown>
REVIEW_EOF

After posting, output the comment URL if available.

=== OUTPUT ===

If the design is sound and ready for implementation:
DESIGN_APPROVED
APPROVAL_NOTES=<brief summary of why the design is approved>

If the design needs revision:
DESIGN_NEEDS_REVISION
BEGIN_REVISION_FEEDBACK
- <specific gap/issue 1 with code evidence>
- <specific gap/issue 2 with code evidence>
- <specific gap/issue 3 with code evidence>
END_REVISION_FEEDBACK
```

**Wait for completion**, then:

1. Parse output
2. **Verify reviewer posted its comment**: Check the issue for a comment containing `<!-- pantheon-design-review:round-{round_number} -->`.
   - If found: good, note the comment URL.
   - If NOT found: the reviewer failed to post. Post the review content yourself (extracted from `branch_output`) as the review comment, so the thread remains complete.
3. **Post orchestrator status comment** on the issue:
   - Step: `design-review`
   - Branch ID: the review branch
   - Agent: `codex`
   - Outcome: `DESIGN_APPROVED` or `DESIGN_NEEDS_REVISION`
   - Review comment posted: yes/no (and whether orchestrator had to post it)
   - Next: what follows
4. If `DESIGN_APPROVED`:
   - Post the final approved design comment (see "Final Design Comment" below)
   - Set `design_status = "APPROVED"`
   - **Exit workflow** with output:
     ```
     DESIGN_STATUS=APPROVED
     DESIGN_COMMENT_URL=<url of the final design comment>
     ```
5. If `DESIGN_NEEDS_REVISION`:
   - Extract revision feedback
   - If `round_number >= max_rounds`: go to "Final Round — Ship Consensus"
   - Otherwise: proceed to Step 3

---

### Step 3: Design Iteration (up to 3 rounds)

**Purpose**: Claude revises the design incorporating reviewer feedback.

Increment `round_number += 1`.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"claude_code"`
- `num_branches`: `1`
- `parent_branch_id`: `baseline_branch_id` (always branch from baseline for design drafts)

**Prompt** (varies by round):

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

=== CONTEXT ===

You are revising a solution design for issue: {issue_link}
This is revision round {round_number} of max {max_rounds}.

{round_pressure}

=== PREVIOUS DESIGN ===

{paste the most recent SOLUTION_DESIGN block}

=== REVIEWER FEEDBACK ===

{paste the REVISION_FEEDBACK from the reviewer}

=== PHASE 1: SYNC CODE ===

Pull the latest code from master branch.

=== PHASE 2: REVISE DESIGN ===

Address every piece of reviewer feedback. For each point:
1. Verify the reviewer's claim against the actual code
2. If the reviewer is right: revise the design to address it
3. If the reviewer is wrong: provide code evidence showing why

Produce a revised design:

VERDICT=NEED_DESIGN_REVIEW

BEGIN_SOLUTION_DESIGN
root_cause: <updated root cause>
severity: <P0 / P1 / P2 / feature>
approach: <revised solution architecture>
files_to_change:
  - <exact file path 1>: <what changes and why>
  - <exact file path 2>: <what changes and why>
edge_cases:
  - <edge case 1 and how design handles it>
  - <edge case 2 and how design handles it>
test_strategy: <revised test strategy>
risks:
  - <risk 1 and mitigation>
  - <risk 2 and mitigation>
alternatives_rejected:
  - <rejected approach 1 and why>
  - <rejected approach 2 and why>
revision_notes: <what changed from previous round and why>
END_SOLUTION_DESIGN

=== PHASE 3: POST TO GITHUB ===

Post the revised design as a comment on the issue:

gh issue comment {issue_number} --body-file - <<'DESIGN_EOF'
<!-- pantheon-design-draft:round-{round_number} -->

## Solution Design (Round {round_number})

<paste the full revised SOLUTION_DESIGN content here, formatted as markdown>

### Changes from Round {round_number - 1}
<summary of what changed and why>
DESIGN_EOF

=== OUTPUT ===

VERDICT=NEED_DESIGN_REVIEW
<full revised SOLUTION_DESIGN block>
```

**Round pressure** (injected into the prompt):

| Round | `{round_pressure}` |
|-------|---------------------|
| 2 | `Think harder. The reviewer found real problems. Verify EVERY claim against the code before asserting it.` |
| 3 | `Final round. Ship the best consensus design you can. Note any remaining concerns explicitly.` |

**Wait for completion**, then:

1. Parse output
2. Set `design_branch_id = <branch_id from this step>`
3. Extract revised `SOLUTION_DESIGN` block
4. **Post orchestrator status comment** on the issue:
   - Step: `design-revision`
   - Branch ID: `design_branch_id`
   - Agent: `claude_code`
   - Round: `{round_number}`
   - Outcome: revision completed
   - Next: sending to reviewer
5. Go back to **Step 2** (Design Review) for Codex to review the revision

---

### Final Round — Ship Consensus

If `round_number >= max_rounds` and the reviewer still says `DESIGN_NEEDS_REVISION`:

1. Post the final consensus design comment (see "Final Design Comment" below), including a "Remaining Concerns" section from the reviewer's last feedback
2. Set `design_status = "CONSENSUS"`
3. **Exit workflow** with output:
   ```
   DESIGN_STATUS=CONSENSUS
   DESIGN_COMMENT_URL=<url of the final design comment>
   DESIGN_NOTES=<remaining concerns from reviewer>
   ```

---

## Final Design Comment

When the design is approved (or consensus reached), post the final design as a GitHub issue comment with a stable marker tag:

```bash
gh issue comment {issue_number} --body-file - <<'FINAL_EOF'
<!-- pantheon-final-design -->

## Final Solution Design

**Status**: {APPROVED or CONSENSUS}
**Rounds**: {round_number}

### Root Cause
{root_cause}

### Severity
{severity}

### Approach
{approach}

### Files to Change
{files_to_change, formatted as bullet list}

### Edge Cases
{edge_cases, formatted as bullet list}

### Test Strategy
{test_strategy}

### Risks
{risks, formatted as bullet list}

### Alternatives Rejected
{alternatives_rejected, formatted as bullet list}

{if CONSENSUS:}
### Remaining Concerns
{remaining concerns from reviewer's last feedback}
{end if}

---
Automated by [pantheon-solution-design](https://github.com/pingcap-inc/pantheon-agents/tree/main/skills/pantheon-solution-design)
FINAL_EOF
```

Capture the comment URL from the `gh issue comment` output and set `design_comment_url`.

---

## Summary: Information Flow

```
Round 1:
  Step 1: Claude drafts design (from baseline) → posts to issue
  Step 2: Codex reviews design → posts to issue
    → DESIGN_APPROVED? → post final comment, exit
    → DESIGN_NEEDS_REVISION? → continue

Round 2 (if needed):
  Step 3: Claude revises (from baseline, with feedback) → posts to issue
  Step 2: Codex re-reviews → posts to issue
    → DESIGN_APPROVED? → post final comment, exit
    → DESIGN_NEEDS_REVISION? → continue

Round 3 (if needed, final):
  Step 3: Claude revises (from baseline, with feedback) → posts to issue
  Step 2: Codex re-reviews → posts to issue
    → DESIGN_APPROVED? → post final comment, exit
    → DESIGN_NEEDS_REVISION? → ship consensus, exit
```

## Recovery & Error Handling

### Pantheon Exploration Failures

If a Pantheon branch fails (status = `failed`):

1. Check `branch_output` for error details
2. Determine if error is transient (network, resource) or permanent (code crash)
3. If transient: retry the same step from the same `parent_branch_id`
4. If permanent: investigate root cause, escalate to user

### Idempotency

- Design draft comments use marker `<!-- pantheon-design-draft:round-N -->`
- Design review comments use marker `<!-- pantheon-design-review:round-N -->`
- Final design comment uses marker `<!-- pantheon-final-design -->`
- Before posting, check if a comment with the same marker already exists to avoid duplicates

## Notes

- **Agent selection**:
  - Step 1, Step 3 (Design drafts): Use `agent="claude_code"` — needs deep code analysis
  - Step 2 (Design review): Use `agent="codex"` — analytical review
- **Branch strategy**: Design drafts always branch from `baseline_branch_id` (design is text analysis, not code changes). Content is carried via prompts.
- **Sequential explorations**: This workflow uses sequential explorations by design (each depends on previous results)
