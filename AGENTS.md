# Agents working in this repository

Read `README.md` first: it lists which file goes to which machine and account, and what may never be written here.

- Change an instruction file by pull request only (draft while working, then `gh pr ready`). The PR and issue watch on
  the main jumpbox reviews, merges and distributes; nothing else merges here, and `main` requires resolved review
  threads and the `review decision` and `content guard` checks.
- `bash scripts/content-guard.sh` must pass before you push: no email addresses, secrets, public IP addresses or
  unreleased model names, in any file.
- Each file is installed whole, replacing what is on the machine. Keep a file self-contained, and change only the file
  for the machine you mean.
