Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Assertions = 0
$IsNativeWindows = $env:OS -eq 'Windows_NT'

function Assert-Equal {
    param($Expected, $Actual, [string]$Label = 'value')
    $script:Assertions++
    if ($Expected -ne $Actual) {
        throw "Expected $Label '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Label)
    $script:Assertions++
    if (-not $Condition) { throw "Expected true: $Label." }
}

function Assert-False {
    param([bool]$Condition, [string]$Label)
    $script:Assertions++
    if ($Condition) { throw "Expected false: $Label." }
}

function Assert-Contains {
    param([string]$Needle, [string]$Haystack, [string]$Label)
    $script:Assertions++
    if (-not $Haystack.Contains($Needle)) { throw "Expected '$Needle' in $Label '$Haystack'." }
}

# Parse every PowerShell file using the in-box language parser. This catches syntax
# errors without requiring Pester or PSScriptAnalyzer.
Get-ChildItem -LiteralPath $RepoRoot -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $messages = ($errors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parse errors in $($_.FullName): $messages"
    }
}

. (Join-Path $RepoRoot 'scripts\Worktrunk.Common.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-worktrunk-tests-" + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $tempRoot 'config'
$stubDir = Join-Path $tempRoot 'stubs'
New-Item -ItemType Directory -Path $configDir, $stubDir -Force | Out-Null
$oldPath = $env:PATH
$oldConfig = $env:HERDR_PLUGIN_CONFIG_DIR
try {
    $env:HERDR_PLUGIN_CONFIG_DIR = $configDir

    Assert-Equal 'workspace' (Get-WorktrunkOpenMode) 'default open mode'
    Assert-Equal 'split' (Get-WorktrunkPickerPlacement) 'default picker placement'
    Assert-False (Get-WorktrunkShowRemoteBranches) 'default remote branches'

    @'
open_mode = "tab"
show_remote_branches = true
picker_placement = "popup"
popup_width = "80%"
popup_height = 24
merge_flags = "--no-squash --no-rebase --stage=tracked --unsafe"
open_mode = "workspace" # last value wins
'@ | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII

    Assert-Equal 'workspace' (Get-WorktrunkOpenMode) 'configured open mode'
    Assert-Equal 'popup' (Get-WorktrunkPickerPlacement) 'configured picker placement'
    Assert-True (Get-WorktrunkShowRemoteBranches) 'configured remote branches'
    Assert-Equal '80%' (Get-WorktrunkPopupDimension 'popup_width') 'popup width'
    Assert-Equal '24' (Get-WorktrunkPopupDimension 'popup_height') 'popup height'
    Assert-Equal '--no-squash --no-rebase --stage=tracked' (@(Get-WorktrunkMergeFlags) -join ' ') 'merge flags'
    Assert-Equal '--border=none --margin=0' (@(Get-WorktrunkFzfArguments) -join ' ') 'popup fzf layout'

    'popup_width = "wide"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII
    Assert-Equal $null (Get-WorktrunkPopupDimension 'popup_width') 'invalid popup width'

    foreach ($shortcut in @('^', '-', 'pr:12', 'mr:4', 'https://github.com/o/r/pull/7')) {
        Assert-True (Test-WorktrunkShortcut $shortcut) "shortcut $shortcut"
    }
    foreach ($name in @('main', 'feature/foo', '@')) {
        Assert-False (Test-WorktrunkShortcut $name) "ordinary branch $name"
    }
    Assert-Equal 'main' (Get-WorktrunkSwitchLabel 'main' 'main') 'same branch label'
    Assert-Equal 'feature/x (pr:12)' (Get-WorktrunkSwitchLabel 'feature/x' 'pr:12') 'shortcut label'

    Assert-Equal 0 @(ConvertTo-WorktrunkItems '[]').Count 'empty schema one item count'

    $schemaOne = '[{"branch":"main","kind":"worktree","path":"C:\\repo","is_main":true},{"branch":"ready","kind":"branch"}]'
    $items = @(ConvertTo-WorktrunkItems $schemaOne)
    Assert-Equal 2 $items.Count 'schema one item count'
    Assert-Equal 'C:\repo' $items[0].Path 'schema one path'
    Assert-True $items[0].IsMain 'schema one main flag'

    $schemaTwo = '{"schema":2,"items":[{"branch":"feature","worktree":{"path":"C:\\repo.feature","main":false}}]}'
    $items = @(ConvertTo-WorktrunkItems $schemaTwo)
    Assert-Equal 1 $items.Count 'schema two item count'
    Assert-Equal 'worktree' $items[0].Kind 'schema two kind'
    Assert-Equal 'C:\repo.feature' $items[0].Path 'schema two path'

    if ($IsNativeWindows) {
        Assert-True (Test-WindowsPathEqual 'C:\Repo\feature' 'c:/repo/feature/') 'case-insensitive mixed path equality'
        Assert-True (Test-WindowsPathEqual '\\?\C:\Repo' 'c:\repo') 'verbatim drive path equality'
        Assert-True (Test-WindowsPathEqual '\\?\UNC\server\share\repo' '\\server\share\repo') 'verbatim UNC path equality'
        Assert-True (Test-WindowsPathWithin 'C:\repo\feature\src' 'c:\REPO\feature') 'descendant path'
        Assert-False (Test-WindowsPathWithin 'C:\repo\feature-two' 'C:\repo\feature') 'sibling prefix path'
    }

    Assert-Equal "'it''s'" (ConvertTo-PowerShellLiteral "it's") 'PowerShell literal'
    $line = Get-TabSwitchCommand 'powershell.exe' 'C:\Plugin Files\TabRelabel.ps1' 'C:\Herdr\herdr.exe' `
        'w1V:t3' "feat'ure" 'C:\Repo Here' @('switch', '--create', "feat'ure")
    Assert-Contains "git-wt 'switch' '--create' 'feat''ure'" $line 'tab command'
    Assert-Contains "if (`$?)" $line 'tab command success gate'
    Assert-Contains "'C:\Plugin Files\TabRelabel.ps1'" $line 'tab relabel path'

    $nuLine = Get-TabSwitchCommand 'nu.exe' 'C:\Plugin Files\TabRelabel.ps1' 'C:\Herdr\herdr.exe' `
        'w1V:t3' "feat'ure" 'C:\Repo Here' @('switch', '--create', "feat'ure")
    Assert-Contains 'print -n (git-wt' $nuLine 'Nushell tab command'
    Assert-Contains 'if ($env.LAST_EXIT_CODE == 0)' $nuLine 'Nushell relabel success gate'
    Assert-Contains 'powershell.exe -NoProfile' $nuLine 'Nushell relabel command'

    if ($IsNativeWindows) {
        # Verify Open.ps1 builds an argv-based split request and forwards the repository
        # through an environment override while remaining independent of the pane cwd.
        $stubLog = Join-Path $tempRoot 'herdr.log'
        $herdrStub = Join-Path $stubDir 'herdr.cmd'
        "@echo off`r`necho %*>>`"$stubLog`"`r`nexit /b 0`r`n" |
            Set-Content -LiteralPath $herdrStub -Encoding ASCII
        $env:HERDR_BIN_PATH = $herdrStub
        $env:HERDR_PLUGIN_ID = 'worktrunk.windows'
        $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
        $env:HERDR_PLUGIN_CONTEXT_JSON = '{"workspace_cwd":"C:\\Projects\\Repo Here","focused_pane_cwd":"C:\\Other"}'
        'picker_placement = "split"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII

        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Open.ps1') 'picker-default'
        Assert-Equal 0 $LASTEXITCODE 'Open.ps1 exit status'
        $openLog = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'plugin pane open' $openLog 'Herdr open arguments'
        Assert-Contains '--entrypoint picker-default' $openLog 'Herdr open arguments'
        Assert-Contains '--env "WORKTRUNK_REPO_CWD=C:\Projects\Repo Here"' $openLog 'Herdr open arguments'
        Assert-Contains '--placement split --direction down' $openLog 'Herdr open arguments'

        # Native-command integration smoke tests for picker, merge, and remove.
        $env:PATH = "$stubDir;$oldPath"
        $wtLog = Join-Path $tempRoot 'wt.log'
        $fzfInput = Join-Path $tempRoot 'fzf.stdin'
        $repo = Join-Path $tempRoot 'repo'
        $checkout = Join-Path $tempRoot 'repo.feature'
        New-Item -ItemType Directory -Path $repo, $checkout -Force | Out-Null
        & git init --quiet --initial-branch=main $repo
        & git -C $repo -c user.email=test@example.com -c user.name=test commit --quiet --allow-empty -m init
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the test Git repository.' }

        @'
@echo off
more > "%FZF_STDIN%"
if defined FZF_STUB_PICK echo %FZF_STUB_PICK%
exit /b %FZF_STUB_STATUS%
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'fzf.cmd') -Encoding ASCII
        @'
@echo off
echo %*>>"%WT_STUB_LOG%"
if "%1"=="list" echo %WT_STUB_LIST%
if "%1"=="switch" echo %WT_SWITCH_JSON%
if "%1"=="merge" exit /b %WT_MERGE_STATUS%
if "%1"=="remove" exit /b %WT_REMOVE_STATUS%
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'git-wt.cmd') -Encoding ASCII
        @'
@echo off
echo %*>>"%HERDR_STUB_LOG%"
if "%1 %2"=="worktree list" echo %HERDR_LIST_JSON%
if "%1 %2"=="pane list" echo %HERDR_PANE_LIST_JSON%
if "%1 %2"=="tab create" echo %HERDR_TAB_CREATE_JSON%
if "%1 %2"=="pane process-info" echo {"result":{"process_info":{"shell_pid":42,"foreground_processes":[{"pid":42,"name":"%HERDR_STUB_SHELL%"}]}}}
if "%1 %2"=="pane run" exit /b %HERDR_PANE_RUN_STATUS%
exit /b 0
'@ | Set-Content -LiteralPath $herdrStub -Encoding ASCII

        $repoJsonPath = $repo.Replace('\', '/')
        $checkoutJsonPath = $checkout.Replace('\', '/')
        $env:FZF_STDIN = $fzfInput
        $env:FZF_STUB_STATUS = '0'
        $env:WT_STUB_LOG = $wtLog
        $env:HERDR_STUB_LOG = $stubLog
        $env:WT_STUB_LIST = '[{"branch":"main","kind":"worktree","path":"' + $repoJsonPath + '","is_main":true},{"branch":"feature","kind":"worktree","path":"' + $checkoutJsonPath + '","is_main":false}]'
        $env:WT_SWITCH_JSON = '{"branch":"feature/new","path":"' + $checkoutJsonPath + '"}'
        $env:WT_MERGE_STATUS = '0'
        $env:WT_REMOVE_STATUS = '0'
        $env:HERDR_LIST_JSON = '{"result":{"source":{"repo_root":"' + $repoJsonPath + '","repo_name":"repo","source_workspace_id":"w1"},"worktrees":[{"path":"' + $checkoutJsonPath + '","open_workspace_id":"ws-feature"}]}}'
        $env:HERDR_STUB_SHELL = 'powershell.exe'
        $env:HERDR_TAB_CREATE_JSON = '{"result":{"tab":{"tab_id":"w1V:t3"},"root_pane":{"pane_id":"w1V:p5"}}}'
        $env:HERDR_PANE_RUN_STATUS = '0'
        $env:WORKTRUNK_REPO_CWD = $repo
        $env:HERDR_WORKSPACE_ID = 'w1'
        'open_mode = "workspace"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII

        $env:FZF_STUB_PICK = 'feature/new'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default'
        Assert-Equal 0 $LASTEXITCODE 'Picker.ps1 exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'switch --create feature/new --no-cd --format=json' $wtCalls 'Worktrunk picker arguments'
        Assert-Contains 'worktree open' $herdrCalls 'Herdr picker arguments'
        Assert-Contains '--path ' $herdrCalls 'Herdr picker arguments'

        # Successful tab setup sends the switch command and keeps the new tab.
        # Unsupported shells and pane-run failures close that placeholder tab.
        'open_mode = "tab"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII
        $env:FZF_STUB_PICK = 'feature/tab'
        $env:HERDR_STUB_SHELL = 'powershell.exe'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default' *> $null
        Assert-Equal 0 $LASTEXITCODE 'successful tab-mode exit status'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'pane run w1V:p5' $herdrCalls 'successful tab pane-run request'
        Assert-False ($herdrCalls.Contains('tab close')) 'successful tab remains open'

        $env:HERDR_STUB_SHELL = 'cmd.exe'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default' *> $null
        Assert-Equal 1 $LASTEXITCODE 'unsupported tab shell exit status'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'tab close w1V:t3' $herdrCalls 'unsupported-shell tab cleanup'
        Assert-False ($herdrCalls.Contains('pane run')) 'unsupported shell receives no command'

        $env:HERDR_STUB_SHELL = 'powershell.exe'
        $env:HERDR_PANE_RUN_STATUS = '9'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default' *> $null
        Assert-Equal 1 $LASTEXITCODE 'failed pane run exit status'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'pane run w1V:p5' $herdrCalls 'failed pane-run attempt'
        Assert-Contains 'tab close w1V:t3' $herdrCalls 'failed pane-run tab cleanup'

        $env:HERDR_PANE_RUN_STATUS = '0'
        $env:HERDR_TAB_CREATE_JSON = '{"result":{"tab":{"tab_id":"w1V:t3"},"root_pane":{}}}'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default' *> $null
        Assert-Equal 1 $LASTEXITCODE 'missing root pane exit status'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'tab close w1V:t3' $herdrCalls 'partial tab response cleanup'
        Assert-False ($herdrCalls.Contains('pane run')) 'missing root pane receives no command'

        $env:HERDR_TAB_CREATE_JSON = '{"result":{"tab":{"tab_id":"w1V:t3"},"root_pane":{"pane_id":"w1V:p5"}}}'
        'open_mode = "workspace"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII
        $env:FZF_STUB_PICK = 'feature'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Merge.ps1') -NoSquash
        Assert-Equal 0 $LASTEXITCODE 'Merge.ps1 exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'merge --no-remove -C' $wtCalls 'Worktrunk merge arguments'
        Assert-Contains '--no-squash' $wtCalls 'Worktrunk merge arguments'
        Assert-Contains 'remove --foreground feature' $wtCalls 'Worktrunk merge removal arguments'
        Assert-Contains 'workspace close ws-feature' $herdrCalls 'Herdr merge cleanup'

        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Remove.ps1')
        Assert-Equal 0 $LASTEXITCODE 'Remove.ps1 exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'remove --foreground feature' $wtCalls 'Worktrunk remove arguments'
        Assert-Contains 'workspace close ws-feature' $herdrCalls 'Herdr remove cleanup'

        # Failure paths must preserve the worktree UI and must not advance from a
        # failed merge to removal.
        $env:WORKTRUNK_NONINTERACTIVE = '1'
        $env:WT_MERGE_STATUS = '7'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Merge.ps1')
        Assert-Equal 0 $LASTEXITCODE 'failed Merge.ps1 handled exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        Assert-False ($wtCalls.Contains('remove --foreground')) 'failed merge does not remove'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-False ($herdrCalls.Contains('workspace close')) 'failed merge does not close workspace'

        $env:WT_MERGE_STATUS = '0'
        $env:WT_REMOVE_STATUS = '8'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Remove.ps1')
        Assert-Equal 0 $LASTEXITCODE 'failed Remove.ps1 handled exit status'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-False ($herdrCalls.Contains('workspace close')) 'failed remove does not close workspace'

        $env:WT_REMOVE_STATUS = '0'

        # Legacy tab-mode cleanup closes only descendant panes and never the
        # calling pane or a sibling path with the same text prefix.
        $env:HERDR_LIST_JSON = '{"result":{"worktrees":[]}}'
        $env:HERDR_PANE_LIST_JSON = '{"result":{"panes":[{"pane_id":"p-self","cwd":"' + $checkoutJsonPath + '"},{"pane_id":"p-in","cwd":"' + $checkoutJsonPath + '/src"},{"pane_id":"p-sibling","cwd":"' + $checkoutJsonPath + '-other"}]}}'
        Remove-Item Env:HERDR_PANE_ID -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stubLog -ErrorAction SilentlyContinue
        Close-WorktrunkUi $null $checkout
        Assert-False (Test-Path -LiteralPath $stubLog) 'legacy cleanup skips panes without caller ID'

        $env:HERDR_PANE_ID = 'p-self'
        Remove-Item -LiteralPath $stubLog -ErrorAction SilentlyContinue
        Close-WorktrunkUi $null $checkout
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'pane list --json' $herdrCalls 'legacy pane cleanup query'
        Assert-Contains 'pane close p-in' $herdrCalls 'legacy descendant cleanup'
        Assert-False ($herdrCalls.Contains('pane close p-self')) 'legacy cleanup keeps caller'
        Assert-False ($herdrCalls.Contains('pane close p-sibling')) 'legacy cleanup keeps sibling'

        # Exercise the same legacy pane fallback through the public remove action
        # when Herdr has no workspace ID for the selected worktree.
        $env:FZF_STUB_PICK = 'feature'
        $env:FZF_STUB_STATUS = '0'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Remove.ps1')
        Assert-Equal 0 $LASTEXITCODE 'legacy cleanup Remove.ps1 exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'remove --foreground feature' $wtCalls 'legacy cleanup remove arguments'
        Assert-Contains 'pane list --json' $herdrCalls 'legacy cleanup remove query'
        Assert-Contains 'pane close p-in' $herdrCalls 'legacy cleanup remove descendant'
        Assert-False ($herdrCalls.Contains('pane close p-self')) 'legacy cleanup remove keeps caller'
        Assert-False ($herdrCalls.Contains('pane close p-sibling')) 'legacy cleanup remove keeps sibling'

        $env:FZF_STUB_PICK = ''
        $env:FZF_STUB_STATUS = '130'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default'
        Assert-Equal 0 $LASTEXITCODE 'cancelled Picker.ps1 exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        Assert-False ($wtCalls.Contains('switch ')) 'cancelled picker does not switch worktrees'
    }

    $manifest = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'herdr-plugin.toml'))
    Assert-Contains 'platforms = ["windows"]' $manifest 'manifest'
    Assert-Contains 'min_herdr_version = "0.8.0"' $manifest 'manifest'
    Assert-False ($manifest.Contains('bash')) 'manifest has no Bash commands'

    Write-Host "PowerShell tests passed ($script:Assertions assertions)." -ForegroundColor Green
}
finally {
    $env:PATH = $oldPath
    $env:HERDR_PLUGIN_CONFIG_DIR = $oldConfig
    Remove-Item Env:HERDR_BIN_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:HERDR_PLUGIN_ID -ErrorAction SilentlyContinue
    Remove-Item Env:HERDR_PLUGIN_CONTEXT_JSON -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
