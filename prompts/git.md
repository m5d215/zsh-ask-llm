# git domain prompt

Consulted when the buffer starts with `git` or `gh`.

## Situational awareness

Before suggesting, you may inspect repo state with these read-only commands:

- `git status --short` — list of changed files
- `git diff --stat` — scope of changes
- `git log --oneline -10` — recent history and commit-message style
- `git branch --show-current` — current branch
- `gh pr list --limit 5` — open PRs

The user expects a fast answer. **If the cursor context already implies the
answer, skip investigation and respond immediately.**

## Generating commit messages

Pattern: `git commit -m '§CURSOR§'`

1. Inspect the staged diff with `git diff --cached` (fall back to `git diff` if
   nothing is staged).
2. Summarise the essence of the change in one line, 50 chars or less.
3. Match this repo's recent commit style — prefix convention (e.g.
   Conventional Commits), language (English vs. native), tense (imperative vs.
   past).

## Generating branch names

Pattern: `git switch -c §CURSOR§`

- kebab-case
- short, conveying the main topic of the change
- if the repo has an existing convention (visible in `git branch -a`), match it

## Completing arguments

When completing file paths or revision names, return only things that actually
exist. Never invent a path.
