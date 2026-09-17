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
    # Native stderr is diagnostic output, not failure: Windows PowerShell 5.1
    # otherwise throws NativeCommandError before the caller can check the status.
    if ($IsNativeWindows) {
        $nativeJsonFile = Join-Path $tempRoot 'native-json.cmd'
        @'
@echo off
echo Native diagnostic text 1>&2
if "%2"=="json" echo {"branch":"created"}
if "%2"=="invalid" echo not-json
exit /b %1
'@ | Set-Content -LiteralPath $nativeJsonFile -Encoding ASCII
        $nativeJsonCommand = $env:ComSpec
        $nativeJsonArguments = @('/c', $nativeJsonFile)
    }
    else {
        $nativeJsonFile = Join-Path $tempRoot 'native-json.sh'
        @'
printf 'Native diagnostic text\n' >&2
if [ "$2" = json ]; then printf '%s\n' '{"branch":"created"}'; fi
if [ "$2" = invalid ]; then printf '%s\n' 'not-json'; fi
exit "$1"
'@ | Set-Content -LiteralPath $nativeJsonFile -Encoding ASCII
        $nativeJsonCommand = '/bin/sh'
        $nativeJsonArguments = @($nativeJsonFile)
    }
    $nativeResult = ConvertFrom-NativeJson $nativeJsonCommand ($nativeJsonArguments + @('0', 'json'))
    Assert-Equal 'created' $nativeResult.branch 'JSON from successful command with stderr'

    $nativeFailure = $null
    $nativeFailureRecord = $null
    try {
        $null = ConvertFrom-NativeJson $nativeJsonCommand ($nativeJsonArguments + @('7', 'json')) `
            'Native test failed' 'native test stage'
    }
    catch {
        $nativeFailure = $_.Exception.Message
        $nativeFailureRecord = $_
    }
    Assert-Contains 'Native test failed (exit code 7)' $nativeFailure 'native nonzero status'
    Assert-Contains 'Native diagnostic text' $nativeFailure 'native nonzero diagnostic'

    $emptyFailure = $null
    try {
        $null = ConvertFrom-NativeJson $nativeJsonCommand ($nativeJsonArguments + @('0', 'empty'))
    }
    catch { $emptyFailure = $_.Exception.Message }
    Assert-Contains 'command returned no JSON' $emptyFailure 'empty native JSON diagnostic'

    $invalidFailure = $null
    try {
        $null = ConvertFrom-NativeJson $nativeJsonCommand ($nativeJsonArguments + @('0', 'invalid'))
    }
    catch { $invalidFailure = $_.Exception.Message }
    Assert-Contains 'invalid JSON' $invalidFailure 'malformed native JSON diagnostic'
    Assert-Contains 'JSON parse error' $invalidFailure 'malformed native JSON parser detail'

    $missingFailure = $null
    try {
        $null = Invoke-WorktrunkNativeCommand (Join-Path $tempRoot 'missing-native-command') @('arg') `
            'missing command test' 'Missing command failed'
    }
    catch { $missingFailure = $_.Exception.Message }
    Assert-Contains 'command could not be started' $missingFailure 'missing native command diagnostic'
    Assert-Contains 'exit code -1' $missingFailure 'missing native command synthetic status'

    $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
    $firstLog = Write-WorktrunkErrorLog 'Native test operation' $nativeFailureRecord
    Assert-True (Test-Path -LiteralPath $firstLog -PathType Leaf) 'error log persisted'
    $firstLogText = [System.IO.File]::ReadAllText($firstLog)
    Assert-Contains 'Operation: Native test operation' $firstLogText 'error log operation'
    Assert-Contains 'Stage: native test stage' $firstLogText 'error log stage'
    Assert-Contains 'Native exit status: 7' $firstLogText 'error log native status'
    Assert-Contains 'Native diagnostic text' $firstLogText 'error log diagnostics'
    Assert-Contains 'Stack trace:' $firstLogText 'error log stack trace field'
    $redacted = Protect-WorktrunkLogText 'https://user:password@example.test token=abc123 Authorization: Bearer secret-value'
    Assert-False ($redacted.Contains('password@example')) 'URL credentials are redacted from logs'
    Assert-False ($redacted.Contains('abc123')) 'token values are redacted from logs'
    Assert-False ($redacted.Contains('secret-value')) 'authorization values are redacted from logs'

    foreach ($index in 1..24) {
        $null = Write-WorktrunkErrorLog "Bounded log $index" $nativeFailureRecord
    }
    $retainedLogs = @(Get-ChildItem -LiteralPath (Get-WorktrunkErrorLogDirectory) -Filter '*.log')
    Assert-True ($retainedLogs.Count -le 20) 'error log count is bounded'

    $blockedLogRoot = Join-Path $tempRoot 'not-a-directory'
    'file' | Set-Content -LiteralPath $blockedLogRoot -Encoding ASCII
    $env:HERDR_PLUGIN_CONFIG_DIR = $blockedLogRoot
    $isolatedLogResult = Write-WorktrunkErrorLog 'Logging isolation' $nativeFailureRecord
    Assert-Equal $null $isolatedLogResult 'logging failure is isolated'
    $env:HERDR_PLUGIN_CONFIG_DIR = $configDir

    $savedNoninteractive = $env:WORKTRUNK_NONINTERACTIVE
    $env:WORKTRUNK_NONINTERACTIVE = '1'
    $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Wait-ForKey 'Noninteractive wait test.'
    $waitTimer.Stop()
    Assert-True ($waitTimer.Elapsed.TotalSeconds -lt 1) 'noninteractive wait does not hang'
    $env:WORKTRUNK_NONINTERACTIVE = $savedNoninteractive

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
    Assert-False ($nuLine.Contains('LAST_EXIT_CODE')) 'Nushell does not consult stale status'
    Assert-Contains '); powershell.exe' $nuLine 'Nushell failure-propagating chain'
    Assert-Contains 'powershell.exe -NoProfile' $nuLine 'Nushell relabel command'

    # Portable behavior checks complement (not replace) native .cmd coverage.
    & {
        function fzf {
            process { }
            end { $global:LASTEXITCODE = $script:FzfStatus; 'query' }
        }
        foreach ($status in @(0, 1, 130, 2, 127)) {
            $script:FzfStatus = $status
            $threw = $false
            $selection = $null
            try { $selection = Select-WorktrunkBranch @('main') 'test' 'test' -AllowQuery }
            catch { $threw = $true }
            if ($status -eq 130) { Assert-Equal $null $selection 'fzf cancellation ignores output' }
            elseif ($status -le 1) { Assert-Equal 'query' $selection "fzf query at status $status" }
            else { Assert-True $threw "fzf status $status throws" }
        }
        $script:FzfStatus = 1
        $threw = $false
        try { Select-WorktrunkBranch @('main') 'test' 'test' } catch { $threw = $true }
        Assert-True $threw 'no-match without query is not cancellation'

        # Path containment itself is covered with Windows paths below; isolate
        # exit handling here from the host platform's GetFullPath semantics.
        function Test-WindowsPathWithin { param($Candidate, $Root) return $true }
        function Test-HerdrCleanup {
            if ($args[0] -eq 'workspace') { $global:LASTEXITCODE = 9; return }
            if ($args[1] -eq 'list') {
                $global:LASTEXITCODE = $script:ListStatus
                '{"result":{"panes":[{"pane_id":"other","cwd":"/tmp/worktree/src"}]}}'
                return
            }
            $global:LASTEXITCODE = 8
        }
        $savedHerdr = $env:HERDR_BIN_PATH
        $savedPane = $env:HERDR_PANE_ID
        try {
            $env:HERDR_BIN_PATH = 'Test-HerdrCleanup'
            $env:HERDR_PANE_ID = 'self'
            foreach ($kind in @('workspace', 'list', 'pane')) {
                $script:ListStatus = 0
                if ($kind -eq 'list') { $script:ListStatus = 7 }
                $workspace = $null
                if ($kind -eq 'workspace') { $workspace = 'ws' }
                $message = ''
                try { Close-WorktrunkUi $workspace '/tmp/worktree' } catch { $message = $_.Exception.Message }
                Assert-Contains 'Worktree removed, but' $message "$kind partial-success error"
                Assert-Contains 'exit code' $message "$kind exit code reported"
            }
        } finally {
            $env:HERDR_BIN_PATH = $savedHerdr
            $env:HERDR_PANE_ID = $savedPane
        }
    }

    if ($IsNativeWindows) {
        # Verify Open.ps1 builds an argv-based split request and forwards the repository
        # through an environment override while remaining independent of the pane cwd.
        $stubLog = Join-Path $tempRoot 'herdr.log'
        $herdrStub = Join-Path $stubDir 'herdr.cmd'
        @"
@echo off
echo %*>>"$stubLog"
if "%1 %2"=="notification show" exit /b %HERDR_NOTIFICATION_STATUS%
if not "%HERDR_OPEN_STATUS%"=="0" echo pane launch exploded 1>&2
exit /b %HERDR_OPEN_STATUS%
"@ | Set-Content -LiteralPath $herdrStub -Encoding ASCII
        $env:HERDR_BIN_PATH = $herdrStub
        $env:HERDR_PLUGIN_ID = 'worktrunk.windows'
        $env:HERDR_PLUGIN_CONFIG_DIR = $configDir
        $env:HERDR_PLUGIN_CONTEXT_JSON = '{"workspace_cwd":"C:\\Projects\\Repo Here","focused_pane_cwd":"C:\\Other"}'
        $env:HERDR_OPEN_STATUS = '0'
        $env:HERDR_NOTIFICATION_STATUS = '0'
        'picker_placement = "split"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII

        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Open.ps1') 'picker-default'
        Assert-Equal 0 $LASTEXITCODE 'Open.ps1 exit status'
        $openLog = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'plugin pane open' $openLog 'Herdr open arguments'
        Assert-Contains '--entrypoint picker-default' $openLog 'Herdr open arguments'
        Assert-Contains '--env "WORKTRUNK_REPO_CWD=C:\Projects\Repo Here"' $openLog 'Herdr open arguments'
        Assert-Contains '--placement split --direction down' $openLog 'Herdr open arguments'

        # Launcher failures have no visible picker pane. Preserve their native
        # diagnostic and status, persist a log, and notify without allowing a
        # notification failure to replace the launch failure.
        $env:HERDR_OPEN_STATUS = '9'
        $env:HERDR_NOTIFICATION_STATUS = '11'
        Remove-Item -LiteralPath $stubLog -ErrorAction SilentlyContinue
        $openFailure = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Open.ps1') 'picker-default') -join "`n"
        Assert-Equal 1 $LASTEXITCODE 'failed Open.ps1 status'
        Assert-Contains 'exit code 9' $openFailure 'launcher native status'
        Assert-Contains 'pane launch exploded' $openFailure 'launcher native diagnostic'
        Assert-Contains 'Error log:' $openFailure 'launcher log location display'
        $openFailureCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'notification show' $openFailureCalls 'launcher failure notification attempt'
        $env:HERDR_OPEN_STATUS = '0'
        $env:HERDR_NOTIFICATION_STATUS = '0'

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
if "%1"=="switch" echo Created worktree 1>&2
if "%1"=="merge" if not "%WT_MERGE_STATUS%"=="0" echo merge exploded 1>&2
if "%1"=="merge" exit /b %WT_MERGE_STATUS%
if "%1"=="remove" if not "%WT_REMOVE_STATUS%"=="0" echo remove exploded 1>&2
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
if "%1 %2"=="pane run" if not "%HERDR_PANE_RUN_STATUS%"=="0" echo pane run exploded 1>&2
if "%1 %2"=="pane run" exit /b %HERDR_PANE_RUN_STATUS%
if "%1 %2"=="tab close" if not "%HERDR_TAB_CLOSE_STATUS%"=="0" echo tab close exploded 1>&2
if "%1 %2"=="tab close" exit /b %HERDR_TAB_CLOSE_STATUS%
if "%1 %2"=="workspace close" if not "%HERDR_CLOSE_STATUS%"=="0" echo close exploded 1>&2
if "%1 %2"=="workspace close" exit /b %HERDR_CLOSE_STATUS%
if "%1 %2"=="pane close" if not "%HERDR_CLOSE_STATUS%"=="0" echo close exploded 1>&2
if "%1 %2"=="pane close" exit /b %HERDR_CLOSE_STATUS%
if "%1 %2"=="pane list" if not "%HERDR_PANE_LIST_STATUS%"=="0" echo pane list exploded 1>&2
if "%1 %2"=="pane list" exit /b %HERDR_PANE_LIST_STATUS%
if "%1 %2"=="tab rename" if not "%HERDR_RENAME_STATUS%"=="0" echo rename exploded 1>&2
if "%1 %2"=="tab rename" exit /b %HERDR_RENAME_STATUS%
if "%1 %2"=="notification show" exit /b %HERDR_NOTIFICATION_STATUS%
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
        $env:HERDR_TAB_CLOSE_STATUS = '0'
        $env:HERDR_CLOSE_STATUS = '0'
        $env:HERDR_PANE_LIST_STATUS = '0'
        $env:HERDR_RENAME_STATUS = '0'
        $env:HERDR_NOTIFICATION_STATUS = '0'
        $env:WORKTRUNK_NONINTERACTIVE = '1'
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

        $env:WT_SWITCH_JSON = 'not-json'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        $invalidPicker = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default') -join "`n"
        Assert-Equal 1 $LASTEXITCODE 'invalid picker JSON status'
        Assert-Contains 'invalid JSON' $invalidPicker 'invalid picker JSON diagnostic'
        Assert-Contains 'Error log:' $invalidPicker 'invalid picker JSON log location'
        Assert-Contains 'Press any key to close.' $invalidPicker 'invalid picker acknowledgement prompt'
        $env:WT_SWITCH_JSON = '{"branch":"feature/new","path":"' + $checkoutJsonPath + '"}'

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
        $env:HERDR_TAB_CLOSE_STATUS = '12'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        $paneRunFailure = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default') -join "`n"
        Assert-Equal 1 $LASTEXITCODE 'failed pane run exit status'
        Assert-Contains 'pane run exploded' $paneRunFailure 'primary tab setup diagnostic preserved'
        Assert-False ($paneRunFailure.Contains('tab close exploded')) 'cleanup failure does not replace primary error'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-Contains 'pane run w1V:p5' $herdrCalls 'failed pane-run attempt'
        Assert-Contains 'tab close w1V:t3' $herdrCalls 'failed pane-run tab cleanup'

        $env:HERDR_PANE_RUN_STATUS = '0'
        $env:HERDR_TAB_CLOSE_STATUS = '0'
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

        'merge_flags = "--no-hooks --no-rebase"' | Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding ASCII
        Remove-Item -LiteralPath $wtLog -ErrorAction SilentlyContinue
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\Merge.ps1')
        Assert-Equal 0 $LASTEXITCODE 'no-hooks merge status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        Assert-Contains 'remove --foreground feature --no-hooks' $wtCalls 'no-hooks forwarded to removal'
        Assert-False ($wtCalls.Contains('remove --foreground feature --no-hooks --no-rebase')) 'merge-only flags not forwarded'

        $env:HERDR_CLOSE_STATUS = '9'
        $failure = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\Remove.ps1')) -join "`n"
        Assert-Equal 1 $LASTEXITCODE 'workspace cleanup failure status'
        Assert-Contains 'Worktree removed, but' $failure 'partial-success diagnostic'
        Assert-Contains 'exit code 9' $failure 'workspace native error'
        $env:HERDR_CLOSE_STATUS = '0'

        # Failure paths must preserve the worktree UI and must not advance from a
        # failed merge to removal.
        $env:WORKTRUNK_NONINTERACTIVE = '1'
        $env:WT_MERGE_STATUS = '7'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        $savedTestErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $mergeFailure = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
                (Join-Path $RepoRoot 'scripts\Merge.ps1') 2>&1) -join "`n"
            $mergeExitStatus = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedTestErrorPreference }
        Assert-Equal 1 $mergeExitStatus 'failed Merge.ps1 status'
        Assert-Contains 'Worktrunk merge failed (exit code 7)' $mergeFailure 'merge failure context and status'
        Assert-Contains 'merge exploded' $mergeFailure 'streamed merge diagnostic remains visible'
        Assert-Contains 'Error log:' $mergeFailure 'merge failure log location'
        Assert-Contains 'Press any key to close.' $mergeFailure 'merge failure acknowledgement prompt'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        Assert-False ($wtCalls.Contains('remove --foreground')) 'failed merge does not remove'
        $herdrCalls = [System.IO.File]::ReadAllText($stubLog)
        Assert-False ($herdrCalls.Contains('workspace close')) 'failed merge does not close workspace'

        $env:WT_MERGE_STATUS = '0'
        $env:WT_REMOVE_STATUS = '8'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        $savedTestErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $removeFailure = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
                (Join-Path $RepoRoot 'scripts\Remove.ps1') 2>&1) -join "`n"
            $removeExitStatus = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedTestErrorPreference }
        Assert-Equal 1 $removeExitStatus 'failed Remove.ps1 status'
        Assert-Contains 'Worktrunk remove failed (exit code 8)' $removeFailure 'remove failure context and status'
        Assert-Contains 'remove exploded' $removeFailure 'streamed remove diagnostic remains visible'
        Assert-Contains 'Press any key to close.' $removeFailure 'remove failure acknowledgement prompt'
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

        foreach ($failureKind in @('close', 'list', 'json')) {
            $savedPaneJson = $env:HERDR_PANE_LIST_JSON
            if ($failureKind -eq 'close') { $env:HERDR_CLOSE_STATUS = '9' }
            if ($failureKind -eq 'list') { $env:HERDR_PANE_LIST_STATUS = '8' }
            if ($failureKind -eq 'json') { $env:HERDR_PANE_LIST_JSON = 'invalid' }
            $failure = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\Remove.ps1')) -join "`n"
            Assert-Equal 1 $LASTEXITCODE "pane $failureKind cleanup failure status"
            Assert-Contains 'Worktree removed, but' $failure "pane $failureKind partial-success diagnostic"
            $env:HERDR_CLOSE_STATUS = '0'
            $env:HERDR_PANE_LIST_STATUS = '0'
            $env:HERDR_PANE_LIST_JSON = $savedPaneJson
        }

        foreach ($status in @('2', '127')) {
            $env:FZF_STUB_STATUS = $status
            Remove-Item -LiteralPath $wtLog -ErrorAction SilentlyContinue
            $failure = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default') -join "`n"
            Assert-Equal 1 $LASTEXITCODE 'fzf native failure status'
            Assert-Contains "fzf selection failed (exit code $status)" $failure 'fzf diagnostic'
            Assert-False ([System.IO.File]::ReadAllText($wtLog).Contains('switch ')) 'failed fzf does not switch'
        }
        $env:FZF_STUB_STATUS = '1'
        $env:FZF_STUB_PICK = 'new-query'
        Assert-Equal 'new-query' (Select-WorktrunkBranch @('main') 'test' 'test' -AllowQuery) 'fzf no-match query'
        $threw = $false
        try { Select-WorktrunkBranch @('main') 'test' 'test' } catch { $threw = $true }
        Assert-True $threw 'fzf no-match without query throws'

        # Git emits UTF-8 branch names; relabel must decode and forward them intact.
        $unicodeBranch = 'feature-' + [char]0x00e9 + [char]0x65e5
        & git -C $repo branch $unicodeBranch
        & git -C $repo checkout --quiet $unicodeBranch
        Remove-Item -LiteralPath $stubLog -ErrorAction SilentlyContinue
        Push-Location $repo
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\TabRelabel.ps1') $herdrStub 't-unicode' '^' $repo
            Assert-Equal 0 $LASTEXITCODE 'unicode relabel status'
        } finally { Pop-Location }
        Assert-Contains "tab rename t-unicode `"$unicodeBranch (^)`"" ([System.IO.File]::ReadAllText($stubLog)) 'unicode relabel argv'

        $env:HERDR_RENAME_STATUS = '12'
        $env:HERDR_NOTIFICATION_STATUS = '13'
        Remove-Item -LiteralPath $stubLog -ErrorAction SilentlyContinue
        Push-Location $repo
        try {
            $relabelFailure = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
                (Join-Path $RepoRoot 'scripts\TabRelabel.ps1') $herdrStub 't-fail' '^' $repo) -join "`n"
            Assert-Equal 1 $LASTEXITCODE 'failed tab relabel status'
        } finally { Pop-Location }
        Assert-Contains 'rename exploded' $relabelFailure 'tab relabel native diagnostic'
        Assert-Contains 'Error log:' $relabelFailure 'tab relabel log location'
        Assert-Contains 'notification show' ([System.IO.File]::ReadAllText($stubLog)) 'tab relabel notification attempt'
        $env:HERDR_RENAME_STATUS = '0'
        $env:HERDR_NOTIFICATION_STATUS = '0'

        $env:FZF_STUB_PICK = ''
        $env:FZF_STUB_STATUS = '130'
        Remove-Item -LiteralPath $wtLog, $stubLog -ErrorAction SilentlyContinue
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $RepoRoot 'scripts\Picker.ps1') 'default'
        Assert-Equal 0 $LASTEXITCODE 'cancelled Picker.ps1 exit status'
        $wtCalls = [System.IO.File]::ReadAllText($wtLog)
        Assert-False ($wtCalls.Contains('switch ')) 'cancelled picker does not switch worktrees'
    }

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
