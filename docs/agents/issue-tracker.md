# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- **Close an issue**: `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v`; `gh` does this automatically inside the clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

When enabled, PRs use the corresponding `gh pr` commands and the same triage labels. GitHub shares one number space across issues and PRs, so resolve an ambiguous `#42` with `gh pr view 42`, then fall back to `gh issue view 42`.

## Skill operations

- When a skill says "publish to the issue tracker," create a GitHub issue.
- When a skill says "fetch the relevant ticket," run `gh issue view <number> --comments`.
- Wayfinder maps use the `wayfinder:map` label.
- Child tickets use `wayfinder:<type>`, GitHub sub-issues where available, and native issue dependencies.
- Claim a ticket with `gh issue edit <number> --add-assignee @me`.
