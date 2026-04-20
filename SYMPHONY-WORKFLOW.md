---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "cmux-ex-985f827d0563"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
    - Planned
polling:
  interval_ms: 10000
workspace:
  root: ~/projects/cmux-ex/workspaces/symphony
hooks:
  after_create: |
    git clone --depth 1 https://github.com/DejaVu-Cyber/cmux-ex.git .
    git submodule update --init --recursive
    if [ -x ./scripts/setup.sh ]; then
      ./scripts/setup.sh
    fi
agent:
  max_concurrent_agents: 5
  max_turns: 30
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  turn_timeout_ms: 3600000
  stall_timeout_ms: 600000
---

You are working on a Linear ticket `{{ issue.identifier }}` for the `cmux-ex` repository.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch, unless the existing branch/PR is closed or merged.
- Do not repeat already-completed investigation or validation unless it is needed for new changes.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Repo map

This repo is a macOS app built around Swift/AppKit plus Ghostty/libghostty.

Read these files first, in this order:

1. `AGENTS.md` for repo invariants, build rules, testing policy, localization policy, and submodule safety.
2. `CLAUDE.md` for the same project guidance when cross-references point there.
3. `PROJECTS.md` for recent completed work and backlog context.
4. Any spec or design doc linked from the Linear issue description.

Treat the repository as the system of record. Prefer in-repo docs and scripts over assumptions.

## Unattended execution rules

1. This is an unattended orchestration session. Do not ask a human to perform follow-up steps.
2. Only stop early for a true blocker: missing required auth, missing required external service access, or a hard environment limitation that prevents completion.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".
4. Work only inside the issue workspace created for this ticket.

## Step 0: Assess prior work

Before implementing anything, inspect the current state:

1. Run `git log --oneline -10` and `git branch -a`.
2. Run `gh pr list --state open --search "{{ issue.identifier }}"`.
3. If an open PR exists, read all feedback before coding:
   - `gh pr view <PR_NUMBER> --comments`
   - `gh api repos/DejaVu-Cyber/cmux-ex/pulls/<PR_NUMBER>/comments`
   - `gh pr view <PR_NUMBER> --json reviews`
4. Fetch Linear issue comments for human guidance:
   ```bash
   curl -s -X POST https://api.linear.app/graphql \
     -H "Content-Type: application/json" \
     -H "Authorization: $LINEAR_API_KEY" \
     -d '{"query": "{ issue(id: \"{{ issue.id }}\") { comments { nodes { body createdAt user { name } } } } }"}' | python3 -m json.tool
   ```
5. Based on what you find:
   - No prior work: start from the issue description and linked docs.
   - Existing PR with review feedback: address that feedback on the existing branch; do not open a new PR.
   - Existing PR with no feedback: finish validation, push any needed updates, and prepare handoff.

## Build and validation rules

Follow `AGENTS.md` exactly. The important repo-specific rules are:

- Always build debug app changes with `./scripts/reload.sh --tag <tag>`.
- Never run bare `xcodebuild` or launch an untagged `cmux DEV.app`.
- Use a short descriptive tag, usually derived from `{{ issue.identifier }}`.
- Do not run local E2E/UI/python socket tests directly; use GitHub Actions for those.
- Safe local compile verification is a tagged debug build. `xcodebuild -scheme cmux-unit` is allowed only when unit coverage is required and you need a narrow local check.
- If touching UI strings, localize them in `Resources/Localizable.xcstrings`.
- If adding a cmux-owned keyboard shortcut, also update shortcut settings, config support, and docs.
- If modifying a submodule, push the submodule commit to its remote before committing the updated pointer in the parent repo.

## Execution flow

1. If the issue is `Todo`, move it to `In Progress` before coding.
2. Create or reuse exactly one persistent Linear comment titled `## Codex Workpad` and keep it updated in place.
3. Re-read the issue description and all linked docs/spec sections before editing code.
4. Create or reuse a branch for the issue.
   - Preferred branch name: `{{ issue.identifier }}-short-description`.
   - If Linear already provides branch metadata, reuse that branch.
5. Implement the change end-to-end.
6. Validate with the smallest correct verification set:
   - For most app changes: `./scripts/reload.sh --tag <tag>`.
   - For UI/E2E coverage: trigger the appropriate GitHub Actions workflow with `gh workflow run ...`.
   - For review feedback or bugfix follow-ups: rerun the relevant targeted validation only.
7. Commit, push, and open or update a PR.
   - The PR title must include `{{ issue.identifier }}` so Linear can link it correctly.
8. Read PR comments and reviews again after pushing. Address all actionable feedback before handoff.
9. Post a completion summary to the Linear issue.
10. Move the issue to `In Review` only after code, validation, and PR publication are complete.

## GitHub and Linear requirements

- `gh` must be installed and authenticated.
- `$LINEAR_API_KEY` must be present and valid.
- If either GitHub or Linear auth is missing and there is no fallback path, record the blocker in the workpad and stop.

## Workflow states

- `Backlog`: do not touch.
- `Planned`: do not touch.
- `Todo`: move to `In Progress`, then execute.
- `In Progress`: implement, validate, push, open/update PR, comment on Linear, then move to `In Review`.
- `In Review`: wait for human review; do not make fresh changes unless the ticket is moved back to an active state.
- `Done`: terminal; do nothing.

## Workpad template

Use this exact structure for the single persistent Linear workpad comment:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1. First task
- [ ] 2. Second task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] build: `./scripts/reload.sh --tag <tag>`

### Notes

- Short timestamped progress note

### Blockers

- Only include when blocked
````

## Completion summary comment

Write the completion summary to `/tmp/linear-summary-{{ issue.identifier }}.md` and post it to Linear:

```bash
cat > /tmp/linear-summary-{{ issue.identifier }}.md << 'SUMMARY'
## Agent Work Summary

**Status:** Completed | Blocked

### Changes
- Branch: <branch-name>
- PR: <PR URL>
- Summary of edits

### Verification
- `./scripts/reload.sh --tag <tag>`: <result>
- Any GitHub Actions workflows triggered: <result>

### Blockers or issues encountered
- None | <details>
SUMMARY

cat /tmp/linear-summary-{{ issue.identifier }}.md | jq -Rs '{
  query: "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }",
  variables: { id: "{{ issue.id }}", body: . }
}' | curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d @-
```

## Updating Linear issue state

Use `$LINEAR_API_KEY` and the Linear GraphQL API.

Example for fetching state IDs:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "{ team(id: \"d870a028-2819-44c7-a3d7-6d75303f573e\") { states { nodes { id name } } } }"}' | python3 -m json.tool
```

Example for moving the issue:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "mutation { issueUpdate(id: \"{{ issue.id }}\", input: { stateId: \"STATE_ID\" }) { success } }"}'
```

Issue ID for this ticket: {{ issue.id }}
