# Dev Doctor

`dev-doctor` is a reusable pre-start checker. It reads a JSON profile, checks
the current shell environment, and reports missing or broken tools before a
long-running workflow starts.

## RepoLens

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --project /path/to/target-repo --agent codex --local
```

Use `--local` when RepoLens will write local markdown output instead of filing
remote issues. Without `--local`, the RepoLens profile also requires a forge CLI
such as `gh`.

`--project` points dev-doctor at the repository that will be reviewed. Profile
checks can use project files such as `go.mod` to require language toolchains
only when the target repo needs them.

For Claude:

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --agent claude --local
```

For machine-readable output:

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --agent codex --local --json
```

## Run With Checked Tools

Use `dev-doctor-run` for project commands that depend on the checked tools:

```bash
bash addons/dev-doctor/dev-doctor-run.sh repolens \
  --project /path/to/target-repo \
  --agent current-session \
  --local \
  -- go test ./...
```

The runner executes the command only after `dev-doctor` reports all required
checks healthy. It also prepends the same tool directories that the preflight
resolved, so direct WSL commands can find user-local tools such as
`~/.local/bin/go` without relying on shell profile loading. When `--project` is
provided, the command runs from that project directory.

From Windows PowerShell, use `wsl.exe --exec` plus PowerShell's stop-parsing
token when command arguments contain shell-sensitive characters:

```powershell
wsl.exe --% --cd /mnt/e/Github/RepoLens --exec bash addons/dev-doctor/dev-doctor-run.sh repolens --project /mnt/e/Github/talvex-node --agent current-session --local -- rg -n -F -e Header().Set /mnt/e/Github/talvex-node/internal/node/health.go
```

## Install Missing Packages

Dry-run is the default. To let `dev-doctor` install declared missing packages:

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --project /path/to/target-repo --agent codex --local --apply
```

For the common "prepare this agent" case, use:

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --project /path/to/target-repo --install-agent codex --local
```

To prepare every agent declared by the profile:

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --all-agents --local --apply
```

Equivalent shorthand:

```bash
bash addons/dev-doctor/dev-doctor.sh repolens --install-agent all --local
```

On Windows/WSL, use the interactive launcher when installs may need the WSL root
password:

```powershell
powershell -ExecutionPolicy Bypass -File addons/dev-doctor/dev-doctor-interactive.ps1 `
  repolens --install-agent codex --local
```

This opens a visible terminal window, runs the same `dev-doctor` command inside
WSL, and allows `sudo` to prompt for your password.

`--apply` is conservative:

- installs declared `apt` packages with `sudo apt-get`
- runs declared `install.shell` commands for tools with standalone installers
- installs declared `npm_global` packages when the command is missing or broken
- still reports broken commands after installation

For RepoLens, the Codex CLI uses OpenAI's macOS/Linux standalone installer in
WSL:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

This avoids the common broken state where WSL resolves a Windows npm shim such
as `/mnt/c/Users/.../npm/codex`.

Authentication remains manual. If `gh`, `codex`, or `claude` is installed but
not logged in, run the provider's login command yourself.

## Install As A User Tool

```bash
bash addons/dev-doctor/install.sh
```

This writes:

```text
~/.local/bin/dev-doctor
~/.config/dev-doctor/profiles/repolens.json
```

After that:

```bash
dev-doctor repolens --agent codex --local
```

## Reuse In Another Repo

Create a profile in the target repo:

```text
.devdoctor.json
```

Then run:

```bash
bash /path/to/RepoLens/addons/dev-doctor/dev-doctor.sh --agent codex --local
```

For target-specific dependencies, pass the target path:

```bash
bash /path/to/RepoLens/addons/dev-doctor/dev-doctor.sh \
  repolens --project "$PWD" --agent codex --local
```

Or pass a profile explicitly:

```bash
bash /path/to/RepoLens/addons/dev-doctor/dev-doctor.sh \
  --profile /path/to/other-repo/.devdoctor.json \
  --agent codex
```

## Profile Shape

```json
{
  "name": "my-repo",
  "checks": [
    {
      "id": "jq",
      "command": "jq",
      "required": true,
      "health": "jq --version >/dev/null 2>&1",
      "install": {
        "apt": "jq",
        "hint": "sudo apt-get install -y jq"
      }
    }
  ]
}
```

Supported requirement conditions:

- `"required": true`
- `"required_when": {"agent": ["codex", "opencode/*"]}`
- `"required_when": {"not_local": true}`
- `"required_when": {"project_files": ["go.mod"]}`
- `"optional": true`

Supported install metadata:

- `install.apt`
- `install.brew`
- `install.winget`
- `install.npm_global`
- `install.shell`
- `install.hint`
