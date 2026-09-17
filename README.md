# Worktrunk for Windows

A Windows-only [Herdr](https://herdr.dev) plugin for switching, creating,
merging, and removing Git worktrees through
[Worktrunk](https://worktrunk.dev). It is a native Windows PowerShell port of
[`devashish2203/herdr-worktrunk`](https://github.com/devashish2203/herdr-worktrunk).

The plugin uses Worktrunk for worktree lifecycle hooks and Herdr for native
worktree workspaces or tabs. It does not require Bash, WSL, `jq`, `sed`, or
`awk`.

## Status

This fork is under active development. Its automated tests run in native
Windows PowerShell 5.1, but releases should also receive a manual smoke test in
Herdr on Windows before being considered stable.

## Requirements

- Windows 10 or newer
- [Herdr](https://herdr.dev) 0.8.0 or newer
- [Git for Windows](https://git-scm.com/download/win)
- [Worktrunk](https://worktrunk.dev) 0.60.0 or newer, installed as `git-wt`
- [fzf](https://github.com/junegunn/fzf)
- Windows PowerShell 5.1 or newer

Install the command-line dependencies with Winget:

```powershell
winget install Git.Git
winget install max-sixty.worktrunk
winget install junegunn.fzf
```

Worktrunk is deliberately invoked as `git-wt`, not `wt`: Windows Terminal owns
an unrelated `wt.exe` application alias.

## Installation

For local development:

```powershell
git clone --branch windows-powershell --single-branch https://github.com/giard-alexandre/herdr-worktrunk-windows.git
Set-Location herdr-worktrunk-windows
herdr plugin link $PWD
```

Install directly from GitHub (the branch is required; default `main` is the Bash plugin):

```powershell
herdr plugin install giard-alexandre/herdr-worktrunk-windows --ref windows-powershell
```

The plugin ID is `worktrunk.windows`.

## Actions

- `worktrunk.windows.open` — switch or create from Worktrunk's default branch
- `worktrunk.windows.open-current` — switch or create from the current branch
- `worktrunk.windows.open-with-remotes` — include remote-tracking branches
- `worktrunk.windows.remove` — remove a non-main worktree
- `worktrunk.windows.merge` — merge and remove a worktree
- `worktrunk.windows.merge-no-squash` — merge without squashing, then remove

Example keybindings in the Herdr config:

```toml
[[keys.command]]
key = "prefix+shift+g"
type = "plugin_action"
command = "worktrunk.windows.open"
description = "Worktree: switch / create"

[[keys.command]]
key = "prefix+shift+d"
type = "plugin_action"
command = "worktrunk.windows.remove"
description = "Worktree: remove"

[[keys.command]]
key = "prefix+shift+m"
type = "plugin_action"
command = "worktrunk.windows.merge"
description = "Worktree: merge"
```

Reload Herdr after editing its configuration:

```powershell
herdr server reload-config
```

## Configuration

Find the plugin-managed configuration directory and create `config.toml`:

```powershell
$configDir = herdr plugin config-dir worktrunk.windows
New-Item -ItemType Directory -Force $configDir | Out-Null
notepad (Join-Path $configDir 'config.toml')
```

Example configuration:

```toml
open_mode = "workspace"
show_remote_branches = false
picker_placement = "popup"
popup_width = "70%"
popup_height = 24
merge_flags = "--no-squash --no-rebase"
```

### Worktree presentation

- `open_mode = "workspace"` is the default. Worktrunk creates or switches the
  checkout, then the plugin registers it with `herdr worktree open`.
- `open_mode = "tab"` opens a Herdr tab and sends the switch command to that
  tab's interactive PowerShell or Nushell session.

Tab mode requires Worktrunk's shell integration:

```powershell
git-wt config shell install
```

Restart the shell after installation. PowerShell and Nushell are supported for
tab mode; `cmd.exe` is not. Workspace mode does not require shell integration.

### Remote branches

Set:

```toml
show_remote_branches = true
```

The dedicated `open-with-remotes` action enables them for one invocation
regardless of this setting. Run `git fetch` yourself when you want refreshed
remote refs.

### Picker placement

- `picker_placement = "split"` opens below the current pane and is the default.
- `picker_placement = "popup"` opens a session-modal popup.

Popup dimensions accept terminal cells or percentages:

```toml
popup_width = "80%"
popup_height = 24
```

### Merge flags

Supported values are:

- `--no-squash`
- `--no-rebase`
- `--no-ff`
- `--no-commit`
- `--no-hooks`
- `--stage=all|tracked|none`

Selecting removal immediately runs Worktrunk removal; the plugin does not ask
for confirmation. Worktrunk's unmerged/untracked-file protections still apply.

## Worktree created but not opened

Worktrunk creates the checkout before the plugin registers it with Herdr. Earlier
plugin versions could stop between these steps on Windows PowerShell 5.1:
Worktrunk's success message on stderr was treated as a terminating PowerShell
error, even when Worktrunk exited successfully. Native JSON commands now use
the process exit code to determine success, not the presence of stderr output.

After updating the plugin, select the existing branch again to register its
checkout; there is no need to delete or recreate the worktree.

## PowerShell execution policy

Every manifest command requests a process-scoped execution-policy bypass:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...
```

This does not modify the user's configured policy. A centrally enforced
`MachinePolicy` or `UserPolicy` can still prohibit scripts. Check with:

```powershell
Get-ExecutionPolicy -List
```

Machines whose administrators prohibit PowerShell scripts cannot run this
PowerShell-based fork.

## Development

The implementation is organized as:

- `scripts/Worktrunk.Common.ps1` — configuration, JSON normalization, path,
  picker, shell-command, and lifecycle helpers
- `scripts/Open.ps1` — action-to-pane bridge
- `scripts/Picker.ps1` — switch/create flow
- `scripts/Remove.ps1` — removal flow
- `scripts/Merge.ps1` — merge/removal flow
- `scripts/TabRelabel.ps1` — tab-mode post-switch relabeling
- `tests/Run-Tests.ps1` — dependency-free PowerShell behavior and parser tests

Run tests in native Windows PowerShell:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

To verify generated Nushell commands against the real Worktrunk integration,
provide a v0.60 binary and its exact upstream `git-wt.nu` script (requires `nu`):

```powershell
powershell.exe -NoProfile -File tests\Test-NushellIntegration.ps1 -WorktrunkBinary C:\Tools\git-wt.exe -IntegrationScript C:\Tools\git-wt.nu
```

This checks successful switching and failed switching with absent and stale
Nushell exit-status variables. Only the final relabel executable is mocked.

When editing `herdr-plugin.toml`, relink the plugin:

```powershell
herdr plugin unlink worktrunk.windows
herdr plugin link $PWD
```

## License

[MIT](LICENSE.md) © Devashish Chandra and contributors
