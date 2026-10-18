# Claude Code Best Practices

This file contains general best practices and patterns to follow across all projects.

## Project Layout

- Main fcvm repository: `~/fcvm`
- Git worktrees go in: `~/src/` (e.g., `~/src/fcvm-no-fuse-pipe-threads`)

### Reference apps (base new work on these)

- `~/ts-api` — five TypeScript API styles (REST/Hono, GraphQL/Yoga+Pothos, tRPC,
  gRPC/ConnectRPC, Express) over one portable core, deployed to Vercel **and**
  Cloudflare. The reference for any new TS API or multi-platform deploy. Its
  `CLAUDE.md` holds the adversarial-review + writing-style rules.
- `~/remote-claw` — Turso ↔ Vercel integration patterns (managed-DB creds, the
  platform `TURSO_API_TOKEN`/`ORG`/`GROUP` vs the per-db `TURSO_DATABASE_URL`/
  `TURSO_AUTH_TOKEN` split). Look here when wiring Turso.

## Building & Deploying a Portable TypeScript API

Lessons from `~/ts-api`. The goal is one codebase that runs unchanged on Vercel
(Node functions) and Cloudflare (Workers, edge Fetch).

### Architecture: one core, thin per-platform entries

- **One Web Fetch handler** `(Request) => Response` composed onto a single app
  (Hono), with a framework-agnostic `core/` (types, `DataStore`, config, validation,
  seed). Per-platform entry adapters are thin: Cloudflare `export default { fetch }`,
  Vercel named HTTP-method exports.
- **Node-only frameworks attach through their own Node adapter, not the Fetch app.**
  ConnectRPC/gRPC and Express have no edge Fetch adapter, so they deploy as Vercel
  Node functions and are absent from the edge build.

### Keep platform-heavy deps out of the wrong bundle

- A Node lib (e.g. `@libsql/client`) must **never** enter the Workers bundle. Don't
  re-export the Node-only module from the shared barrel (`core/index`); import it only
  from Node entry points. Verify: `wrangler deploy --dry-run --outdir dist` then grep
  the bundle for the package name.

### ESM: use explicit `.js` import specifiers

- Vercel **transpiles each TS file (does not bundle)**, so extensionless relative
  imports fail at runtime under Node ESM: `ERR_MODULE_NOT_FOUND: Cannot find module
  '/var/task/src/app'`. Write `from './app.js'` everywhere. `moduleResolution: bundler`,
  vitest, and esbuild/wrangler all resolve `.js`→`.ts`, so the gate stays green.

### Vercel function export shape

- A **default export is treated as a Node `(req, res) => void` handler**; returning a
  `Response` is silently ignored. For a Fetch app, export **named HTTP methods**:

  ```ts
  const handler = (request: Request) => app.fetch(request)
  export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE }
  ```

- **Disable framework detection** for custom `api/` functions, or the detected preset
  (e.g. Hono) builds your app entry and fails on the export shape:

  ```json
  { "framework": null, "rewrites": [{ "source": "/(.*)", "destination": "/api" }] }
  ```

- **Deployment Protection** (Vercel Authentication / SSO) returns a 302 to a login; a
  public demo needs it off at the project level.

### Persistence is per-platform behind one interface — never ship in-memory as "real"

- D1 (Cloudflare) and Turso/libSQL (Node) both implement one `DataStore`. Both are
  SQLite, so one SQL implementation + a per-platform driver; carry the rowid as
  `bigint` (lossless `String()`), and guard id lookups (`String(row.id) === id`) so
  SQLite numeric affinity doesn't coerce `'01'`→`1`.
- An in-memory store that resets on cold start is **not** persistence. Provision the
  real DB and set its env/secrets before calling persistence "done".

### Deploys are CI-driven

- Deploys run from CI on merge to main — a GitHub Action runs `wrangler deploy` with
  the token as a repo secret; Vercel's git integration builds on push. Not manual CLI.
- Each change is a reviewed PR (mechanical gate → `/code-review` → `codex` → CI green)
  before merge. Don't iterate by patching a live deployment.

### Drafts behind Cloudflare Access always ship (owner, 2026-10-12)

A draft deployed behind a Cloudflare Access gate is ALWAYS okay to push, without asking: staging
`<site>-stage` Workers, prototypes, previews, and test-flight builds (TestFlight to internal testers
included). Getting a working build in front of the owner is part of the task, not a follow-up:
never stop at "merged" or "ready" with the product undeployed. If a credential or permission is
missing, get it (open the PR to `ejc3/aws` for the access) in the same push, rather than
reporting the gap and stopping. Only a public, ungated production launch needs the owner's
go-ahead.

## Python Async Patterns

### Cooperative Shutdown Pattern

**DO**: Use `asyncio.Event()` for cooperative shutdown

```python
async def monitor(stop: asyncio.Event):
    """Long-running task that checks stop event."""
    try:
        while not stop.is_set():
            # Do work
            await asyncio.sleep(1)
    except asyncio.CancelledError:
        logger.info("Monitor cancelled, cleaning up")
        raise

async def main():
    stop = asyncio.Event()

    # Setup signal handlers
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            # Note: Use default arg to capture loop variable!
            loop.add_signal_handler(sig, lambda s=sig: stop.set())
        except NotImplementedError:
            signal.signal(sig, lambda *_, s=sig: stop.set())

    # Start background tasks
    monitor_task = asyncio.create_task(monitor(stop), name="monitor")

    try:
        # Wait for shutdown signal
        await stop.wait()
        logger.info("Shutdown signal received")

        # Graceful shutdown with timeout
        try:
            await asyncio.wait_for(monitor_task, timeout=10)
        except TimeoutError:
            logger.warning("Task didn't finish, cancelling")
            monitor_task.cancel()
            await monitor_task  # Still await after cancel!
    finally:
        # Cleanup
        pass
```

### Task Lifecycle Management

**DO**: Always await cancelled tasks

```python
# Good
task.cancel()
try:
    await task
except asyncio.CancelledError:
    pass

# Bad - leaves task dangling
task.cancel()
```

**DO**: Name all background tasks for debugging

```python
# Good
asyncio.create_task(stream_output(proc), name="service-logs")

# Bad
asyncio.create_task(stream_output(proc))
```

**DON'T**: Use fire-and-forget without lifecycle management

```python
# Bad - no reference, can't cancel/await
asyncio.create_task(long_running_work())

# Good - store reference and manage lifecycle
self.work_task = asyncio.create_task(long_running_work())
# Later: cancel and await in cleanup
```

### Exception Handling

**DO**: Let exceptions propagate naturally

```python
# Good - exceptions bubble up
await risky_operation()

# Bad - using sys.exit() in callbacks
def callback(task):
    try:
        task.result()
    except Exception:
        sys.exit(1)  # Don't do this!
```

**DO**: Wrap tasks that need cleanup, but still re-raise

```python
async def task_wrapper(coro, name):
    try:
        return await coro
    except asyncio.CancelledError:
        raise  # Normal cancellation
    except Exception as e:
        logger.error(f"Exception in {name}: {e}", exc_info=True)
        raise  # Still propagate!
```

## Git Commit Messages

### Critical Rule: Describe What's IN the Commit

**Commit messages must describe the actual changes in the diff, NOT the user's request or Claude's instructions.**

#### Bad Examples

```
# User said: "fix the bug"
# Commit: "Fix bug"  ❌ Too vague

# User said: "add async support"
# Commit: "Add async support"  ❌ Doesn't say what changed

# Last Claude instruction: "refactor error handling"
# Commit: "Refactor error handling"  ❌ What specifically changed?
```

#### Good Examples

```
# Commit describes actual changes:
"Replace blocking requests with async httpx

- Convert get() helper to async function
- Add httpx dependency in pyproject.toml
- Update all test files to await get() calls
- Fix integration test timeout from 60s to 120s"
✅ Specific, verifiable from diff
```

### Commit Message Checklist

Before committing, verify:

1. ✅ Run `git diff --cached` to see what's actually staged
2. ✅ Each bullet point in the message corresponds to visible changes
3. ✅ No claims about functionality that isn't in the diff
4. ✅ Mention file types changed (Dockerfiles, tests, configs, etc.)
5. ✅ If fixing a bug, mention the symptom and the fix
6. ✅ If adding a feature, list the specific new capabilities

### Pattern: Review Before Committing

```bash
# Always review the actual diff first
git diff --cached --stat
git diff --cached

# Write message based on what you SEE, not what you remember doing
git commit -m "..."
```

## Three Broad Review Passes, Not an Open-Ended Review Loop

A review campaign has at most three broad passes:

1. **Architecture pass, before implementation.** Write the invariants, ownership
   boundaries, failure states, publication boundary, and test plan. For process or file
   lifecycle work, draw the complete create/use/cleanup sequence. Review this model before
   patching individual call sites.
2. **Candidate pass, on one frozen tree.** Finish focused tests, freeze one commit, and run
   all independent reviewers in parallel against that exact commit. Wait for every reviewer,
   then deduplicate their findings into one report and fix the batch together. Reviewers must
   return one complete report, not drip findings while the tree moves.
3. **Closure pass, on the integrated exact head.** Run the full relevant suite, freeze the
   resulting commit, and review that exact head in parallel. Wait for every reviewer and fix
   the consolidated batch. Every accepted defect claim needs a regression test observed red
   without the fix. A process, architecture, or configuration contract can be pinned by a
   fixture or source-level assertion when no runtime test fits. Naming, documentation, and
   style findings that are not defect claims use the project's non-defect disposition and
   verification of the corrected text. Never substitute prose evidence for a red test on an
   accepted defect. Review the repair deltas, then run the full relevant suite and CI on the
   repaired exact head and verify exact-head coverage. Targeted checks supplement that
   validation; they do not start another broad campaign.

Never send reviewers a moving worktree, add new broad reviewers halfway through a pass, or
run the full suite after each individual finding. Batch findings, make one repair, and run the
suite once per candidate.

The second instance of one defect class is an architecture finding. Stop fixing sites one at
a time. Extract a shared primitive or invariant, build a test matrix over every caller, and
then resume the current pass.

If the closure pass finds a new systemic defect class, stop and report that the architecture
model was incomplete. Re-plan the abstraction once instead of silently starting broad review
passes four, five, and six. This does not waive a concrete defect: fix it and prove the
regression, using a fixture or source-level assertion for a non-runtime contract. Keep the
follow-up review targeted to that repair and the final exact head.

When a user-controlled remote is authorized, push each signed, focused-green frozen
checkpoint before beginning the next pass. A remote checkpoint is recovery and visibility;
it is not merge authorization and its old checks do not cover later local commits.

**Land the smallest correct PR, then continue on the next stacked PR.** The architecture
pass must partition the work into a sequence of independently useful, mergeable contracts.
Once one PR satisfies its stated contract, focused and full tests, CI, and exact-head review,
report it ready. Merge it only when the user has separately authorized that merge. Push or
checkpoint authority is not merge authority. Do not hold a ready PR open to add adjacent
features, speculative hardening, or cleanup that can be expressed safely in a follow-up.

Every review finding must be classified before work starts:

- **Blocks this PR:** the diff causes it, makes it worse, violates the PR's stated contract,
  makes its tests/evidence invalid, or would make the merged state unsafe.
- **Stacked follow-up:** it is pre-existing or adjacent work that the PR does not rely on and
  can remain safely after this PR merges. File it or put it in the next stacked branch, with
  its dependency stated.

Review scope is the PR's contract and delta, not an invitation to redesign the whole system.
Never use “follow-up” to waive a known defect in changed code, but never keep a correct PR
hostage to unrelated improvements either. A review thread classified as a follow-up still
needs the gate's existing disposition vocabulary. Reply with `DISAGREE: this PR does not
cause or worsen the reported behavior; tracked in #N` and resolve it only when the diff and
tests substantiate that statement. If they do not, the finding blocks this PR.

### Reviewer bots and the merge gate: a time budget, not a loop

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

## Pull Requests

### MANDATORY: Examine ALL Changes Before Creating/Updating PRs

**Before creating or updating ANY pull request, you MUST:**

1. **Run `git log main..HEAD`** to see every commit in the PR
2. **Read EVERY commit** - message AND body, not just subject lines
3. **Write a PR description that covers ALL changes** - not just the latest commit

**This is NON-NEGOTIABLE.** A PR description that only mentions recent changes while ignoring earlier commits is WRONG.

#### Why This Matters

When a PR has 10 commits, the description must summarize all 10 - not just the last one you worked on. Missing changes means:
- Reviewers don't know what they're reviewing
- Important context is lost
- The PR becomes unmergeable or causes confusion

#### Bad Example

```bash
# ❌ WRONG - only looking at latest commit
git log -1  # Only shows last commit!
# Then writing PR description based on that one commit

# ❌ WRONG - just looking at files
git diff --stat main...HEAD
# File names don't tell you WHY changes were made
```

#### Good Example

```bash
# ✅ CORRECT - read ALL commits in the PR
git log main..HEAD --format="%h %s%n%b" --no-merges

# Review EACH commit message and body
# Understand the full progression of work
# Group related changes into themes
# Write PR description that summarizes ALL the work
```

### PR Description Checklist

Before creating or updating a PR:

1. ✅ Run `git log main..HEAD` to see ALL commits since branch point
2. ✅ Read EACH commit message AND body (not just subject line)
3. ✅ Count the commits - your description must cover ALL of them
4. ✅ Identify major themes across commits
5. ✅ Group related changes together in PR description
6. ✅ Include specific examples of what was added/fixed/changed
7. ✅ Mention files changed by category (Dockerfiles, tests, docs, etc.)
8. ✅ Note any breaking changes or migration steps
9. ✅ Include test results if applicable

## General Code Quality

### Logging

- Use structured logging with levels (DEBUG, INFO, WARNING, ERROR)
- Include context in log messages (service name, request ID, etc.)
- Don't log sensitive data (passwords, tokens, PII)

### Error Messages

- Include actionable information
- Mention what failed and why
- Suggest next steps when possible

### Documentation

- Keep inline comments minimal and meaningful
- Update README.md when adding features
- Document non-obvious design decisions
- Keep CLAUDE.md project files up to date

## Nothing From My Environment Goes Into Anything Public

Some of the model ids I run are private. A model id read from my environment or session (`ANTHROPIC_MODEL`, `/model`,
a launch command), and shortened or altered forms of one, must **never** appear in anything public: a public
repository, a pull request or issue (title, body, comments), a commit message, a test fixture, an example in a README,
a release note, a gist. Only the public model names (Opus, Sonnet, Haiku and their published ids) may be written
there. Private files and private documents are fine.

The same holds for any other value read from my environment or session: profile names, host names, account names. A
value copied from my shell, my launch command or a transcript is private by default.

- In tests, examples and descriptions, use a made-up placeholder (`claude-test-model`, `example-host`), never the real
  value, even to reproduce a bug I reported with it.
- Before every push to a public repository and before creating or editing a pull request or issue there, check which
  repositories are public (`gh repo view --json visibility`) and search the diff, the commit messages and the text for
  the current session's own model id and any other model id that is not a published one. A hit blocks the push.
- If one gets out, tell me at once. Removing it means rewriting history and may mean recreating the repository; GitHub
  keeps old commits behind closed pull requests.

### Incident, 2026-10-02: a private model id in a public test file

Asked why a model setting did not reach a new window, Claude reproduced the bug with the exact model id from my launch
command, wrote that id into a new test file and the pull request description, and merged it into a public repository.
It was found two days later. The fix was a history rewrite, then deleting and recreating the repository.

## C and Other Unmanaged Code: Leaks and Crashes Are Release Blockers

In C (tmux, anything long-running), a leak or a crash is worse than a missing feature: a
server process lives for weeks, so a few bytes per event becomes gigabytes, and a crash
takes every session with it. Treat input from a program, a terminal, a file or the network
as hostile, and prove safety with tools, not by reading the code.

**While writing:**

- Every allocation has one owner and one free on every path, including each early return
  and error path. Write the create/use/free sequence before the code.
- Every buffer write checks room for the largest thing it can write, not the typical one.
  Every parse is bounded by the known input length, never by a terminator alone.
- Every resource a peer can grow (queues, pending uploads, caches, lists, output buffers)
  has a hard cap and a defined action at the cap (drop, refuse, evict oldest in O(1)).
  "Bounded by a quota" counts only if the quota covers that exact structure.
- Nothing a peer controls may block the process: no blocking `open()` (FIFOs), no reads
  without a size limit, no `mmap` of a file someone else can truncate (SIGBUS).
- Object lifetimes across callbacks: anything that holds a pointer to a client, pane or
  request must be told when it goes away. Timers and held requests must be cancelled or
  resolved on detach, exit, suspend and kill.
- Number fields from input: check for zero divisors, overflow, negative values and
  values over the type's range before using them.

**Before calling it done:**

- Build with `-fsanitize=address,undefined -fno-sanitize-recover=undefined` and run the
  full test suite on that build. LeakSanitizer must report nothing for the long-running
  process at exit.
- Run a steady-state growth check: repeat each changed feature hundreds of times and
  require the live heap (allocated bytes and block count, not RSS) to stay flat.
- Run a bounds check for every cap: drive input past it, with a slow reader where
  output is queued, and require peak memory under the cap.
- Fuzz every parser that was touched, from each side that feeds it, on the sanitizer
  build, with interleaved lifecycle events (detach, resize, kill, suspend).
- A leak, crash, sanitizer report, or unbounded growth found anywhere in the changed code
  blocks the change. Fix the source and add a regression test that fails without the fix.

## Testing

### Critical Rule: NEVER SKIP TESTS

**If a test fails, FIX THE ROOT CAUSE. Never skip, comment out, or ignore failing tests.**

- ❌ Do NOT use `@unittest.skip()` or `@pytest.skip()` decorators
- ❌ Do NOT comment out failing tests
- ❌ Do NOT ignore test failures
- ✅ DO fix the root cause when tests fail
- Tests exist to catch bugs - skipping them hides bugs

### Mandatory Pre-Commit Checklist

Before committing ANY code changes:

- [ ] **Run linting** - MUST pass with no errors
- [ ] **Run appropriate tests** based on what changed
- [ ] **Review test output** - Verify tests PASSED, not just exit code
- [ ] **Fix all failures** - Do NOT commit with failing tests

No shortcuts. Every item must be checked before `git commit`.

### Test Organization

- Use Makefiles for common test commands
- Name tests clearly: `test_<feature>_<scenario>`
- Run tests locally before pushing to CI
- Include both happy path and error cases

### Background Command Execution (Claude Code)

**CRITICAL: For ANY command >10 seconds, use background execution with tee:**

```python
# ✅ CORRECT - Run in background with tee to file
Bash(
    command="cargo build --release 2>&1 | tee /tmp/build.log",
    description="Build release binary",
    timeout=600000,  # 10 min
    run_in_background=True
)
# Returns immediately with shell_id

# Check progress every 10 seconds (not 5, not 30!)
BashOutput(bash_id=shell_id)
# System auto-notifies when new output available

# Do other work while command runs...

# Check again in 10 seconds
BashOutput(bash_id=shell_id)

# ✅ ALSO CORRECT - SSH commands with tee
Bash(
    command='ssh user@host "cd ~/project && cargo build 2>&1 | tee /tmp/build.log"',
    run_in_background=True
)
```

**DO NOT do this:**

```python
# ❌ WRONG - Using grep/tail to filter output (costs money/time!)
Bash("cargo build 2>&1 | grep error")  # Missing output, no file saved

# ❌ WRONG - Piping output through grep (blocks until command finishes!)
Bash("sudo cargo test ... 2>&1 | grep 'pattern'")  # No output until test ends

# ❌ WRONG - Shell loops
Bash("until grep -q DONE /tmp/log; do sleep 5; done")

# ❌ WRONG - Sleep to wait
Bash("sleep 60 && cat /tmp/log")

# ❌ WRONG - Blocking synchronous run for slow commands
Bash("cargo build --release")  # Blocks for 2+ minutes, wastes money

# ❌ WRONG - Wrong polling interval
# Check every 10 seconds, not 5, not 30!
```

**For post-hoc filtering, always log to file first:**

```bash
# ✅ CORRECT - Log to file, then grep after completion
ssh host "cargo test 2>&1 | tee /tmp/test.log"
# Later:
ssh host "grep 'pattern' /tmp/test.log"

# ❌ WRONG - Pipe directly (blocks until test finishes, no incremental output)
ssh host "cargo test 2>&1 | grep 'pattern'"
```

**Why this matters:**
- Claude's background feature lets you work while tests run
- System reminders auto-notify when tasks have output
- BashOutput gives immediate status without polling
- Timeout handled by Claude, not shell commands

### Async Tests

```python
# Pattern for async tests
class MyTest(unittest.TestCase):
    def test_async_thing(self):
        asyncio.run(self._test_async_thing())

    async def _test_async_thing(self):
        result = await async_function()
        assert result == expected
```

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

## Stack of PRs Workflow

### Critical Rule: Work in Phases, Test Locally, Wait for Green

**When implementing multiple related changes, break work into a stack of pull requests. Each PR must be tested locally AND pass CI before proceeding.**

### CRITICAL: Maintain Stack Coherence

**When PRs are stacked (PR #2 depends on PR #1), the branch for PR #2 MUST be based on PR #1's branch, not on main.**

**Common Mistake:**
```
# WRONG - Both branches based on main (siblings, not stacked)
main ← pr1-branch (PR #1)
main ← pr2-branch (PR #2)  # PR #2 won't have PR #1's changes!

# CORRECT - PR #2 branch based on PR #1 branch
main ← pr1-branch (PR #1) ← pr2-branch (PR #2)
```

**How to verify:**
```bash
# Check that PR #2 includes PR #1's commits
git log --oneline origin/main..pr2-branch
# Should show: PR #2 commits, then PR #1 commits, in that order
```

**How to fix a wrongly-based branch:**
```bash
# Reset PR #2's branch to PR #1's branch, then cherry-pick PR #2's commit
git checkout -B pr2-branch origin/pr1-branch
git cherry-pick <pr2-commit-hash>
git push origin pr2-branch --force
```

**Why this matters:**
- Tests for PR #2 will FAIL if they depend on PR #1's changes
- Merging PR #1 first will cause conflicts in PR #2
- The whole point of stacking is that each PR builds on the previous

### Phase-Based Development Pattern

**DO**: Break large changes into logical phases

```bash
# Example: 6 phases of changes
Phase 1: Simplify configuration
Phase 2: Replace test orchestration
Phase 3: Use native logging
Phase 4: Fix version handling (depends on Phase 3)
Phase 5: Fix error handling (depends on Phase 4)
Phase 6: Split CI tests (depends on Phase 5)
```

**Why phases matter:**
- Each phase is independently reviewable
- Easier to identify which change broke something
- Can merge phases incrementally as they pass
- Parallel CI execution across multiple PRs
- Clearer commit history and easier rollback

### Mandatory Pre-Push Checklist

**CRITICAL**: Before pushing ANY branch, you MUST complete ALL checks:

```bash
# 1. Run linting
make lint
# or: uv run python3 -m ruff check

# 2. Run format check (separate from lint!)
make format-check
# or: uv run python3 -m ruff format --check

# 3. Fix any issues found
make lint-fix   # Auto-fix linting
make format     # Auto-fix formatting

# 4. Run appropriate tests locally
make test-smoke      # Quick validation
make test-app        # If you changed app code
make test-integration # If you changed infra

# 5. Verify tests PASSED (don't just check exit code!)
# Read the output - look for "OK", "PASSED", "✓"
```

**Common mistakes:**
- ❌ Running `make lint` but forgetting `make format-check` (BOTH are required!)
- ❌ Pushing without running tests locally
- ❌ Assuming tests passed without reading output
- ❌ Testing expected behavior but not testing what changed

### Wait for CI - No Early Stops

**CRITICAL**: After pushing, you MUST wait for CI to complete and go green before moving to the next phase.

**DO**: Loop and check CI status until all jobs pass

```bash
# Check all PRs in your stack
for pr in 3 4 5 6 7 8; do
  echo "PR #$pr: $(gh pr view $pr --json statusCheckRollup --jq '...')"
done

# Keep checking until all are green
# ✅ All checks must show "SUCCESS"
# ❌ Any "FAILURE" requires immediate fix
# ⏳ "PENDING" means keep waiting
```

**DON'T**: Move to next phase while CI is pending

```bash
# ❌ WRONG - pushing Phase 5 while Phase 4 CI is still running
git checkout phase5 && git push

# ✅ CORRECT - wait for Phase 4 to go green first
# Check CI status repeatedly
# Only proceed when Phase 4 shows ✅ ALL PASSED
```

**Why waiting matters:**
- Failures often reveal issues you missed locally
- Later phases may need fixes from earlier failures
- Rebasing becomes necessary if earlier phases change
- Saves time by catching issues before they compound

### Checking Multiple GitHub Jobs in Parallel

**Use `gh` CLI to check CI status across multiple PRs:**

```bash
# Quick status summary for all PRs
echo "=== CI Status Summary ==="
for pr in 3 4 5 6 7 8; do
  echo -n "PR #$pr: "
  gh pr view $pr --json number,title,statusCheckRollup --jq \
    '.title + " - " + (.statusCheckRollup | map(.conclusion) |
     if all(. == "SUCCESS") then "✅ ALL PASSED"
     elif any(. == "FAILURE") then "❌ FAILED"
     elif any(. == "PENDING" or . == null) then "⏳ PENDING"
     else "❓ UNKNOWN" end)'
done

# Detailed check results for specific PR
gh pr checks 6

# Find which jobs failed
gh pr checks 6 | grep -E "fail|FAIL"

# Watch CI in real-time
watch -n 10 'gh pr checks 6'
```

### Rebase Chain When Earlier PRs Change

**When you fix an earlier PR in the stack, ALL later PRs must be rebased:**

```bash
# Fixed Phase 4, now rebase Phase 5 and 6
git checkout phase5 && git rebase phase4 && git push -f
git checkout phase6 && git rebase phase5 && git push -f

# This triggers new CI runs for all rebased PRs
# You must wait for ALL of them to go green again
```

### After a Squash Merge: Re-apply the Child's Net Diff

When the parent PR is squash-merged, git can no longer see that the child branch already
contains the parent's commits. Merging main into the child then conflicts on every line the
child changed on top of the parent. Instead, replay only the child's own change:

```bash
head=$(git rev-parse child)        # save the child's tip: the next line moves the branch
git checkout -B child origin/main
git diff --binary <child-base> "$head" | git apply -3 --index
# resolve the real overlaps and regenerate generated files, then compare the change set
# file by file: diff <(git diff <child-base> "$head") <(git diff --cached origin/main)
# and read every difference that is not line numbers or context
```

A CI job that commits generated files back to main (rendered charts, lockfiles) conflicts
with every open PR touching them. Wait for that commit to land, then refresh the next PR
once, keeping the PR's own generated output and re-rendering.

### Stack of PRs Summary

**The complete workflow:**

1. **Plan phases** - Break work into logical, independent chunks
2. **Implement phase** - Write code for one phase
3. **Test locally** - Run lint, format-check, AND appropriate tests
4. **Push branch** - Create PR for the phase
5. **Wait for CI** - Do NOT proceed until green ✅
6. **Fix failures** - If CI fails, fix immediately and rebase later PRs
7. **Repeat** - Only move to next phase when current phase is GREEN
8. **Merge when ready** - Merge phases independently or as a batch

**Key principle: No shortcuts, no early stops, no assumptions. Test → Push → Wait → Green → Next.**

## File Organization

### Project-Specific Instructions

- Keep a `CLAUDE.md` in project root for project-specific context
- Update it when architecture changes
- Include recent decisions and patterns
- Reference it in commit messages when following conventions

### Scratch files go in the checkout's `.scratch/`

Every scratch file you or an agent writes goes in `.scratch/` at the root of the checkout
being worked in. That covers notes, pull request descriptions, probe and one-off scripts,
patches and outputs. `.scratch/` is ignored by git in every repository on this machine, through
the global ignore file `~/.config/git/ignore`. Never write them to a shared scratchpad, to
`/tmp`, or outside the checkout.

The one exception is anything big: builds, browser profiles, mutation copies, VM images,
large logs and the like. Those go on the ephemeral NVMe scratch disk under `/mnt/fcvm-btrfs`,
as the host section below says. Everything else stays in the checkout's `.scratch/`.

When briefing agents, put this rule in the brief, and have each one use its own checkout's
`.scratch/`.

**Incident, 2026-10-10:** eleven parallel agents wrote their pull request descriptions to the
same file names (`pr1.md`) in one shared scratchpad. Two pull requests were published with
another agent's description.

## Host: fcvm-metal-arm — root disk is durable and small, use scratch for disposable state

`/` is a persistent, daily-backed-up 400GB EBS volume. `/mnt/fcvm-btrfs` is the
instance-local NVMe (currently ~3.5TB, RAID0 across the ephemeral disks) — but it is wiped
on every stop/start. Anything disposable (browser profiles, caches, build artifacts, VM
images) belongs on `/mnt/fcvm-btrfs`, never under `~/.local/state`, `~/.cache`, or anywhere
else on `/`.

### Incident, 2026-09-20: root disk hit 100%, broke codex

`~/.local/state/remote-claw/claude-browser/DeferredBrowserMetrics` grew to **~112GB** —
over 27,000 orphaned Chromium `BrowserMetrics-*.pma` files (4MB each), accumulated over 3
days. That profile's Chrome was launched with `--metrics-recording-only`, which records
UMA metrics locally but never uploads or prunes them, so the files just piled up forever.
No running process still had the directory open (`lsof +D` came back empty), which is what
made it safe to delete outright rather than needing to stop anything first.

Root disk went 387G/387G used → `codex login status` started failing with `No space left
on device`, which broke `codex-rc@` remote-control. Symptom looked like an SSH/host-key
issue at first; it wasn't — same instance, same EIP, no recreation. Check `df -h /` before
chasing anything else when a tool on this box starts failing mysteriously.

**Fix applied:** deleted `DeferredBrowserMetrics` (safe: disposable telemetry, not auth or
session data) → reclaimed 107GB, back to 73% used.

**Do differently going forward:**
- Any `remote-claw` / browser-manager Chromium `--user-data-dir` should live under
  `/mnt/fcvm-btrfs`, not `~/.local/state`. It doesn't need to survive a stop/start.
- If launching Chromium for automation, don't pass `--metrics-recording-only` unless
  something is actually going to flush/prune `DeferredBrowserMetrics` — otherwise it grows
  unbounded. Either drop the flag or `--disable-metrics` outright.
- If disk fills again: `sudo du -x -d1 /home/ubuntu/.local/state | sort -rn` first — that's
  where per-tool session/browser state balloons, not source trees or build caches.

---

## Host: fcvm-metal-arm — ports: one registry, a block per project

Many projects and many agent sessions share this box. Each one picking its own port (a
framework's default, or the same "unusual" number someone else picked) puts two servers
on one port. There is one registry, `~/.config/ports/registry.tsv`, read and changed only
through `ports` (`~/.local/bin/ports`; it locks the file). `ports rules` prints the rules.

- **Claim before you listen.** `ports claim <project> "$PWD"` gives the project a block of
  20 ports between 20000 and 29999 and prints the first. Asking again gives the same
  block. Everything the project leaves listening is in its block: by habit +0 the app,
  +1 to +9 its other services, +10 to +19 what its tests start.
- **Always give the port explicitly**, from an environment variable. Never leave it to a
  framework's default (3000, 5173, 8000, 8080 and the like), and never let a tool pick
  "the next free one": that is how a server ends up on someone else's port.
- **The number stays out of the repository.** It lives in the project's gitignored local
  env file; the repository reads a variable and may keep a default for other machines.
- **A taken port is not yours to free.** `ports who <port>` says whose it is by the
  registry and what is listening there now. Never stop a listener you did not start; use
  another port of your own block.
- **A port fixed elsewhere** (a tunnel, a proxy's upstream, a browser left running for
  others to attach to) is written down so nobody is given it:
  `ports fixed <port> <project> "why"`.
- **A port needed for a moment** (one test) is asked of the kernel (port 0) and read back.
  It claims nothing.
- A second checkout of a project that runs at the same time claims its own block as
  `<project>@<checkout>`. A finished project: `ports release <project>`.
- `ports check` shows what is listening now and whose claim it is in. `UNCLAIMED` means
  it should move into a block. `ports list` shows every claim.

### Incident, 2026-10-04: two projects on one port

While one project's browser tests were running, another project's dev server started on
the port those tests use (3917: an "unusual" number that two projects had each chosen so
as not to collide). The tests failed with "already used"; the other server was rightly
left alone and the tests moved by hand. Nothing said who had which port, so nothing could
have prevented it. The registry is that.

---

## Host: fcvm-metal-arm — measure on the parallel boxes, never on this box

This box is shared: other sessions and users run builds and tests on it, so any timing taken
here is noise. Compile and run tests here; take every number that goes into a record, a write-up
or a decision on a dedicated parallel box (`pbox`), and throw away anything measured here.

- `pbox status` first: four slots (1-4), each its own instance and work volume. Use a slot that
  is down or that your own job brought up; never take over a box another job is using.
- `pbox up N` launches it (spot where it can); `PARALLEL_BOX_TYPES="c8gd.48xlarge ..."` asks
  for instance types with local NVMe when the job does disk I/O. `pbox ip N`, `pbox ssh N`.
- In a Claude Code session the HTTPS proxy asks for a client certificate, which `pbox`'s AWS
  calls (and git, gh) cannot give: they fail with certificate errors. Run them through a
  local plain-HTTP forwarder on a kernel-assigned port, `socat TCP-LISTEN:$P,bind=127.0.0.1,fork
  OPENSSL:<proxy host:port>,cafile=ca.pem,cert=client.pem,key=client.key,verify=1` with the
  files in `~/.config/claude-master/`, then `HTTPS_PROXY=http://127.0.0.1:$P` and `NO_PROXY`
  covering `169.254.169.254` and localhost. Kill the forwarder afterwards; never turn off
  verification or bypass the proxy.
- Start the job detached on the box (`nohup setsid ... &`) so a dropped ssh does not kill it,
  log to a file there, and copy logs and results back periodically with `rsync`.
- A box bills by the hour: `pbox down N` as soon as the results are copied back (the work
  volume is kept). Do not leave one idle between jobs.
- Records keep the instance type, never the box's host name, IP or boot id.

## Skills and Tool Gotchas on This Box

- **Skills in `~/claude-skills`** (symlinked into `~/.claude/skills`):
  - `docs-design-pass` raises a repository's charts, figures and prose to a technical-paper
    standard. It ships an SVG legibility audit, a number-preservation check and a link
    checker.
  - Each repository's `pr-review-gate` skill is the merge gate: every finding answered with a
    disposition, and the head reviewed.
  - Use a skill when its description matches the task.
- **The Bash tool runs zsh.** zsh does not word-split unquoted variables, so
  `for p in $list` and `set -- $p` see one word. Write the command substitution inline,
  or use `${=var}`.
- **A background agent can go silent mid-task** and not answer messages. Verify its
  committed work yourself (run the tests, and run the red check against the old code), then
  stop it instead of waiting.

## Host: fcvm-metal-arm — machine-local instructions

What only this box needs to know and the public repository must not hold (how to reach the owner's signed-in
browsers and Mac, local host aliases and services) is kept in a file on the box, outside git, and read from here:

@~/.claude/local.md

Change that file on the box itself. If it is missing, nothing breaks; ask the owner.

## Code someone else owns is not a reason to stop

The owner's rule (2026-10-12): "we never abide by 'someone else owns it'. Draft PRs and
personal forks are cheap!!" When the next bottleneck or bug sits in another project, crate,
package or team's code, change it there: in a worktree, a personal fork or a draft pull
request on the owner's own repositories, then measure or test it like any other change. Do not
park it as "a design question for the maintainers" or list it as open work. Rules about
what may go to an upstream project (issues, pull requests, comments) still apply as given for
that project.

## Driving the MacBook

There is one way into the owner's MacBook: **`ssh mac`**. It goes through Cloudflare Access (this account's own service
token) to macOS Remote Login on the Mac. The owner wants no manual steps at the Mac.

| Need | How |
|---|---|
| Builds, scripts, files, the scratch drive (`/Volumes/Scratch/<project>`), a freshly built binary included | plain `ssh mac` |
| `osascript` to System Events and Google Chrome | plain `ssh mac` |
| Screenshots, clicks, typing | `peekaboo` (through `ssh mac`) |
| The login keychain: `codesign`, `xcodebuild archive` / `-exportArchive` with signing, `security` on it | `mac-gui [--timeout S] -- CMD` |

A plain Remote Login session cannot reach the login keychain (`errSecInternalComponent`); `mac-gui` runs the command in
the logged-in GUI session and returns its output and exit status (124 on timeout).

### Sharing the Mac with other sessions

Several agents use the Mac at once. Two small tools keep them out of each other's way:

- **`mac-lease`**: take the desktop lease before driving the screen or relaunching an app, release it after.
  `mac-lease run NAME -- CMD` for one command; `take NAME` / `release NAME` across several calls; `status` shows who holds
  it. `peekaboo` waits while someone else holds it (pass yours as `MAC_LEASE=NAME`). Looking never waits.
- **`mac-build`**: at most two heavy builds at once. The `swift`, `xcodebuild` and `xcrun` on the Mac's `PATH` already go
  through it; a third build waits. `mac-build --status` shows the slots.

### Permission prompts

- **Approve permission prompts your own work triggers** (Automation, Accessibility, Screen Recording, Full Disk Access,
  keychain access for signing): click Allow. Prefer granting them to Remote Login (`sshd-keygen-wrapper`), the identity
  every `ssh mac` session shares. A System Settings toggle that asks for Touch ID or a password goes to the owner.
- **Never answer another app's own dialog** (a keychain password prompt from another app, a mail account password, Time
  Machine, an app's sign-in): take a screenshot, report what it asks, leave it.

### Chrome (the owner's real, signed-in browser)

The owner's logins live there; never reach for a separate automated browser for signed-in sites.

- **Take the lease first**, and never relaunch Chrome while another session is mid-flow (a relaunch can sign the owner
  out of sites such as App Store Connect).
- **Work in your own window and keep it by id**: `set wid to id of (make new window with properties {mode:"normal"})`,
  then `tell window id wid`. Never act on the owner's tabs, and never match tabs by URL alone (the owner may have the same
  site open). Close your window when done.
- **Check the login, don't assume it**: a new window opens in the profile of the window in front, and a second profile
  may be signed in to a different account. Read the page's signed-in state before acting.
- **Always wrap calls**: `with timeout of N seconds ... end timeout`.
- **After a click that saves** (Create, Delete, Install, Submit), wait 8-10 s before closing the window.
- **Known wedge**: JavaScript from Apple Events can stop answering in every window of one profile (`AppleEvent timed out
  (-1712)`) while plain AppleScript still works. Only a Chrome relaunch clears it: take the lease and ask the owner first.
- **Clicking**: the owner authorizes clicking through setups they asked for (create an app, install it, request API
  access, generate a key). The owner signs in and confirms passkeys and two-factor codes. Never pay and never accept a
  contract that commits money.

### Peekaboo

`peekaboo see --mode screen --no-elements --path /tmp/s.png` for the screen; `peekaboo window list --app PID:<pid>
--json` then `peekaboo see --window-id <id>` for one window. Use `PID:` from `pgrep -x "Google Chrome"`: app names
match helpers too.

### Signing and long jobs

The build runs over plain `ssh mac`; only the signing steps go through `mac-gui`. A job that must survive the
connection dropping (an upload) runs as a one-off LaunchAgent in the GUI domain (`launchctl bootstrap gui/$(id -u)
job.plist`, `RunAtLoad`, no `KeepAlive`, logging to a file; `bootout` afterwards). TestFlight groups, testers and build
assignment go through the App Store Connect API key (`games-worth-watching/app-store-connect`), not Chrome. When a
script reaches the Mac on stdin (`ssh mac 'zsh -s' < script`), give every `ssh` inside it `-n`.

## AI services on this box (use them if a task needs them)

- **ElevenLabs** (voice, sound effects, music for the games). The API key is in AWS Secrets
  Manager as `games/elevenlabs-api-key` (us-west-1); this box's instance role may read it.
  Fetch it into the environment only when needed, never onto a command line, into a file, a
  log or a commit, and never print it:
  `export ELEVENLABS_API_KEY=$(aws secretsmanager get-secret-value --region us-west-1 --secret-id games/elevenlabs-api-key --query SecretString --output text)`
  The deployed games already have it as the server-side Vercel env `ELEVENLABS_API_KEY`; keep
  it server-side (never `NEXT_PUBLIC_`). Pay-as-you-go account: generate what is needed, not
  in bulk. Managed in ejc3/aws `dev-ai-services.tf`.
- **DeepSeek via opencode.** `opencode` runs DeepSeek V3.2 on Amazon Bedrock through this box's
  instance role, with no key (the managed `~/.zshrc` wraps it). `deepseek.r1-v1:0` is also
  allowed. Managed in ejc3/aws `dev-user-data.tf`.

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

## Credentials on this box

This box's instance role gives agents these, with no key on disk. Load a secret into the environment, never onto a
command line, into a file in a repo or a commit; never print one.

- **Cloudflare logs and metrics** (read-only: Workers Logs, `wrangler tail`, GraphQL Analytics, every zone's analytics):
  `export CLOUDFLARE_API_TOKEN=$(aws secretsmanager get-secret-value --region us-west-1 --secret-id cloudflare-observability-token --query SecretString --output text)`
- **Browserbase** (hosted browsers): JSON secret `browserbase/credentials`; export every key with
  `eval "$(aws secretsmanager get-secret-value --region us-west-1 --secret-id browserbase/credentials --query SecretString --output text | jq -r 'to_entries[] | "export \(.key)=\(.value|@sh)"')"`
- **ElevenLabs** (voice and sound): `games/elevenlabs-api-key`, as `ELEVENLABS_API_KEY`.
- **Colton Games, non-production**: `colton-games/nonprod/auth` and `colton-games/nonprod/push` (JSON; export as above).
- **Claude on Amazon Bedrock**: every Anthropic model through the instance role (Haiku 5.5: region `us-west-2`, model
  `us.anthropic.claude-haiku-5-5`); DeepSeek through `opencode`.
- **Turso platform token** (makes and deletes databases): `turso/api-token`, as `TURSO_API_TOKEN`.
- **dolphin-films, non-production**: `dolphin-films/nonprod/auth` and `dolphin-films/nonprod/turso` (JSON; export as above).
- **claude-master's paid API-key backup**: `claude-master/backup-api-key`, as `CLAUDE_MASTER_BACKUP_API_KEY`. Billed per token.
- **CloudWatch** (read): metrics, including the claude-master pool's (`ClaudeMaster` namespace).
- **claude-master's log** (read): log group `/claude-master/server` (moves, rate limits, upstream errors, label reloads),
  e.g. `aws logs filter-log-events --region us-west-1 --log-group-name /claude-master/server --filter-pattern '"routing summary"'`.

Not reachable from this box (administration only): production secrets, `workers-stage/*`, `vercel-env/*`, the Workers
deploy token, `people/addresses`, `claude-master/account-labels`. Ask the owner.

The full, current list, with what each is for, is in the public `ejc3/aws` repo:
`curl -fsSL https://raw.githubusercontent.com/ejc3/aws/main/AGENTS.md | sed -n '/^### AI services on the dev boxes/,/^### Sites also deploying/p'`

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
