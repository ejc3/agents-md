# Instructions for coding agents

Session values stay out of the repository. A value copied from a working session (a shell, an environment variable, a launch command or a transcript) is not useful to the repository and goes stale: profile names, account names, one-off paths, model names, local ports. Don't put one in a file, a comment, a commit message, or a pull request title, description or review comment. Use a variable or a made-up placeholder (`example-profile`, `example-name`). Where something specific has to be named, use its publicly documented identifier. Check the diff, the commit messages and the PR text before every push.

## Cheaper models for straightforward work

Claude Code here can run three current models. Opus 5.5 is the default. Sonnet 5.5 and Haiku 5.5 are faster and
much cheaper (list price per million tokens, input/output: Opus 5.5 $4/$20, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50 for
prompts up to 100K tokens and $0.50/$2.50 above), so hand them the simple parts and keep Opus for the thinking.

- **Haiku 5.5 (`haiku`)**: mechanical work that is easy to check. Finding and reading files and summarizing them,
  extraction and classification, renames, formatting, lookups, running a command and reporting what it printed, simple
  browser checks. Anthropic: "high-volume, latency-sensitive tasks such as classification, extraction, and routing".
- **Sonnet 5.5 (`sonnet`)**: well-scoped everyday engineering. A bug whose cause is known, a contained change with a
  clear done condition, tests for behaviour that already exists, docs. Anthropic: "the best combination of speed and
  intelligence".
- **Opus 5.5 (stay on it)**: planning and design, debugging where the cause is unknown, security, anything touching
  shared infrastructure, money or credentials, reviewing other agents' work, and the final check before you say done.

How to use them:

- Give a subagent its model on the Agent tool (`model: "haiku"` or `model: "sonnet"`); the main session keeps its own.
  For a long run of simple work, start a session on Sonnet with `claude --model sonnet` (that session only). `/model
  sonnet` inside a session also makes Sonnet the default for later sessions, so `/model opus` when the simple work ends.
- Delegate down, never up. A subagent runs on the session's own model or a cheaper one: Haiku from a Sonnet session,
  Haiku or Sonnet from an Opus session. A Sonnet session never starts an Opus subagent; if the work needs Opus, the
  session itself goes back to Opus (`/model opus`) first.
- A subagent starts with no context: give it the goal, the files, the constraints and what "done" looks like.
- One task per subagent. Check what it did yourself (run the tests, read the diff) before relying on it.
- If a subagent gets it wrong once, do that piece in the main session instead; do not retry the same model.
- Never hand a cheaper model an action that cannot be undone: a deploy, a delete, a push to main, a credential.

## Drafts behind Cloudflare Access always ship (owner, 2026-10-12)

A draft deployed behind a Cloudflare Access gate is ALWAYS okay to push, without asking: staging
`<site>-stage` Workers, prototypes, previews, and test-flight builds (TestFlight to internal testers
included). Getting a working build in front of the owner is part of the task, not a follow-up:
never stop at "merged" or "ready" with the product undeployed. If a credential or permission is
missing, propose it in the same push (a pull request to `ejc3/aws`, which the jumpbox reviews and
applies) rather than reporting the gap and stopping. What "Credentials on this box" below lists as
not reachable from this box stays off it: deploys that need those run from the jumpbox or another
box, so propose the change there or ask the owner. Only a public, ungated production launch needs
the owner's go-ahead.

## Interactive web pages are built on Astryx (owner, 2026-10-17)

New interactive web pages (app chrome and navigation, forms, settings, editors, dialogs, lists)
are built on Astryx, Meta's open-source design system (`@astryxdesign/core`,
github.com/facebook/astryx): React 19 components with pre-built CSS, themed through CSS custom
properties (`defineTheme`), with a CLI made for agents.

- **Pin the exact version** (`"0.7.1"`, not `"^0.7.1"`) of `@astryxdesign/core` and of its CLI,
  `@astryxdesign/cli` (a dev dependency): it is in beta. Upgrade both in a pull request of their own,
  with its codemods (`npx astryx upgrade --apply`).
- **The CLI is `@astryxdesign/cli`, never the unscoped `astryx` package.** That name on npm belongs
  to someone else; `npx astryx` in a project without the CLI installed downloads and runs it. Add the
  CLI first (`npm install --save-dev --save-exact @astryxdesign/cli@0.7.1`), so `npx astryx` runs the
  project's own copy, or call it by its full name (`npx @astryxdesign/cli@0.7.1 ...`).
- **Use the CLI before writing a component.** Run `npx astryx init` once per project, so its
  component index is in that project's `AGENTS.md` or `CLAUDE.md` (whichever the project keeps;
  where one is a symlink to the other, either); look a component up with
  `npx astryx component <Name>`; start a page from `npx astryx template` rather than composing from scratch.
- **One product theme per app.** Change the look with theme tokens or `className`; eject a
  component (`npx astryx swizzle <Name>`) only when a token cannot say it.
- **Not `@astryxdesign/lab`**: it is unpublished and experimental.
- **Not for surfaces with rules of their own**: wall and kiosk screens (TV, e-ink), canvases and
  games, printed sheets, email. Those keep their own stylesheet, and their pages do not load Astryx.
- **Existing projects keep their current UI stack**; move one to Astryx only when the owner asks.

## Credentials on this box

This box's instance role gives agents these, with no key on disk. Load a secret into the environment, never onto a
command line, into a file in a repo or a commit; never print one.

- **Cloudflare logs and metrics** (read-only: Workers Logs, `wrangler tail`, GraphQL Analytics, every zone's analytics):
  `export CLOUDFLARE_API_TOKEN=$(aws secretsmanager get-secret-value --region us-west-1 --secret-id cloudflare-observability-token --query SecretString --output text)`
- **Browserbase** (hosted browsers): JSON secret `browserbase/credentials`; export every key with
  `eval "$(aws secretsmanager get-secret-value --region us-west-1 --secret-id browserbase/credentials --query SecretString --output text | jq -r 'to_entries[] | "export \(.key)=\(.value|@sh)"')"`
- **ElevenLabs** (voice and sound): `games/elevenlabs-api-key`, as `ELEVENLABS_API_KEY`.
- **Colton Games, non-production**: `colton-games/nonprod/auth` and `colton-games/nonprod/push` (JSON; export as above).
- **Claude Haiku 5.5 on Amazon Bedrock**: bedrock-runtime, region `us-west-2`, model `us.anthropic.claude-haiku-5-5`,
  credentials from the instance role. No other Bedrock model here.
- **CloudWatch** (read): metrics, including the claude-master pool's (`ClaudeMaster` namespace).

Not reachable from this box (administration only, or the metal boxes): production secrets, `workers-stage/*`,
`vercel-env/*`, the Workers deploy token, `people/addresses`, Turso, dolphin-films. Ask the owner.

The full, current list, with what each is for, is in the public `ejc3/aws` repo:
`curl -fsSL https://raw.githubusercontent.com/ejc3/aws/main/AGENTS.md | sed -n '/^### AI services on the dev boxes/,/^### Sites also deploying/p'`

## Reviewer Bots and the Merge Gate: a Time Budget, Not a Loop

The owner's rule (2026-10-12): "We can't take hours on this stuff unless it's super critical,"
and the merge gate exists "to make sure models are honest and don't skip steps", not to
block attackers.

**Scope:** repositories whose merge gate is a `pr-review-gate` skill. In `ejc3/aws` and
`ejc3/agents-md` this section does not apply: there this box only opens pull requests, the
jumpbox reviews and merges them, and security and correctness findings block.

- **Codex is the one required head reviewer.** CodeRabbit and Greptile findings are
  answered like any other, but do not wait on their reviews of each head.
- **Fix before merge only what is critical.** That means a committed result, number or doc
  that is actually wrong, or a defect in the merge path itself. Answer the rest in the thread
  (`DISAGREE: not blocking; tracked in #N`) and collect it in one tracking issue. Treat a
  finding that only matters against a hostile actor as not blocking. Treat one that would let
  a model skip a step unnoticed as blocking.
- **Hand-modelled checkers never converge under bot review.** An SVG legibility audit, a
  number-preservation diff and a link checker each drew 3–5 new edge-case findings per Codex
  round for about ten rounds. Before the first review, state the contract (a lint over what
  our own tools emit; anything else refused as unsupported) and the stopping rule.
- **Every push resets the head review,** and every merge to main can make the other open PRs
  conflict. Batch fixes into one push, merge each PR as soon as it clears, and merge PRs that
  touch the same files back to back.
- **Disposition replies must open with the exact prefix**: `RED-VERIFIED:`, `NOT-A-DEFECT:`
  or `DISAGREE:`. A gate rejected "RED-VERIFIED (source-level):". A doc or wording fix is
  `NOT-A-DEFECT:`.
- **When a bot cannot review** (the Codex GitHub reviewer has its own usage limit, separate
  from the `codex` CLI), review the unreviewed delta with the CLI: `codex exec -s read-only`
  with a prompt naming the range (`git diff <last reviewed sha>..<head sha>`) and asking for a
  code review of exactly that diff. Then record on the PR the range, the command and the
  findings, before merging past the gate.
- **Bot quirks:**
  - CodeRabbit allows about one review an hour per account, reviews incrementally, and
    re-edits its summary and old findings after later pushes. An edited finding needs a new
    answer.
  - Greptile runs only on an `@greptileai review` comment. It reports through a "Greptile
    Review" check and a summary below `<!-- greptile_comment -->` in the PR body, not through
    review comments, so look for those when checking whether it ran.

## Interactive sessions: mark a checkout or worktree for interactive use

The owner's rule (2026-10-13): at boot, a box opens a Claude session (t-claude, Remote Control) for
every folder with session activity in the last 30 days: a prompt a person sent in a Claude
conversation there, or an interactive marker touched in that window. A folder nobody prompts drops
off at the next reboot.

- When you clone a repository or create a git worktree the user wants to use interactively, mark it:
  `touch "$(git -C <folder> rev-parse --absolute-git-dir)/claude-interactive"` (absolute: a relative
  `.git` would resolve against your own directory). The marker lives in the git directory, so it is
  never tracked and never shows in `git status`. The new-repo watcher (agent-session-sync) starts a
  Remote Control session there within seconds, ready for the user to prompt from the phone. It looks
  at clones directly under `~` or `~/src` and at worktrees of those, wherever the worktree lives.
- Do not mark scratch clones, review trees, or anything only you use. Subagent worktrees under
  `.claude/worktrees/` are never opened, marked or not.
- To see what this box will open: `agent-active-dirs --explain`.

## ejc3/aws and ejc3/agents-md: this box proposes, the jumpbox merges

The owner's rule (2026-10-12), for two repositories only: `ejc3/aws` and `ejc3/agents-md`. Agents on this box may open
pull requests and issues there, and do nothing else with them. A watch on the main jumpbox (`ejc3/aws`
`scripts/pr-watch/SKILL.md`) runs every 30 minutes over their open pull requests and issues authored by `ejc3`: it
reviews each one, fixes what the review finds, gets the reviewers (Codex, CodeRabbit, Greptile, the review gate) to sign
off, merges it and applies or distributes it.

- **This file comes from `ejc3/agents-md`** and is replaced by what is on its `main` at every distribution. To change
  your own instructions, propose the change there as a pull request; never edit this file in place.
- **Open a pull request as a draft while you are working on it, and mark it ready (`gh pr ready`) when it is done.** The
  watch leaves drafts alone and takes a ready pull request on its next run.
- **Never merge a pull request, push to `main`, resolve review threads or apply Terraform** in those two repositories
  from this box. Propose it in a pull request; the jumpbox does the rest.
- Something only the jumpbox can do (a live AWS or Cloudflare change)? File an issue in `ejc3/aws`.

Every other repository works as it always has: this rule does not apply to them.
