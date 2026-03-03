---
name: pantheon-issue-resolve
description: "Implementation + review + verify + fix loop. Receives an approved solution design via GitHub comment link, implements the fix, hunts P0/P1 bugs, triages findings, and iterates until no blocking issues remain."
---

# Pantheon Issue Resolve

## Overview

A rigorous implementation and review workflow that takes an approved solution design and drives it to a merge-ready PR. The workflow consists of:

1. **Implement** → Execute the approved design, create/update PR
2. **Review** → P0/P1 bug hunt + CI check on the changes
3. **Verify** → Triage findings and scope decisions
4. **Fix Loop** → Iterate until no in-scope blockers remain

This skill receives its design from `pantheon-solution-design`, which posts the final design as a GitHub issue comment.

## Golden Rule

> Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

This rule applies to ALL prompts in this skill.

## Prerequisites

### Terminology

- **Pantheon branch**: A long-running sandbox environment (takes hours to complete)
- **PR**: GitHub Pull Request
- **P0/P1**: Critical/high-severity issues (see definitions below)
- **In-scope**: Issues that must be fixed in this PR before merge
- **Deferred**: Valid issues tracked in separate GitHub issues
- **Design comment**: The GitHub issue comment containing the approved solution design (posted by `pantheon-solution-design`)

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
- **One issue, one active exploration, one PR** – Never start a second exploration while the first is running
- **Pantheon branches are long-running** (hours) – Don't treat them as quick tasks; be patient
- **Read branch_output before any decision** – Impatience creates duplicate PRs and wasted work

### P0/P1 Standard (Evidence-Backed)

All severity claims must include code-causal evidence + reachability analysis + blast radius.

- **P0 (Critical)**: Reachable under default production config, and causes:
  - Production unavailability, OR
  - Severe data loss/corruption, OR
  - Security vulnerability, OR
  - Primary workflow completely blocked with no practical workaround

- **P1 (High)**: Reachable in realistic production scenarios (default or common configs), and:
  - Significantly impairs core/major functionality, OR
  - Violates user-facing contracts (correctness errors), OR
  - Severe performance regression impacting usability
  - Workaround may exist but is costly/risky/high-friction

- **Evidence bar**: Borderline P1/P2 defaults to P1 unless impact is clearly narrow or edge-case only.

## Inputs & Setup

**Parse the `task_description` to extract:**

1. **Entry point** (exactly ONE of):
   - `issue_link`: GitHub issue URL or identifier → set `entry_mode = "new_issue"`
   - `existing_pr_link`: GitHub PR URL or number → set `entry_mode = "existing_pr"`

2. **Design input:**
   - `design_comment_link`: URL of the GitHub comment containing the final approved/consensus design (posted by `pantheon-solution-design`)

3. **Required Pantheon context:**
   - `parent_branch_id`: Starting Pantheon branch ID (sandbox baseline)

**Pre-workflow setup:**

If `entry_mode = "existing_pr"`:
1. Extract PR metadata:
   ```bash
   gh pr view {existing_pr_link} --json number,url,headRefName,body
   ```
2. Set: `pr_number`, `pr_url`, `pr_head_branch`
3. Try to extract issue link from PR body/title (look for "Fixes #123", "Closes https://...")
4. If no issue found: set `issue_link = existing_pr_link`

**Initialize workflow variables:**
```python
# Entry tracking
entry_mode = "new_issue" or "existing_pr"
issue_link = <extracted from task>
existing_pr_link = <extracted or None>
design_comment_link = <extracted from task>

# Branch tracking
baseline_branch_id = parent_branch_id
last_fix_branch_id = None  # Set after Step 1

# PR tracking (pre-filled if existing_pr, otherwise set after Step 1)
pr_number = <extracted or None>
pr_url = <extracted or None>
pr_head_branch = <extracted or None>

# Metrics
review_cycle_count = 0  # Increment each time Step 4.1 executes
```

## Workflow Observability

The orchestrator (you, following this skill) **must post a status comment on the PR (or issue, if PR doesn't exist yet) after every step completes**. This ensures the workflow is fully traceable from the thread alone.

**Status comment format:**

```bash
gh pr comment {pr_number} --body-file - <<'STATUS_EOF'
<!-- pantheon-resolve-status:step-{step_name}:cycle-{review_cycle_count} -->

**Pantheon Resolve Workflow — {step_name}** (Cycle {review_cycle_count})

- **Branch ID**: `{branch_id}`
- **Agent**: {agent_type}
- **Outcome**: {outcome summary}
- **Next**: {what happens next}
STATUS_EOF
```

For Step 1 (before PR exists in `new_issue` mode): post on the issue instead, then switch to the PR for subsequent steps.

---

## Workflow

### Step 1: Implement Solution

**Purpose**: Read the approved design from the GitHub comment, then implement with expert workflow discipline.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"claude_code"`
- `num_branches`: `1`
- `parent_branch_id`: `baseline_branch_id`

**Construct prompt based on `entry_mode`:**

**If `entry_mode = "new_issue"`:**

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

=== PHASE 1: READ THE APPROVED DESIGN ===

Fetch the approved solution design from the GitHub issue comment:

gh api "{design_comment_api_url}" --jq .body

(where {design_comment_api_url} is the API URL derived from {design_comment_link})

Read and internalize the full design — root cause, approach, files to change, edge cases, test strategy, and risks.

=== PHASE 2: SYNC CODE ===

Pull the latest code from master branch.

=== PHASE 3: IMPLEMENT ===

WORKING METHOD (CRITICAL):
Do not rush to write code.
First, make sure you fully understand the issue and the approved design.
Then, design the best implementation strategy based on the solution design.
You are a Linus bigfan: use KISS (accurate, rigorous, concise) to find the best simple, robust, minimal-change strategy.
Only after the strategy is clear should you implement.
If new constraints appear during implementation, pause and re-evaluate the strategy before continuing.

Implement the solution following the approved design:

1. Follow the expert method above and the approved solution design
2. Apply KISS principle: accurate, rigorous, and concise
3. Self-review your diff (correctness, edge cases, compatibility)
4. Run the smallest relevant tests/build to verify basic functionality
5. Create a NEW PR:
   - Use `gh pr create`
   - Include a clear title and description referencing {issue_link}
6. Handle GitHub CLI auth:
   - If `gh` is unauthorized (token expired/invalid), retry once
   - If still unauthorized: commit locally, keep the branch, and output GH_AUTH_EXPIRED mode

=== OUTPUT ===

Output exactly ONE of the following modes:

--- Success mode ---
IMPLEMENTATION_SUCCESS
PR_URL=<url>
PR_NUMBER=<number>
PR_HEAD_BRANCH=<branch>

--- GH auth expired mode ---
GH_AUTH_EXPIRED
LOCAL_COMMIT=<sha>
RETRY_PUSH_BRANCH=<branch>

--- Implementation blocked mode (use ONLY if design is fundamentally flawed) ---
IMPLEMENTATION_BLOCKED
REASON=<why the design doesn't work; requires re-design>
```

**If `entry_mode = "existing_pr"`:**

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

=== PHASE 1: READ THE APPROVED DESIGN ===

Fetch the approved solution design from the GitHub issue comment:

gh api "{design_comment_api_url}" --jq .body

Read and internalize the full design — root cause, approach, files to change, edge cases, test strategy, and risks.

=== PHASE 2: SYNC CODE ===

Checkout the existing PR branch: {pr_head_branch}

=== PHASE 3: IMPLEMENT ===

WORKING METHOD (CRITICAL):
Do not rush to write code.
First, understand the current PR and the approved design for improvements.
Then, design the best implementation strategy.
You are a Linus bigfan: use KISS (accurate, rigorous, concise) to find the best simple, robust path.
Only after the strategy is clear should you implement.
If new constraints appear during implementation, pause and re-evaluate the strategy before continuing.

Implement the improvements following the approved design:

1. Follow the expert method above and the approved solution design
2. Apply KISS principle: accurate, rigorous, and concise
3. Self-review your diff (correctness, edge cases, compatibility)
4. Run the smallest relevant tests/build to verify basic functionality
5. PR Management:
   - Checkout existing PR branch: `gh pr checkout {pr_number}` (or `git checkout {pr_head_branch}`)
   - Commit your changes
   - Push to existing branch: `git push`
6. Handle GitHub CLI auth:
   - If `gh` is unauthorized (token expired/invalid), retry once
   - If still unauthorized: commit locally, keep the branch, and output GH_AUTH_EXPIRED mode

=== OUTPUT ===

Output exactly ONE of the following modes:

--- Success mode ---
IMPLEMENTATION_SUCCESS
PR_URL=<url>
PR_NUMBER=<number>
PR_HEAD_BRANCH=<branch>

--- GH auth expired mode ---
GH_AUTH_EXPIRED
LOCAL_COMMIT=<sha>
RETRY_PUSH_BRANCH={pr_head_branch}

--- Implementation blocked mode (use ONLY if design is fundamentally flawed) ---
IMPLEMENTATION_BLOCKED
REASON=<why the design doesn't work; requires re-design>
```

**Wait for completion**, then:

1. Parse output
2. Set `last_fix_branch_id = <branch_id from Step 1>`
3. **Post orchestrator status comment** (on issue if `new_issue` and no PR yet, on PR if available):
   - Step: `implement`
   - Branch ID: `last_fix_branch_id`
   - Agent: `claude_code`
   - Outcome: `IMPLEMENTATION_SUCCESS` / `GH_AUTH_EXPIRED` / `IMPLEMENTATION_BLOCKED`
   - Next: what follows

4. If `IMPLEMENTATION_SUCCESS`:
   - Extract and store `pr_url`, `pr_number`, `pr_head_branch`
   - Proceed to Step 2

5. If `GH_AUTH_EXPIRED`:
   - Start ONE recovery exploration from `last_fix_branch_id`:
     ```
     Do NOT change code. Use existing local commits only.
     Push branch {retry_push_branch} and create/update PR using gh.
     If a PR for this branch already exists, reuse it.

     Output:
     IMPLEMENTATION_SUCCESS
     PR_URL=<url>
     PR_NUMBER=<number>
     PR_HEAD_BRANCH=<branch>
     ```
   - Wait for completion, extract PR info, proceed to Step 2

5. If `IMPLEMENTATION_BLOCKED`:
   - Log the reason
   - **Output to orchestrator**:
     ```
     IMPLEMENTATION_BLOCKED
     REASON=<reason>
     ```
   - The orchestrator should re-run the design skill with the blocker as additional context

---

### Step 2: Review (P0/P1 Bug Hunt + CI Check)

**Purpose**: Rigorously review the PR changes for critical issues and verify CI status.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `last_fix_branch_id`

**Prompt**:

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

Review PR #{pr_number} (related to: {issue_link}) with scientific rigor.

=== REVIEW PRINCIPLES ===

1. Treat this like a scientific investigation: read as much as needed, explain what the code actually does (don't guess)
2. Only accept a P0/P1 finding when code evidence + reachability justify it
3. Default stance: assume no critical issues unless proven otherwise

=== REVIEW CHECKLIST ===

1. Correctness: Does the fix address the root cause? Are there logical errors?
2. Edge cases: Are boundary conditions handled? What about error paths?
3. Compatibility: Does this break existing behavior or APIs?
4. Regressions: Could this introduce new bugs in other code paths?
5. Performance: Are there performance implications?
6. Security: Are there security vulnerabilities (injection, XSS, auth bypass, etc.)?
7. Testing: If the original issue was a failing test, rerun that test on the current PR HEAD to verify the fix

=== CI STATUS CHECK ===

Check the CI status of the PR:

gh pr checks {pr_number} --watch --fail-fast

If CI is still running, wait for it to complete. Report any CI failures as findings:
- If a CI failure is caused by the PR changes: report as P0/P1 finding with evidence
- If a CI failure is a known flaky test or pre-existing failure: note it but do NOT report as P0/P1

=== OUTPUT ===

If you find any P0 or P1 issues (including CI failures caused by PR changes), output:

P0_P1_FINDINGS
BEGIN_P0_P1_FINDINGS
<list each finding with:>
- Severity: P0 or P1
- Description: What is the issue?
- Code evidence: Exact file:line and why it's a problem
- Reachability: How is this triggered? (default config / common config / edge case)
- Blast radius: What is the impact? (availability / correctness / data / security / performance)
END_P0_P1_FINDINGS

If no P0/P1 issues found, output exactly:
NO_P0_P1

IMPORTANT: Do NOT post PR comments or create GitHub issues in this step.
```

**Wait for completion**, then:

1. Parse output
2. Do NOT update `last_fix_branch_id` (Review is read-only)
3. **Post orchestrator status comment** on the PR:
   - Step: `review`
   - Branch ID: the review branch
   - Agent: `codex`
   - Outcome: `NO_P0_P1` or `P0_P1_FINDINGS` (with count of findings)
   - CI status: pass/fail/not-checked
   - Next: what follows
4. If `NO_P0_P1`:
   - Post workflow completion comment (see "Workflow Completion Comment" below)
   - **Workflow complete** (no blocking issues found)
5. If `P0_P1_FINDINGS`: Extract findings, proceed to Step 3

---

### Step 3: Verify (Triage & Scope)

**Purpose**: Validate findings and decide what must be fixed in this PR vs deferred.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `last_fix_branch_id`

**Prompt**:

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

Verify the P0/P1 findings from the review for PR #{pr_number}.

=== INPUT: REVIEW FINDINGS ===

{paste entire content between BEGIN_P0_P1_FINDINGS and END_P0_P1_FINDINGS from Step 2}

=== VERIFICATION PRINCIPLES ===

Default stance: Each finding may be a misread, misunderstanding, or edge case—unless code evidence forces you to accept it.

Read as much as needed. Treat analysis like a scientific experiment: explain what the code does (don't guess), challenge assumptions, confront gaps in understanding.

=== TRIAGE PROCESS ===

For EACH finding, perform the following triage:

1. **Validity**: Confirm it is real on current PR HEAD
   - Is the issue actually present in the code?
   - Is it reachable in realistic scenarios?
   - Is the severity assessment correct?

2. **Origin**: Best-effort determination
   - Introduced by this PR? (check git diff)
   - Pre-existing on master? (check base branch)

3. **Fix Difficulty & Risk**:
   - Difficulty: S (small) / M (medium) / L (large)
   - Risk: low / med / high

4. **Scope Decision** (choose exactly ONE per finding):

   - **FIX_IN_THIS_PR**: Must be fixed before merge
     - Issue is introduced by this PR, OR
     - Merging makes things worse, OR
     - P0/P1 that must be addressed now

   - **DEFER_CREATE_ISSUE**: Valid but does NOT block this PR
     - Not introduced by this PR and merge doesn't worsen it, OR
     - Fix is large/risky and better handled separately

   - **INVALID_OR_ALREADY_FIXED**: Not a real issue
     - Not valid, not reachable, not actually P0/P1, OR
     - Already fixed by current HEAD, OR
     - Duplicate of existing issue

=== GITHUB ISSUE CREATION ===

For every finding marked DEFER_CREATE_ISSUE:

1. Extract repo name:

   REPO=$(gh pr view {pr_number} --json baseRepository --jq .baseRepository.nameWithOwner)

2. Search for existing issues (avoid duplicates):

   gh issue list -R "$REPO" --search "<keywords> in:title,body state:open" --limit 10

3. If matching open issue exists:
   - Do NOT create new issue
   - Optionally add comment with new evidence + link to PR #{pr_number}
   - Use existing issue URL

4. If no match, create new issue:

   gh issue create -R "$REPO" --title "<title>" --body "<body>"

   Body must include: code evidence, repro steps, impact, link to PR #{pr_number}

=== PR COMMENT (IDEMPOTENT) ===

Post ONE summary comment on the PR (idempotent per PR HEAD SHA):

1. Get PR HEAD SHA:

   HEAD_SHA=$(gh pr view {pr_number} --json headRefOid --jq .headRefOid)

2. Check if comment already exists:
   - Search for existing comment containing: `<!-- pantheon-verify:$HEAD_SHA -->`
   - If found, do NOT post again (comment is idempotent per SHA)

3. Post comment via stdin (preserves formatting):

   gh pr comment {pr_number} --body-file - <<'EOF'
<!-- pantheon-verify:$HEAD_SHA -->

## Review Verification Summary

### FIX_IN_THIS_PR (blocking merge)
<list each item with: severity, brief rationale, difficulty/risk>

### DEFER_CREATE_ISSUE (tracked separately)
<list each item with: issue link, brief rationale>

### INVALID_OR_ALREADY_FIXED
<brief rationale for each>
EOF

=== OUTPUT ===

If NO findings are marked FIX_IN_THIS_PR, output:
NO_IN_SCOPE_P0_P1

Otherwise, output:
IN_SCOPE_P0_P1
BEGIN_IN_SCOPE_P0_P1
<list only the findings marked FIX_IN_THIS_PR, with full details: severity, description, code evidence, fix guidance>
END_IN_SCOPE_P0_P1
```

**Wait for completion**, then:

1. Parse output
2. Do NOT update `last_fix_branch_id` (Verify is read-only)
3. **Post orchestrator status comment** on the PR:
   - Step: `verify`
   - Branch ID: the verify branch
   - Agent: `codex`
   - Outcome: `NO_IN_SCOPE_P0_P1` or `IN_SCOPE_P0_P1` (with triage breakdown: N fix / N defer / N invalid)
   - Next: what follows
4. If `NO_IN_SCOPE_P0_P1`:
   - Post workflow completion comment (see "Workflow Completion Comment" below)
   - **Workflow complete** (all issues are deferred or invalid)
5. If `IN_SCOPE_P0_P1`: Extract in-scope issues, proceed to Step 4

---

### Step 4: Fix Loop (Iterate Until Clean)

**Purpose**: Fix in-scope P0/P1 issues, then re-review until clean.

**Loop structure**:

```
WHILE in-scope P0/P1 issues exist:
    1. Fix the issues
    2. Review again (Step 2)
    3. If NO_P0_P1: break
    4. Verify again (Step 3)
    5. If NO_IN_SCOPE_P0_P1: break
END WHILE
```

**4.1: Fix In-Scope Issues**

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"claude_code"`
- `num_branches`: `1`
- `parent_branch_id`: `last_fix_branch_id`

**Prompt**:

```
=== GOLDEN RULE ===

Don't patch, don't workaround, don't add legacy/fallback code. Design a clean architecture. Solve the task thoroughly.

Fix the following in-scope P0/P1 issues for PR #{pr_number}:

=== ISSUES TO FIX ===

{paste entire content between BEGIN_IN_SCOPE_P0_P1 and END_IN_SCOPE_P0_P1 from Step 3}

=== REQUIREMENTS ===

1. Do not rush into code changes
2. First understand each finding and the affected code paths
3. Then design the best fix strategy before editing: you are a Linus bigfan, and use KISS (accurate, rigorous, concise) to find the best simple, robust path
4. If new constraints are discovered, pause and re-evaluate the strategy before continuing
5. Fix each issue using KISS principle: accurate, rigorous, concise
6. Do NOT introduce new bugs or regressions
7. Self-review your changes
8. Run smallest relevant tests/build

9. PR Management:
   - Do NOT create a new PR
   - Checkout existing PR branch: `gh pr checkout {pr_number}` (or `git checkout {pr_head_branch}`)
   - Commit your fixes
   - Push to existing branch: `git push`

10. Handle GitHub CLI auth:
   - If `gh` unauthorized: retry once
   - If still unauthorized: commit locally, output GH_AUTH_EXPIRED mode

=== OUTPUT ===

Success mode:
FIX_SUCCESS

GH auth expired mode:
GH_AUTH_EXPIRED
LOCAL_COMMIT=<sha>
RETRY_PUSH_BRANCH={pr_head_branch}
```

**Wait for completion**, then:

1. Set `last_fix_branch_id = <branch_id from this Fix run>`
2. Increment `review_cycle_count += 1`
3. **Post orchestrator status comment** on the PR:
   - Step: `fix`
   - Branch ID: `last_fix_branch_id`
   - Agent: `claude_code`
   - Cycle: `{review_cycle_count}`
   - Outcome: `FIX_SUCCESS` or `GH_AUTH_EXPIRED`
   - Next: re-review

4. If `GH_AUTH_EXPIRED`:
   - Start recovery exploration from `last_fix_branch_id`:
     ```
     Do NOT change code. Use existing local commits.
     Push {pr_head_branch} and sync PR using gh.
     Output: FIX_SUCCESS
     ```
   - Wait for completion

5. Proceed to 4.2

**4.2: Re-Review**

Repeat **Step 2** (Review) with `parent_branch_id = last_fix_branch_id`.

Wait and parse output:
- If `NO_P0_P1`:
  - Post workflow completion comment (see "Workflow Completion Comment" below)
  - **Exit loop, workflow complete**
- If `P0_P1_FINDINGS`: Proceed to 4.3

**4.3: Re-Verify**

Repeat **Step 3** (Verify) with `parent_branch_id = last_fix_branch_id`.

Wait and parse output:
- If `NO_IN_SCOPE_P0_P1`:
  - Post workflow completion comment (see "Workflow Completion Comment" below)
  - **Exit loop, workflow complete**
- If `IN_SCOPE_P0_P1`: Extract issues, go back to 4.1 (Fix again)

**Loop termination**: Exit when either Review finds no P0/P1, or Verify finds no in-scope P0/P1.

---

## Workflow Completion Comment

When the workflow completes (no in-scope P0/P1 issues remain), post a completion comment on the PR:

```bash
gh pr comment {pr_number} --body "$(cat <<'EOF'
## Pantheon Issue Resolution Complete

This PR has been analyzed and iterated through the Fix/Review/Verify loop until no in-scope P0/P1 blockers remain.

**Final Status:**
- No P0/P1 blocking issues found in latest review
- All identified issues have been either fixed or deferred to separate issues
- PR is ready for final human review and merge

**Workflow Summary:**
- Issue analyzed: {issue_link}
- PR created/updated: #{pr_number}
- Review cycles completed: {review_cycle_count}

---
Automated by [pantheon-issue-resolve](https://github.com/pingcap-inc/pantheon-agents/tree/main/skills/pantheon-issue-resolve)
EOF
)"
```

**Replace placeholders with actual variable values:**
- `{issue_link}` → value of `issue_link` variable
- `{pr_number}` → value of `pr_number` variable
- `{review_cycle_count}` → value of `review_cycle_count` variable

---

## Summary: Information Flow

```
Step 1 (Implement) ← reads design from design_comment_link
  ↓ outputs: PR info (pr_number, pr_url, pr_head_branch)
Step 2 (Review + CI Check) ← knows PR info
  ↓ outputs: P0_P1_FINDINGS (or NO_P0_P1)
Step 3 (Verify) ← receives P0_P1_FINDINGS
  ↓ outputs: IN_SCOPE_P0_P1 (or NO_IN_SCOPE_P0_P1)
Step 4 (Fix Loop) ← receives IN_SCOPE_P0_P1
  ↓ iterates: Fix → Review → Verify
  ↓ workflow complete when no in-scope P0/P1 remain
```

## Recovery & Error Handling

### Pantheon Exploration Failures

If a Pantheon branch fails (status = `failed`):

1. Check `branch_output` for error details
2. Determine if error is transient (network, resource) or permanent (code crash)
3. If transient: retry the same step from the same `parent_branch_id`
4. If permanent: investigate root cause, fix if possible, or escalate to user

### GitHub Auth Failures

Handled automatically via `GH_AUTH_EXPIRED` output mode and recovery explorations (see Step 1 and Step 4.1).

### Implementation Blocked

If Step 1 outputs `IMPLEMENTATION_BLOCKED`:
- The solution design is fundamentally flawed
- The orchestrator (AGENTS.md) should re-run `pantheon-solution-design` with the blocker reason as additional context

## Notes

- **Agent selection**:
  - Steps 1, 4.1 (Implementation, Fix): Use `agent="claude_code"` for coding tasks
  - Steps 2, 3 (Review, Verify): Use `agent="codex"` for analytical/review tasks
- **Design input**: The agent reads the design from `design_comment_link` using `gh api` — GitHub is the work ledger, not prompt blobs
- **Sequential explorations**: This workflow uses sequential explorations by design (each depends on previous results)
- **Extensibility**: This workflow can be extended to support refactoring, performance optimization, or feature development (not just bug fixes)
