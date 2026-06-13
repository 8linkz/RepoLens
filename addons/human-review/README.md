# Human Review Add-on

This add-on runs RepoLens lens by lens without changing the core `repolens.sh`
run loop. It creates a parent run with a queue, then starts exactly one focused
RepoLens child run per invocation.

## Start

```bash
bash addons/human-review/repolens-human.sh start \
  --project ~/my-app \
  --agent codex \
  --local \
  --yes \
  --domain security
```

The `start` command resolves the lens list through RepoLens `--dry-run`, writes
`logs/human-review/<parent-run-id>/queue.json`, then runs the first lens.

To begin at a 1-based lens offset while keeping the full queue visible:

```bash
bash addons/human-review/repolens-human.sh start \
  --start-at 56 \
  --project ~/my-app \
  --agent codex \
  --local \
  --yes
```

Entries before the offset are marked `skipped` in `queue.json` and counted as
`skipped_lenses` in `latest-result.json`.

## Continue

```bash
bash addons/human-review/repolens-human.sh next <parent-run-id>
```

If the previous child run ended with RepoLens exit code `3`, the active queue
entry stays `rate_limited_retryable`. The next invocation retries that same lens
instead of advancing to the next lens.

## Current Session Bridge

Use `current-session` when you want this already-running Codex session to do the
work instead of launching a local agent CLI:

```bash
bash addons/human-review/repolens-human.sh start \
  --project ~/my-app \
  --agent current-session \
  --local \
  --yes
```

`next` writes a task prompt and output directory, then pauses the queue with
status `awaiting_current_session`. After this session writes the finding files,
mark the lens done:

```bash
bash addons/human-review/repolens-human.sh complete <parent-run-id>
```

## Artifacts

Each parent run writes:

- `metadata.json` - original RepoLens arguments and parent status
- `queue.json` - ordered lens queue and per-lens status
- `attempts.json` - one record per child RepoLens invocation
- `latest-result.json` - current status and next action
- `attempts/attempt-NNN.out` - captured child run output
- `current-session/tasks/*/prompt.md` - bridge prompts for active-session work
- `current-session/lens-outputs/<domain>/<lens>/` - bridge finding output

The latest parent result is also copied to:

```text
logs/human-review/latest-result.json
```

## Rate Limits

Child runs default `REPOLENS_RATE_LIMIT_MAX_SLEEP=0` so RepoLens returns control
to the add-on instead of sleeping for a long provider cooldown. Override this
only when you explicitly want the child RepoLens process to wait:

```bash
REPOLENS_HUMAN_RATE_LIMIT_MAX_SLEEP=300 \
  bash addons/human-review/repolens-human.sh next <parent-run-id>
```
