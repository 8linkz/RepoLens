# Finalization Summary

## Issue

GitHub issue #214: switch the Claude backend to `--output-format json` and use the structured envelope for failure classification.

## Reviewed Changes

- `lib/core.sh` now invokes Claude with `--output-format json`, emits `.result` for existing text consumers, and writes optional envelope sidecars.
- `lib/streak.sh` classifies structured Claude envelopes for budget exhaustion, refusals, max-token truncation, rate limits, auth/model failures, and generic agent errors.
- `repolens.sh` persists per-iteration envelope sidecars and classifies structured failures before DONE/no-progress handling.
- `lib/triage.sh`, `lib/synthesize.sh`, `lib/verify.sh`, and `lib/rounds.sh` route phase-local envelope sidecars through shared failure handling.
- Tests were added or extended for the Claude envelope wrapper and structured rc=0 rate-limit handling in non-lens phases.

## Commands Run

- `git status --short`
- `find logs/issues/214 -maxdepth 2 -type f -print`
- `sed -n '1,200p' logs/issues/214/commit-message.txt`
- `git diff --stat -- ./`
- `sed -n '1,220p' logs/issues/214/issue.json`
- `sed -n '1,220p' logs/issues/214/implementation.md`
- `sed -n '1,220p' logs/issues/214/review-correctness.md`
- `git diff -- ./lib/core.sh ./lib/streak.sh ./repolens.sh`
- `sed -n '1,240p' tests/test_agent_json_envelope.sh`
- `sed -n '1,220p' logs/issues/214/controller-decision.md`
- `bash -n ./lib/core.sh ./lib/streak.sh ./lib/rounds.sh ./lib/synthesize.sh ./lib/triage.sh ./lib/verify.sh ./repolens.sh ./tests/test_agent_json_envelope.sh ./tests/test_meta_orchestrator_dispatch.sh ./tests/test_synthesize_validate_manifest.sh ./tests/test_triage_dispatcher.sh ./tests/test_verify_dispatcher.sh`
- `bash ./tests/test_agent_json_envelope.sh`
- `bash ./tests/test_triage_dispatcher.sh`
- `bash ./tests/test_synthesize_validate_manifest.sh`
- `bash ./tests/test_verify_dispatcher.sh`
- `bash ./tests/test_meta_orchestrator_dispatch.sh`
- `bash ./tests/test_agent_failure_classification.sh`
- `bash ./tests/test_rate_limit_phase_helper.sh`
- `git diff --check -- ./`

## Verification

- Syntax check passed for the modified shell libraries, CLI, and issue-focused tests.
- `tests/test_agent_json_envelope.sh`: 12 passed, 0 failed.
- `tests/test_triage_dispatcher.sh`: 43 passed, 0 failed.
- `tests/test_synthesize_validate_manifest.sh`: 53 passed, 0 failed.
- `tests/test_verify_dispatcher.sh`: 49 passed, 0 failed.
- `tests/test_meta_orchestrator_dispatch.sh`: 50 passed, 0 failed.
- `tests/test_agent_failure_classification.sh`: 6 passed, 0 failed.
- `tests/test_rate_limit_phase_helper.sh`: 6 passed, 0 failed.
- `git diff --check -- ./` passed.

## Final Git Status

Before staging and commit, the worktree contained only issue #214 implementation and test changes plus this finalization file. After staging those paths and committing with `git commit -F "logs/issues/214/commit-message.txt"`, the expected final status is clean.
