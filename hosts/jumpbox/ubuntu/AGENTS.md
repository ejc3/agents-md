# Claude Code Best Practices

This file contains general best practices and patterns to follow across all projects.

---

## Host: jumpbox

This is an ARM64 EC2 instance (t4g.large) in us-west-1 used as a jumpbox/management host.

### Quick Reference

```bash
# Get current IPs (spot instances change IPs on restart)
aws ec2 describe-instances --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],PublicIpAddress]' --output table

# SSH to dev hosts (use IPs from above)
ssh -i ~/.ssh/fcvm-ec2 ubuntu@<IP>
```

### Dev Hosts

| Name | IP | Type | Purpose |
|------|----|----|---------|
| fcvm-metal-arm | (Elastic IP; `ssh fcvm-arm`) | c7g.metal (ARM64) | Firecracker/KVM nested virt |
| fcvm-metal-x86 | (Elastic IP; `ssh fcvm-x86`) | c5.metal (x86) | x86-specific testing |

Note: IPs may change if instances are stopped/started (spot instances). Use `aws ec2 describe-instances` to get current IPs.

Both are spot instances with persistent EBS volumes. Auto-stop after 3 days idle.

### Installed Tools

- **Shell**: zsh (default), with starship prompt, atuin history, fzf
- **Languages**: Rust (rustup), Node.js 22.x
- **Build**: cmake, ninja-build, autoconf, libtool, pkg-config
- **Dev**: git, gh (GitHub CLI), Claude Code
- **Containers**: podman (rootless)
- **FUSE**: fuse3, libfuse3-dev
- **Libs**: protobuf, libsodium, libcurl

### Key Paths

- Terraform: `~/aws/`
- SSH key: `~/.ssh/fcvm-ec2`
- Starship config: `~/.config/starship.toml`
- Atuin data: `~/.local/share/atuin/`

### Terraform State

Terraform in `~/aws/` manages:
- jumpbox - t4g.large
- fcvm-metal-arm - c7g.metal ARM64 dev server
- fcvm-metal-x86 - c5.metal x86 dev server
- github-runner-autoscale - autoscaling group for CI runners

---

## Drafts behind Cloudflare Access always ship (owner, 2026-10-12)

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

## Pull Requests

### Critical Rule: Read Actual Commits, Not Just File Lists

**When creating PRs that span multiple commits, you MUST read the actual commit messages and bodies, not just look at file statistics.**

#### Bad Example

```bash
# ❌ WRONG - just looking at files
git diff --stat main...HEAD
# Then writing PR description based on file names
```

This fails because:
- File names don't tell you WHY changes were made
- You'll miss important context from commit messages
- You can't properly summarize the work

#### Good Example

```bash
# ✅ CORRECT - read actual commits
git log main..HEAD --format="%h %s%n%b" --no-merges

# Review each commit message and body
# Understand the progression of work
# Group related changes into themes
# Write PR description that summarizes ALL the work
```

### PR Description Checklist

Before creating a PR:

1. ✅ Run `git log main..HEAD` to see all commits since branch point
2. ✅ Read each commit message AND body (not just subject line)
3. ✅ Identify major themes across commits
4. ✅ Group related changes together in PR description
5. ✅ Include specific examples of what was added/fixed/changed
6. ✅ Mention files changed by category (Dockerfiles, tests, docs, etc.)
7. ✅ Note any breaking changes or migration steps
8. ✅ Include test results if applicable

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

## Reviewer Bots and the Merge Gate: a Time Budget, Not a Loop

The owner's rule (2026-10-12): "We can't take hours on this stuff unless it's super critical,"
and the merge gate exists "to make sure models are honest and don't skip steps", not to
block attackers.

**Scope:** repositories whose merge gate is a `pr-review-gate` skill. In `ejc3/aws` and
`ejc3/agents-md` the PR watch (`/pr-watch`) and ejc3/aws's AGENTS.md govern instead: every
reviewer is asked on the head, and security and correctness findings block.

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

## Stack of PRs Workflow

### Critical Rule: Work in Phases, Test Locally, Wait for Green

**When implementing multiple related changes, break work into a stack of pull requests. Each PR must be tested locally AND pass CI before proceeding.**

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

### Cross-Repo Stacked PRs (Fork to Upstream)

When contributing to an upstream repo via a fork, use this pattern:

```bash
# 1. Check existing open PRs on upstream
gh pr list --state open --repo <upstream-owner>/<repo>

# Example output showing a chain:
# 31  Add non-interactive init     ejc3:feature/non-interactive-init  OPEN
# 30  Add configurable subdirectory  ejc3:feature/configurable-subdirectory  OPEN
# ...
# 25  refactor: replace git2       ejc3:feature/scm-abstraction  OPEN
```

**Creating a new PR in the chain:**

1. **Base on master** - All your changes should be in the branch
2. **PR description shows delta** - Only describe what's new since the previous PR
3. **Reference the chain** - Use format: `> **Stack:** #25 → #26 → ... → #31 → **This PR**`

```markdown
## Summary

Brief description of THIS PR's changes only.

> **Stack:** #25 → #26 → #27 → #28 → #29 → #30 → #31 → **This PR**
>
> This PR depends on #31 and should be reviewed/merged after it.

## Changes (delta from #31)

**22 files changed, +1,099 / -4,747 lines**

### What's new in THIS PR
- Feature 1
- Feature 2
- Removed: old module

## Test plan
- [x] Tests passing
- [x] Manual testing done
```

**Finding the delta:**

```bash
# Compare your branch to the previous PR's branch
git log origin/feature/previous-pr..origin/your-branch --oneline
git diff origin/feature/previous-pr..origin/your-branch --stat
```

**If token lacks upstream access:**

```bash
# Push to your fork
git push origin your-branch

# Get URL to create PR manually
echo "https://github.com/<upstream>/compare/master...<you>:<repo>:<branch>?expand=1"
```

## File Organization

### Project-Specific Instructions

- Keep a `CLAUDE.md` in project root for project-specific context
- Update it when architecture changes
- Include recent decisions and patterns
- Reference it in commit messages when following conventions

---

## fuse-pipe Tracing and Telemetry

### Overview

fuse-pipe includes a distributed tracing system for measuring end-to-end latency of FUSE operations. Traces capture timing at multiple points in the request/response pipeline to identify bottlenecks.

### Span Structure

The `Span` struct in `protocol/wire.rs` captures timing at 8 points:

```rust
pub struct Span {
    pub t0: u64,             // Client: request created
    pub server_recv: u64,    // Server: received from socket
    pub server_deser: u64,   // Server: deserialized request
    pub server_spawn: u64,   // Server: spawned handler task
    pub server_fs_done: u64, // Server: filesystem operation complete
    pub server_resp_chan: u64, // Server: response sent to channel
    pub client_recv: u64,    // Client: received response
    pub client_done: u64,    // Client: finished processing
}
```

### Latency Phases

From the span timestamps, these latency phases are computed:

| Phase | Meaning |
|-------|---------|
| `to_server` | Network: client → server |
| `server_deser` | Request deserialization |
| `server_spawn` | Task spawn overhead |
| `server_fs` | Filesystem operation (read/write/stat) |
| `server_chan` | Response channel send |
| `to_client` | Network: server → client |
| `client_done` | Client response processing |
| **total** | End-to-end latency |

### SpanCollector API

```rust
use fuse_pipe::{SpanCollector, SpanSummary};

// Create collector
let collector = SpanCollector::new();

// Record spans (automatically done by Multiplexer)
collector.record(unique_id, span);

// Get summary with percentile statistics
if let Some(summary) = collector.summary() {
    println!("p50 total: {}µs", summary.total.p50_us);
    println!("p99 total: {}µs", summary.total.p99_us);
}

// Print formatted summary to stderr
collector.print_summary();

// Export as JSON
if let Some(json) = collector.summary_json() {
    std::fs::write("telemetry.json", &json)?;
}
```

### Enabling Tracing in Tests

#### Mount with Telemetry Collection

```rust
use fuse_pipe::{mount_with_telemetry, SpanCollector};

let collector = SpanCollector::new();
mount_with_telemetry(
    "/tmp/fuse.sock",
    "/mnt/fuse",
    256,        // num_readers
    10,         // trace_rate: trace every 10th request
    Some(collector.clone())
)?;

// After unmount, get summary
collector.print_summary();
```

#### Stress Test CLI

```bash
# Run stress test with tracing (every 10th request)
cargo test --test stress --release -- -t 10

# Client subcommand with JSON output
./stress client -s /tmp/fuse.sock -m /mnt/fuse -r 256 -t 10 \
    --telemetry-output /tmp/telemetry.json
```

### trace_rate Parameter

- `0` = Tracing disabled (no overhead)
- `1` = Trace every request (highest overhead)
- `10` = Trace every 10th request (recommended for benchmarks)
- `100` = Trace every 100th request (minimal overhead)

### Sample Output

```json
{
  "count": 1024,
  "total": {"p50_us": 85, "p90_us": 110, "p99_us": 180, "max_us": 450},
  "to_server": {"p50_us": 12, "p90_us": 18, "p99_us": 25, "max_us": 45},
  "server_deser": {"p50_us": 2, "p90_us": 3, "p99_us": 5, "max_us": 12},
  "server_spawn": {"p50_us": 3, "p90_us": 8, "p99_us": 15, "max_us": 35},
  "server_fs": {"p50_us": 55, "p90_us": 75, "p99_us": 120, "max_us": 350},
  "server_chan": {"p50_us": 1, "p90_us": 2, "p99_us": 3, "max_us": 8},
  "to_client": {"p50_us": 10, "p90_us": 15, "p99_us": 22, "max_us": 40},
  "client_done": {"p50_us": 1, "p90_us": 2, "p99_us": 3, "max_us": 10}
}
```

### Key Files

- `fuse-pipe/src/telemetry.rs` - SpanCollector, SpanSummary, LatencyStats
- `fuse-pipe/src/protocol/wire.rs` - Span struct with timing fields
- `fuse-pipe/src/client/multiplexer.rs` - Records spans when trace_rate > 0
- `fuse-pipe/src/client/mount.rs` - `mount_with_telemetry()` function

### Performance Insights

From benchmarks on c6g.metal (64 ARM cores):

- **Typical total latency**: 80-120µs for small reads
- **Main bottleneck**: `server_fs` (filesystem I/O) at 50-80µs
- **Network overhead**: ~20-30µs combined (to_server + to_client)
- **Serialization**: ~5µs combined (deser + spawn + chan)

---

## Terraform Best Practices

### Critical Rule: Terraform Only for AWS Changes

**NEVER make AWS changes directly via CLI.** All infrastructure changes MUST go through Terraform:

- ❌ `aws ec2 run-instances` - NO
- ❌ `aws ec2 modify-instance-attribute` - NO
- ❌ `aws ec2 create-volume` - NO
- ❌ Any `aws` command that creates/modifies/deletes resources - NO

- ✅ Edit `.tf` files, then `terraform apply` - YES
- ✅ `aws` commands for READ-ONLY queries (describe, list, get) - OK

**Why?** Direct CLI changes cause terraform state drift. The state becomes out of sync with reality, leading to confusing errors and potential data loss.

**If you need to make a quick fix:**
1. Update the terraform files first
2. Run `terraform apply`
3. Verify the change worked

**Exception:** Disaster recovery only - if terraform is broken and you need to urgently restore service.

---

## AWS SSO Authentication

### Critical Lessons

1. **SSO Session Format is Required**
   - Must use `[sso-session]` block in `~/.aws/config`
   - Device code flow (`--no-browser`) doesn't work with all SSO setups
   - PKCE flow (browser-based) is the reliable method

2. **Region Must Match SSO Region**
   - `sso_region` must match where your IAM Identity Center is deployed
   - Using wrong region causes `InvalidRequestException` errors

3. **SSO Configuration Structure**
   ```
   [sso-session default-sso]
   sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
   sso_region = us-west-1
   sso_registration_scopes = sso:account:access

   [profile default]
   sso_session = default-sso
   sso_account_id = 123456789012
   sso_role_name = AdministratorAccess
   region = us-west-1
   ```

4. **Container Authentication Flow**
   - AWS CLI must run on HOST for browser-based auth (PKCE flow)
   - Container accesses cached credentials in `~/.aws/`
   - Login on host: `aws sso login --profile default`
   - Container reads from mounted `~/.aws:/root/.aws:ro`

5. **Common Pitfalls**
   - ❌ Device code flow with `#/device` URLs - often fails
   - ❌ Running AWS CLI only in container - can't open browser
   - ✅ Browser-based PKCE flow on host - reliable
   - ✅ Mount ~/.aws as read-only in container

---

## Terraform: apply ONLY from a fresh worktree off origin/main

**Never run `terraform apply` from a working tree with uncommitted edits.** Commit first, then
apply from a clean checkout:

```bash
git -C ~/aws fetch origin
git -C ~/aws worktree add /tmp/tf-$(date +%s) origin/main   # detached, exactly what is on main
cd /tmp/tf-<stamp> && terraform init -input=false && terraform plan && terraform apply
```

**Why:** on 2026-08-16 several changes were applied from a dirty tree and never committed —
SSM role attachments, the t4g.large resize, the snap-aware SSM block, the CloudWatch agent,
`--auto` on the launcher. A later `git reset --hard origin/main` erased the source while the
infrastructure kept running it. The next apply from `main` would have destroyed the SSM
attachments and shrunk the box back to the 4GB that had already OOM-killed a user's session.
Nobody would have known until it happened.

Applying only from a fresh worktree makes "applied but uncommitted" structurally impossible:
if it is not committed, it cannot be applied. It also means the plan you review is the plan
`main` produces, not one contaminated by local edits.

Corollary: `git reset --hard` in a directory you have been applying from is destructive in a
way `git` cannot warn you about. Prefer a throwaway worktree per change.

## Dev box -> jumpbox connections are NOT permitted

**Nothing on a dev server may connect to a jumpbox.** Not SSH, not a forced-command key,
not an SSM SendCommand, not a queue the jumpbox polls. The trust direction is one-way:

```
phone -> jumpbox -> dev server        NEVER  dev server -> jumpbox
```

The dev boxes run agents with `--dangerously-skip-permissions`, and the jumpbox is where
the AWS admin session lives. `dev-hop-key.tf` removed `~/.ssh/fcvm-ec2` from the dev boxes
for exactly this reason; `pbox-key.tf` then quietly reintroduced the path with a
forced-command key, and it survived a year because "it can only run one script" sounds
safe.

It is not the transport that matters. **Every delegation transport has the same blast
radius** -- SSH forced command, SSM, or a polled queue all end with "a compromised dev box
causes the jumpbox to run something as root." They differ in audit trail, not capability.
Do not propose one as a mitigation for another.

When a dev box needs to do something privileged, give it a **narrow, tag-scoped IAM grant
and let it call AWS directly**. `parallel-box-launch.tf` is the worked example: a launch
template holds the whole launch configuration, and the dev role may only RunInstances from
it with a required Name tag, pass exactly one role, and touch two named volumes. Precedent
for that shape already existed in `parallel-box-watchdog.tf`, which has always terminated
those boxes with tag-scoped `ec2:TerminateInstances`.

Two things that make such a policy fail closed rather than silently over-grant:

- **A tag condition on a RunInstances statement that also covers the AMI denies the AMI.**
  Split it: created resources (instance/volume/ENI) carry the `aws:RequestTag` condition,
  referenced ones (image, subnet, SG, key pair, launch template) are pinned to exact ARNs.
- **`iam:PassRole` is the escalation.** Pin it to one role ARN with
  `iam:PassedToService = ec2.amazonaws.com`. A wildcard there hands the box any role in the
  account.

On a shared box, remember an instance-role grant is a **box-wide** grant: every account on
`nextjs-dev` has full sudo, so per-user key placement is convenience, never isolation.

## Operating Live Hosts

### Critical Rule: ASK before restarting or rebooting anything

**Never reboot, restart or stop a host on your own initiative.** Ask, and wait for an answer,
even when you are confident and even when something is broken.

- ❌ Rebooting because the evidence "changed" after the user said to wait
- ❌ Restarting a service to prove a permission works (this took a live dev server down)
- ✅ Present the evidence, recommend the action, let the user decide

Somebody may be sitting in that session. The cost of asking is a few seconds; the cost of
being wrong is their unsaved work.

### A 302 behind Cloudflare Access is NOT a health check

`curl https://<host>` returning **302 is the SSO gate**, served by Cloudflare at the edge. It
appears whether or not `cloudflared` is running and whether or not the origin exists. Health
was reported as "fine" from that signal for half an hour while **both tunnels were down**.

Check the tunnel itself:

```bash
T=$(aws secretsmanager get-secret-value --secret-id cloudflare-tunnel-token \
      --region us-west-1 --query SecretString --output text)
curl -s -H "Authorization: Bearer $T" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/cfd_tunnel/$TUNNEL_ID" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; \
      print(r['status'], len(r.get('connections') or []))"
```

`status=down conns=0` is the truth. Only `cloudflare-tunnel-token` has this permission; the
api/account tokens return 401.

### Diagnose before acting: packet, syscall, or metric

Guards, retries, longer timeouts and kills hide faults instead of fixing them. Every real
answer came from evidence, every wrong one from reasoning about what ought to be true:

- `ss -tnpi` showed `SYN-SENT ... retrans:1/7` → a security group with no `::/0` egress, so
  IPv6 to genuinely dual-stack endpoints (secretsmanager) hung 60-90s while sts/s3 (IPv4-only
  addresses) were fine. Three weeks old, invisible until something waited on it.
- `VolumeReadBytes` flat at 7,500 MB/min (= the 125 MB/s gp3 cap) with **writes at ~0** is the
  signature of **swap thrashing**, not load. CPU was only 66% with full burst credits.
- `/proc/<pid>/stack` and `getent ahostsv6` settle in seconds what theories cannot.

### Every host needs SSM

`nextjs-dev` had no `AmazonSSMManagedInstanceCore`, so when sshd stopped completing its
handshake there was **no second way in** — no way to read load, name the runaway, or confirm
the machine was alive.

The agent was NOT missing. Ubuntu's AMI ships it as a **snap**, running as
`snap.amazon-ssm-agent.amazon-ssm-agent.service`. Two traps:

- `systemctl is-active amazon-ssm-agent` reports **inactive** on a snap install — that unit
  name does not exist. Check the snap unit, or `snap list amazon-ssm-agent`.
- Installing the `.deb` does not help: the preinst refuses ("installed in this instance by
  snap, please use snap") and exits 1.

So the agent had been running for weeks, unable to register, purely for want of the IAM
policy. Attach the policy and **wait** — registration lags the attach by minutes. Do not
reboot to force it; that destroys the evidence you wanted SSM for in the first place.

### Sizing: count the humans, not the box

The nextjs-dev swapfile comment assumed "2x next, 2x claude, 2x codex". With four accounts it
is 4 of each on 4 GB RAM, and the box pages until the disk saturates and everything else
starves. There is no memory metric without the CloudWatch agent, so this is invisible in
CloudWatch — infer it from `VolumeReadBytes` + `VolumeQueueLength`.

### Upstream first: run scripts/dev-box-triage.sh before diagnosing anything

`ejc3/aws` has `scripts/dev-box-triage.sh`. Run it FIRST when the dev box "breaks". It checks
the Anthropic status feed, real tunnel state, memory/swap, the EBS starvation signature and
per-user Remote Control, then prints a verdict. It is read-only.

On 2026-08-16 an hour went into diagnosing Remote Control failures that turned out to be a
published Anthropic incident. The symptoms of an upstream outage look exactly like a local
fault, and the difference is one HTTP call to the status page.

Statuspage lifecycle is `investigating → identified → monitoring → resolved`. **monitoring
means the fix is already in** — retry before concluding it is still broken. That is how the
outage ended: session creation worked again while the page still said monitoring, and one
`/remote-control` per session brought it back with no restarts.

### Capturing what an API error actually says

`[bridge] Session creation failed` logged only a status code. The body — which named the
cause — needed a packet capture:

```bash
sudo /tmp/mitmdump --mode transparent --showhost --set confdir=/home/<user>/.mitmproxy \
  -p 8888 -w /tmp/flows.mitm &
sudo iptables  -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(id -u <user>)" \
  -j REDIRECT --to-port 8888
sudo ip6tables       -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(id -u <user>)" -j REJECT
sudo -u <user> env NODE_EXTRA_CA_CERTS=/home/<user>/.mitmproxy/mitmproxy-ca-cert.pem <cmd>
sudo /tmp/mitmdump -nr /tmp/flows.mitm --set flow_detail=3
```

Two traps cost three attempts:

- Run the proxy as **root**, not as the intercepted user. A uid-scoped REDIRECT catches the
  proxy's OWN upstream connections and loops; the symptom is `curl` returning `000`.
- **Block IPv6 for that uid.** v6 REDIRECT does not give mitmproxy `SO_ORIGINAL_DST`, and
  since the v6 egress fix these clients prefer v6 and sail around a v4-only rule. `NODE_OPTIONS`
  will not steer it either — `claude` is a bundled single-executable.

The answer was `{"type":"overloaded_error","message":"Overloaded"}` with a 503: capacity
shedding, during an incident. Never restart a session in response to a 503 — the conversation
dies and the error does not care.

### Unattended launchers need t-claude --auto

`agents-start` ran `t-claude --remote-control`. The non-auto path is `claude --resume`, which
renders the session PICKER as soon as a user has any transcript — and a picker waits for a
keypress systemd will never send. The window sits there with no claude running, so Remote
Control has nothing to attach to. `--auto` resolves to `--continue` when transcripts exist and
plain `claude` when they do not. Any launcher started by systemd must pass it.

---

**Last Updated**: 2026-08-16
