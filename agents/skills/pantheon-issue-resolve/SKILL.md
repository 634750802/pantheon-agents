---
name: pantheon-issue-resolve
description: "Evidence-first issue resolution workflow: analyze deeply, implement fixes, review rigorously (P0/P1 bug hunt), and verify scope until no blocking issues remain. Supports both new issues and existing PRs."
---

# Pantheon Issue Resolve

## Overview

A rigorous, evidence-first workflow for resolving software issues or improving existing PRs. The workflow consists of:

1. **Deep Analysis** → Understand root cause and design solution (can use opus for stronger reasoning)
2. **Implementation** → Execute the solution design (can use sonnet for efficiency)
3. **Review** → P0/P1 bug hunt on the changes
4. **Verify** → Triage findings and scope decisions
5. **Fix Loop** → Iterate until no in-scope blockers remain
6. **Pre-merge Validation** → Build, test, and CI checks

## Prerequisites

### Terminology

- **Pantheon branch**: A long-running sandbox environment (takes hours to complete)
- **PR**: GitHub Pull Request
- **P0/P1**: Critical/high-severity issues (see definitions below)
- **In-scope**: Issues that must be fixed in this PR before merge
- **Deferred**: Valid issues tracked in separate GitHub issues

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

## Inputs

Provide **exactly ONE** of the following entry points:

- `issue_link` (string): GitHub issue URL or identifier
- `existing_pr_link` (string): GitHub PR URL or number

**Required parameters:**
- `project_name` (string): Pantheon project name
- `parent_branch_id` (string): Starting Pantheon branch ID (sandbox baseline)

**Variable initialization:**
```python
# At workflow start:
baseline_branch_id = parent_branch_id
analysis_branch_id = None  # Set after Step 1
last_fix_branch_id = None  # Set after Step 2, updated after each Fix
pr_number = None           # Set after Step 2
pr_url = None              # Set after Step 2
pr_head_branch = None      # Set after Step 2
```

## Workflow

### Step 1: Deep Analysis

**Purpose**: Sync code, analyze deeply, and design solution (or conclude no action needed).

**Model recommendation**: Use `opus` for stronger analytical reasoning.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `baseline_branch_id`
- `model`: `"opus"` (optional, for better analysis)

**Prompt**:

```
=== PHASE 1: SYNC CODE ===

Sync to the latest code:
- If starting from issue ({issue_link}): pull latest from master branch
- If starting from existing PR ({existing_pr_link}): checkout the PR branch

Input context:
- Issue: {issue_link} (if provided)
- Existing PR: {existing_pr_link} (if provided)

=== PHASE 2: DEEP ANALYSIS ===

Analyze the target with scientific rigor. Default stance: every claim may be invalid until evidence proves otherwise.

[IF starting from issue_link]:
1. Restate the issue claim precisely (expected vs actual, triggering inputs/config)
2. Locate relevant code paths and exact conditions to reach them
3. Determine reachability under default/common production configs
4. Identify root cause with code-causal chain (why this, not alternatives)
5. Search for counter-evidence (feature gates, guards, fallbacks, test-only paths, unreachable branches)
6. Assess impact and blast radius (unavailability, correctness, data safety, security, performance)
7. Check for broader systemic issues (same pattern elsewhere, shared abstractions)

[IF starting from existing_pr_link]:
1. Understand the PR's intent and current implementation
2. Analyze code changes (what changed, why, impact)
3. Identify potential issues or improvement opportunities
4. Assess code quality, edge cases, and compatibility

[FOR BOTH]:
- If the report mentions a failing test, identify the minimal failing case and rerun it on current HEAD to confirm repro (or prove non-repro). Capture exact failure output.

=== PHASE 3: CONCLUSION ===

Based on your analysis, output exactly ONE of the following:

--- Option A: No action needed ---
VERDICT=NO_ACTION_NEEDED
REASON=<brief explanation: not a bug / already fixed / duplicate / out of scope / test-only>

--- Option B: Action required ---
VERDICT=NEED_FIX
(or VERDICT=NEED_IMPROVEMENT if starting from existing_pr_link)

BEGIN_SOLUTION_DESIGN
root_cause: <one-line root cause>
severity: <P0 / P1 / P2 / feature>
approach: <solution approach using KISS principle>
files_to_change:
  - file: <path>
    changes: <what to change and why>
  - file: <path>
    changes: <what to change and why>
test_strategy: <how to verify the fix>
risks: <potential risks or edge cases>
alternatives_rejected: <why other approaches were not chosen>
END_SOLUTION_DESIGN
```

**Wait for completion** (see Waiting/Polling), then:

1. Parse output
2. Set `analysis_branch_id = <branch_id from Step 1>`
3. If `VERDICT=NO_ACTION_NEEDED`: **Stop workflow**
4. If `VERDICT=NEED_FIX` or `VERDICT=NEED_IMPROVEMENT`:
   - Extract `SOLUTION_DESIGN` block (everything between BEGIN and END)
   - Proceed to Step 2

---

### Step 2: Implement Solution

**Purpose**: Execute the solution design from Step 1.

**Model recommendation**: Use `sonnet` for cost-efficiency (analysis is already done).

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `analysis_branch_id`
- `model`: `"sonnet"` (optional)

**Prompt**:

```
=== CONTEXT: SOLUTION DESIGN ===

The analysis phase has identified the following solution:

{paste entire SOLUTION_DESIGN block from Step 1}

=== YOUR TASK: IMPLEMENT ===

Implement the solution following the design above:

1. Follow the approach exactly as designed
2. Make changes to the files listed, in the manner described
3. Apply KISS principle: accurate, rigorous, and concise
4. Self-review your diff (correctness, edge cases, compatibility)
5. Run the smallest relevant tests/build to verify basic functionality
6. Manage the PR:

   [IF starting from issue_link (no existing PR)]:
   - Create a NEW PR using `gh pr create`
   - Include a clear title and description referencing {issue_link}

   [IF starting from existing_pr_link]:
   - Checkout the existing PR branch: `gh pr checkout {existing_pr_link}`
   - Commit your changes
   - Push to the existing branch: `git push`

7. Handle GitHub CLI auth:
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
REASON=<why the design doesn't work; requires re-analysis>
```

**Wait for completion**, then:

1. Parse output
2. Set `last_fix_branch_id = <branch_id from Step 2>`

3. If `IMPLEMENTATION_SUCCESS`:
   - Extract and store `pr_url`, `pr_number`, `pr_head_branch`
   - Proceed to Step 3

4. If `GH_AUTH_EXPIRED`:
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
   - Wait for completion, extract PR info, proceed to Step 3

5. If `IMPLEMENTATION_BLOCKED`:
   - Log the reason
   - **Stop workflow** (requires re-analysis or user intervention)

---

### Step 3: Review (P0/P1 Bug Hunt)

**Purpose**: Rigorously review the PR changes for critical issues.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `last_fix_branch_id`

**Prompt**:

```
Review PR #{pr_number} for issue {issue_link} with scientific rigor.

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

=== OUTPUT ===

If you find any P0 or P1 issues, output:

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
3. If `NO_P0_P1`: **Skip to Step 6** (Pre-merge Validation)
4. If `P0_P1_FINDINGS`: Extract findings, proceed to Step 4

---

### Step 4: Verify (Triage & Scope)

**Purpose**: Validate findings and decide what must be fixed in this PR vs deferred.

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `last_fix_branch_id`

**Prompt**:

```
Verify the P0/P1 findings from the review for PR #{pr_number}.

=== INPUT: REVIEW FINDINGS ===

{paste entire content between BEGIN_P0_P1_FINDINGS and END_P0_P1_FINDINGS from Step 3}

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
   ```bash
   REPO=$(gh pr view {pr_number} --json baseRepository --jq .baseRepository.nameWithOwner)
   ```

2. Search for existing issues (avoid duplicates):
   ```bash
   gh issue list -R "$REPO" --search "<keywords> in:title,body state:open" --limit 10
   ```

3. If matching open issue exists:
   - Do NOT create new issue
   - Optionally add comment with new evidence + link to PR #{pr_number}
   - Use existing issue URL

4. If no match, create new issue:
   ```bash
   gh issue create -R "$REPO" --title "<title>" --body "<body>"
   ```
   - Body must include: code evidence, repro steps, impact, link to PR #{pr_number}

=== PR COMMENT (IDEMPOTENT) ===

Post ONE summary comment on the PR (idempotent per PR HEAD SHA):

1. Get PR HEAD SHA:
   ```bash
   HEAD_SHA=$(gh pr view {pr_number} --json headRefOid --jq .headRefOid)
   ```

2. Check if comment already exists:
   - Search for existing comment containing `<!-- pantheon-verify:$HEAD_SHA -->`
   - If found, do NOT post again

3. Post comment via stdin (preserves formatting):
   ```bash
   gh pr comment {pr_number} --body-file - <<'EOF'
   <!-- pantheon-verify:$HEAD_SHA -->

   ## Review Verification Summary

   ### ✅ FIX_IN_THIS_PR (blocking merge)
   <list each item with: severity, brief rationale, difficulty/risk>

   ### 📋 DEFER_CREATE_ISSUE (tracked separately)
   <list each item with: issue link, brief rationale>

   ### ❌ INVALID_OR_ALREADY_FIXED
   <brief rationale for each>
   EOF
   ```

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
3. If `NO_IN_SCOPE_P0_P1`: **Skip to Step 6** (Pre-merge Validation)
4. If `IN_SCOPE_P0_P1`: Extract in-scope issues, proceed to Step 5

---

### Step 5: Fix Loop (Iterate Until Clean)

**Purpose**: Fix in-scope P0/P1 issues, then re-review until clean.

**Loop structure**:

```
WHILE in-scope P0/P1 issues exist:
    1. Fix the issues
    2. Review again (Step 3)
    3. If NO_P0_P1: break
    4. Verify again (Step 4)
    5. If NO_IN_SCOPE_P0_P1: break
END WHILE
```

**5.1: Fix In-Scope Issues**

**Call**: `functions.mcp__pantheon__parallel_explore`
- `agent`: `"codex"`
- `num_branches`: `1`
- `parent_branch_id`: `last_fix_branch_id`

**Prompt**:

```
Fix the following in-scope P0/P1 issues for PR #{pr_number}:

=== ISSUES TO FIX ===

{paste entire content between BEGIN_IN_SCOPE_P0_P1 and END_IN_SCOPE_P0_P1 from Step 4}

=== REQUIREMENTS ===

1. Fix each issue using KISS principle: accurate, rigorous, concise
2. Do NOT introduce new bugs or regressions
3. Self-review your changes
4. Run smallest relevant tests/build

5. PR Management:
   - Do NOT create a new PR
   - Checkout existing PR branch: `gh pr checkout {pr_number}` (or `git checkout {pr_head_branch}`)
   - Commit your fixes
   - Push to existing branch: `git push`

6. Handle GitHub CLI auth:
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

2. If `GH_AUTH_EXPIRED`:
   - Start recovery exploration from `last_fix_branch_id`:
     ```
     Do NOT change code. Use existing local commits.
     Push {pr_head_branch} and sync PR using gh.
     Output: FIX_SUCCESS
     ```
   - Wait for completion

3. Proceed to 5.2

**5.2: Re-Review**

Repeat **Step 3** (Review) with `parent_branch_id = last_fix_branch_id`.

Wait and parse output:
- If `NO_P0_P1`: **Exit loop, proceed to Step 6**
- If `P0_P1_FINDINGS`: Proceed to 5.3

**5.3: Re-Verify**

Repeat **Step 4** (Verify) with `parent_branch_id = last_fix_branch_id`.

Wait and parse output:
- If `NO_IN_SCOPE_P0_P1`: **Exit loop, proceed to Step 6**
- If `IN_SCOPE_P0_P1`: Extract issues, go back to 5.1 (Fix again)

**Loop termination**: Exit when either Review finds no P0/P1, or Verify finds no in-scope P0/P1.

---

### Step 6: Pre-merge Validation

**Purpose**: Final validation before merge (build, test, CI).

**This step is NOT a Pantheon exploration** – run these checks in the main workflow (not inside codex).

**6.1: Checkout PR Branch**

```bash
gh pr checkout {pr_number}
# or: git checkout {pr_head_branch}
```

**6.2: Local Build & Test**

Run project-specific build and smoke tests. Examples:

For Rust projects:
```bash
cargo build --release
cargo test
```

For other projects, adapt as needed.

**If local validation fails**:
- Treat failure as a new in-scope issue
- Start a Fix exploration (Step 5.1) to address the failure
- Re-run Review and Verify
- Return to Step 6 after fixes

**6.3: Wait for CI (Required Checks)**

```bash
gh pr checks {pr_number} --required --watch --fail-fast
```

**If CI fails**:

1. List failed checks:
   ```bash
   gh pr checks {pr_number} --required
   ```

2. Inspect failure logs:
   ```bash
   gh run list --branch {pr_head_branch} --limit 20
   gh run view <run-id> --log-failed
   ```

3. Determine failure cause:
   - **Introduced by this PR**: Treat as in-scope issue, start Fix exploration
   - **Flaky/infra issue** (not caused by this PR):
     - Create or reuse GitHub issue to track (use same dedupe workflow as Step 4)
     - Do NOT merge until CI is green
     - Stop workflow

4. If fix is needed:
   - Start Fix exploration (Step 5.1)
   - Re-run Review (Step 3) and Verify (Step 4) if needed
   - Return to Step 6

**6.4: Merge Decision**

If all checks pass:
- Local build ✅
- Local tests ✅
- CI required checks ✅

**Workflow complete**. The PR is ready for merge (manual or automated based on project policy).

## Summary: Information Flow

```
Step 1 (Analyze)
  ↓ outputs: SOLUTION_DESIGN
Step 2 (Implement) ← receives SOLUTION_DESIGN
  ↓ outputs: PR info (pr_number, pr_url, pr_head_branch)
Step 3 (Review) ← knows PR info
  ↓ outputs: P0_P1_FINDINGS (or NO_P0_P1)
Step 4 (Verify) ← receives P0_P1_FINDINGS
  ↓ outputs: IN_SCOPE_P0_P1 (or NO_IN_SCOPE_P0_P1)
Step 5 (Fix Loop) ← receives IN_SCOPE_P0_P1
  ↓ iterates: Fix → Review → Verify
Step 6 (Pre-merge) ← final validation
```

## Recovery & Error Handling

### Pantheon Exploration Failures

If a Pantheon branch fails (status = `failed`):

1. Check `branch_output` for error details
2. Determine if error is transient (network, resource) or permanent (code crash)
3. If transient: retry the same step from the same `parent_branch_id`
4. If permanent: investigate root cause, fix if possible, or escalate to user

### GitHub Auth Failures

Handled automatically via `GH_AUTH_EXPIRED` output mode and recovery explorations (see Step 2 and Step 5.1).

### Implementation Blocked

If Step 2 outputs `IMPLEMENTATION_BLOCKED`:
- The solution design from Step 1 is fundamentally flawed
- Requires manual intervention or re-running Step 1 with more context

### Infinite Loop Protection

If Step 5 (Fix Loop) iterates more than **5 times**:
- Log warning
- Output summary of remaining issues
- Stop workflow and escalate to user (may require different approach or manual intervention)

## Notes

- **Model selection**: Step 1 (Analysis) benefits from `opus`; other steps can use `sonnet` for efficiency
- **Parallel explorations**: This workflow uses sequential explorations by design (each depends on previous results)
- **Cost optimization**: Using `sonnet` for implementation/review/verify saves significant cost vs `opus` everywhere
- **Extensibility**: This workflow can be extended to support refactoring, performance optimization, or feature development (not just bug fixes)
