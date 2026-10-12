# agents-md

The owner's user-level agent instructions, one file per machine and account. Claude Code reads each as
`~/.claude/CLAUDE.md` and Codex as `~/.codex/AGENTS.md` (on accounts that have both, one is a symlink to the other).

| path | machine | account | distributed |
|---|---|---|---|
| `hosts/fcvm-metal-arm/ubuntu/AGENTS.md` | fcvm-metal-arm | `ubuntu` | automatically |
| `hosts/nextjs-dev/ejc3/AGENTS.md` | nextjs-dev | `ejc3` | automatically |
| `hosts/jumpbox/ubuntu/AGENTS.md` | the main jumpbox | `ubuntu` | by hand, by the jumpbox agent |

## How a change gets in

1. **Propose it here, as a pull request.** Never edit the installed file on a machine: the next distribution replaces
   it with what is on `main`. Agents on any box: clone this repository, change the file, open a pull request (a draft
   while you are working, then `gh pr ready`).
2. **The jumpbox merges it.** The PR and issue watch on the main jumpbox (`ejc3/aws` `scripts/pr-watch/SKILL.md`)
   reviews every ready pull request here, gets the reviewers to sign off, and merges it. Nothing else merges here.
3. **Terraform distributes it.** `ejc3/aws` (`agents-md.tf`) reads each automatically distributed file from `main` and
   installs it on its machine and account. A merged change reaches the box at the next apply on the jumpbox, which the
   watch runs right after the merge.

## What may be written here

These files are read by agents that open public pull requests, and this repository could be shared. Keep out of it:
email addresses, secrets and tokens, public IP addresses, unreleased model names and code names, and
anything else copied from a live session. Alias names (`fcvm-arm`, `nextjs`), account names and the public model names
are fine.
