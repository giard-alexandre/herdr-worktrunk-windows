Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-HerdrCommand {
    if ($env:HERDR_BIN_PATH) { return $env:HERDR_BIN_PATH }
    return 'herdr'
}

function Get-WorktrunkCommand {
    $command = Get-Command 'git-wt' -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "git-wt was not found on PATH. Install Worktrunk with 'winget install max-sixty.worktrunk'."
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) { return $command.Source }
    if (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) { return $command.Path }
    return $command.Name
}

function Limit-WorktrunkText {
    param([AllowNull()][string]$Text, [int]$MaximumLength = 16384)

    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $MaximumLength) { return $Text }
    return $Text.Substring(0, $MaximumLength) + "`r`n[truncated]"
}

function Protect-WorktrunkLogText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $value = [regex]::Replace($Text, '(?i)\b(https?://)[^/\s:@]+(?::[^@/\s]*)?@', '$1<redacted>@')
    $value = [regex]::Replace($value, '(?i)\b(authorization\s*:\s*(?:bearer|basic)\s+)\S+', '$1<redacted>')
    return [regex]::Replace($value, `
        '(?i)\b((?:token|password|passwd|secret|api[_-]?key)\s*[=:]\s*)[^\s;]+', '$1<redacted>')
}

function Throw-WorktrunkNativeError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [AllowNull()][string]$Diagnostics
    )

    $diagnosticText = ([string](Limit-WorktrunkText $Diagnostics 4096)).Trim()
    $displayMessage = "$Message (exit code $ExitCode)"
    if (-not [string]::IsNullOrWhiteSpace($diagnosticText)) {
        $displayMessage += ": $diagnosticText"
    }
    $exception = New-Object System.InvalidOperationException($displayMessage)
    $exception.Data['Worktrunk.Stage'] = $Stage
    $exception.Data['Worktrunk.ExitCode'] = $ExitCode
    $exception.Data['Worktrunk.Diagnostics'] = [string]$Diagnostics
    throw $exception
}

function Invoke-WorktrunkNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$FailureMessage = 'Command failed',
        [switch]$Interactive
    )

    if ($Interactive) {
        # Merge/remove hooks and prompts must retain their native terminal. Their
        # output is already visible in the pane, so only add context and status.
        & $FilePath @ArgumentList
        $status = $LASTEXITCODE
        if ($status -ne 0) {
            Throw-WorktrunkNativeError $FailureMessage $Stage $status `
                'Native diagnostics were streamed to the terminal above.'
        }
        return
    }

    # Windows PowerShell 5.1 turns redirected native stderr into ErrorRecords.
    # Capture it separately from stdout under Continue, and trust the process
    # exit code rather than treating successful diagnostic output as failure.
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $savedErrorActionPreference = $ErrorActionPreference
    $output = @()
    $status = $null
    $invocationFailure = $null
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $output = @(& $FilePath @ArgumentList 2> $stderrPath)
        $status = $global:LASTEXITCODE
    }
    catch { $invocationFailure = $_ }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
        $diagnostics = ''
        try { $diagnostics = [System.IO.File]::ReadAllText($stderrPath) }
        catch { }
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $invocationFailure) {
        $startupDiagnostics = [string]$invocationFailure.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($diagnostics)) {
            $startupDiagnostics += [Environment]::NewLine + $diagnostics.Trim()
        }
        Throw-WorktrunkNativeError "$FailureMessage (command could not be started)" $Stage -1 $startupDiagnostics
    }
    if ($null -eq $status) {
        Throw-WorktrunkNativeError "$FailureMessage (command returned no exit status)" $Stage -1 $diagnostics
    }
    if ($status -ne 0) {
        Throw-WorktrunkNativeError $FailureMessage $Stage $status $diagnostics
    }
    return [pscustomobject]@{
        Output = $output
        Diagnostics = $diagnostics
        ExitCode = $status
    }
}

function ConvertFrom-NativeJson {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object[]]$ArgumentList,
        [string]$FailureMessage = 'Command failed',
        [string]$Stage = 'native JSON command'
    )

    $result = Invoke-WorktrunkNativeCommand $FilePath $ArgumentList $Stage $FailureMessage
    $text = $result.Output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        Throw-WorktrunkNativeError "$FailureMessage (command returned no JSON)" $Stage 0 $result.Diagnostics
    }
    try {
        return $text | ConvertFrom-Json
    }
    catch {
        $diagnostics = "JSON parse error: $($_.Exception.Message)"
        if (-not [string]::IsNullOrWhiteSpace($result.Diagnostics)) {
            $diagnostics += [Environment]::NewLine + $result.Diagnostics.Trim()
        }
        Throw-WorktrunkNativeError "$FailureMessage (invalid JSON)" $Stage 0 $diagnostics
    }
}

function Get-WorktrunkErrorLogDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:HERDR_PLUGIN_CONFIG_DIR)) {
        return Join-Path $env:HERDR_PLUGIN_CONFIG_DIR 'error-logs'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { $root = Join-Path $env:APPDATA 'herdr' }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $root = Join-Path $env:USERPROFILE 'AppData\Roaming\herdr' }
    elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $root = Join-Path $env:HOME '.config/herdr' }
    else { $root = Join-Path ([System.IO.Path]::GetTempPath()) 'herdr' }
    return Join-Path $root 'plugins/config/worktrunk.windows/error-logs'
}

function Write-WorktrunkErrorLog {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    try {
        $exception = $ErrorRecord.Exception
        $stage = $Operation
        $exitStatus = 'not available'
        $diagnostics = ''
        if ($null -ne $exception -and $exception.Data.Contains('Worktrunk.Stage')) {
            $stage = [string]$exception.Data['Worktrunk.Stage']
        }
        if ($null -ne $exception -and $exception.Data.Contains('Worktrunk.ExitCode')) {
            $exitStatus = [string]$exception.Data['Worktrunk.ExitCode']
        }
        if ($null -ne $exception -and $exception.Data.Contains('Worktrunk.Diagnostics')) {
            $diagnostics = [string]$exception.Data['Worktrunk.Diagnostics']
        }
        $cwd = '<unavailable>'
        try { $cwd = (Get-Location).Path } catch { }
        $stack = [string]$ErrorRecord.ScriptStackTrace
        $lines = @(
            'Timestamp: ' + [DateTime]::UtcNow.ToString('o'),
            'Operation: ' + $Operation,
            'Stage: ' + $stage,
            'Cwd: ' + $cwd,
            'Native exit status: ' + $exitStatus,
            '',
            'Diagnostics:',
            (Limit-WorktrunkText (Protect-WorktrunkLogText $diagnostics) 16384),
            '',
            'Exception:',
            (Limit-WorktrunkText (Protect-WorktrunkLogText ([string]$exception.Message)) 8192),
            '',
            'Stack trace:',
            (Limit-WorktrunkText $stack 16384)
        )

        $directory = Get-WorktrunkErrorLogDirectory
        [void](New-Item -ItemType Directory -Path $directory -Force)
        $name = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + "-$PID-" + `
            [guid]::NewGuid().ToString('N') + '.log'
        $path = Join-Path $directory $name
        [System.IO.File]::WriteAllText($path, ($lines -join [Environment]::NewLine), `
            (New-Object System.Text.UTF8Encoding($false)))

        # Unique files avoid cross-process append corruption. Best-effort pruning
        # keeps the newest 20 records even when plugin actions overlap.
        $logs = @(Get-ChildItem -LiteralPath $directory -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
        for ($index = 20; $index -lt $logs.Count; $index++) {
            Remove-Item -LiteralPath $logs[$index].FullName -Force -ErrorAction SilentlyContinue
        }
        return $path
    }
    catch {
        # Logging is supplementary and must never replace the original error.
        return $null
    }
}

function Send-WorktrunkFailureNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][string]$LogPath
    )

    try {
        $body = Protect-WorktrunkLogText "$Operation failed: $Message"
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $body += "; Log: $LogPath" }
        $body = Limit-WorktrunkText $body 1024
        $null = Invoke-WorktrunkNativeCommand (Get-HerdrCommand) `
            @('notification', 'show', 'Worktrunk failed', '--body', $body, '--sound', 'none') `
            'Herdr failure notification' 'Failed to show Herdr failure notification'
    }
    catch {
        # Notification errors are intentionally isolated to prevent recursion.
    }
}

function Report-WorktrunkError {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [switch]$Wait,
        [switch]$Notify
    )

    $message = [string]$ErrorRecord.Exception.Message
    $logPath = Write-WorktrunkErrorLog $Operation $ErrorRecord
    Write-Host "$Operation failed: $message" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        Write-Host "Error log: $logPath" -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Error log could not be written.' -ForegroundColor DarkGray
    }
    if ($env:WORKTRUNK_DEBUG -eq '1' -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkGray
    }
    if ($Notify) { Send-WorktrunkFailureNotification $Operation $message $logPath }
    if ($Wait) { Wait-ForKey 'Press any key to close.' }
}

function Get-WorktrunkConfigValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    if ([string]::IsNullOrWhiteSpace($env:HERDR_PLUGIN_CONFIG_DIR)) { return $null }
    $configFile = Join-Path $env:HERDR_PLUGIN_CONFIG_DIR 'config.toml'
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { return $null }

    $escapedKey = [regex]::Escape($Key)
    $pattern = '^\s*' + $escapedKey + '\s*=\s*(?:"([^"]*)"|([^\s#"]+))\s*(?:#.*)?$'
    $value = $null
    foreach ($line in [System.IO.File]::ReadAllLines($configFile)) {
        $match = [regex]::Match($line, $pattern)
        if ($match.Success) {
            if ($match.Groups[1].Success) { $value = $match.Groups[1].Value }
            else { $value = $match.Groups[2].Value }
        }
    }
    return $value
}

function Get-WorktrunkOpenMode {
    $mode = Get-WorktrunkConfigValue 'open_mode'
    switch ($mode) {
        { [string]::IsNullOrWhiteSpace($_) } { return 'workspace' }
        'workspace' { return 'workspace' }
        'tab' { return 'tab' }
        default {
            Write-Warning "Unsupported open_mode '$mode'; using workspace."
            return 'workspace'
        }
    }
}

function Get-WorktrunkPickerPlacement {
    $placement = Get-WorktrunkConfigValue 'picker_placement'
    switch ($placement) {
        { [string]::IsNullOrWhiteSpace($_) } { return 'split' }
        'split' { return 'split' }
        'popup' { return 'popup' }
        default {
            Write-Warning "Unsupported picker_placement '$placement'; using split."
            return 'split'
        }
    }
}

function Get-WorktrunkShowRemoteBranches {
    $value = Get-WorktrunkConfigValue 'show_remote_branches'
    switch ($value) {
        { [string]::IsNullOrWhiteSpace($_) } { return $false }
        'false' { return $false }
        'true' { return $true }
        default {
            Write-Warning "Unsupported show_remote_branches '$value'; hiding remote branches."
            return $false
        }
    }
}

function Get-WorktrunkPopupDimension {
    param([Parameter(Mandatory = $true)][string]$Key)

    $value = Get-WorktrunkConfigValue $Key
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    if ($value -notmatch '^(?:[0-9]+|[0-9]+%)$') {
        Write-Warning "Unsupported $Key '$value'; using Herdr's default popup size."
        return $null
    }
    return $value
}

function Get-WorktrunkMergeFlags {
    $value = Get-WorktrunkConfigValue 'merge_flags'
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }

    $accepted = @('--no-squash', '--no-rebase', '--no-ff', '--no-commit', '--no-hooks',
        '--stage=all', '--stage=tracked', '--stage=none')
    $result = @()
    foreach ($flag in ($value -split '\s+')) {
        if ($accepted -contains $flag) { $result += $flag }
        else { Write-Warning "Unsupported merge_flags entry '$flag'; ignoring it." }
    }
    return $result
}

function Get-WorktrunkFzfArguments {
    if ((Get-WorktrunkPickerPlacement) -eq 'popup') {
        return @('--border=none', '--margin=0')
    }
    return @('--border=rounded', '--margin=20%,30%')
}

function Test-WorktrunkShortcut {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $Name -eq '^' -or $Name -eq '-' -or $Name.Contains(':')
}

function Get-WorktrunkSwitchLabel {
    param([string]$Branch, [Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Branch) -or $Branch -eq $Name) { return $Name }
    return "$Branch ($Name)"
}

function Test-WorktrunkRefExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    & git show-ref --quiet --verify "refs/heads/$Name"
    if ($LASTEXITCODE -eq 0) { return $true }
    & git show-ref --quiet --verify "refs/remotes/$Name"
    return $LASTEXITCODE -eq 0
}

function ConvertTo-WorktrunkItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Json)

    if ($Json -is [string]) { $parsed = $Json | ConvertFrom-Json }
    else { $parsed = $Json }

    # ConvertFrom-Json returns Object[] on Windows PowerShell 5.1 and a generic
    # List[object] for some arrays on newer PowerShell. Build ArrayLists through
    # foreach rather than @($value), which triggers a binder bug for an empty
    # generic list on PowerShell 7.
    $parsedValues = New-Object System.Collections.ArrayList
    if ($null -eq $parsed) { return @() }
    if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
        foreach ($entry in $parsed) {
            if ($null -ne $entry) { [void]$parsedValues.Add($entry) }
        }
    }
    else { [void]$parsedValues.Add($parsed) }

    if ($parsedValues.Count -eq 0) { return @() }
    if ($parsedValues.Count -eq 1 -and $null -ne $parsedValues[0].PSObject.Properties['items']) {
        $rawItems = New-Object System.Collections.ArrayList
        foreach ($entry in $parsedValues[0].PSObject.Properties['items'].Value) {
            [void]$rawItems.Add($entry)
        }
    }
    elseif ($parsedValues.Count -gt 0 -and $null -ne $parsedValues[0].PSObject.Properties['branch']) {
        $rawItems = $parsedValues
    }
    else {
        throw 'Unsupported Worktrunk list JSON schema.'
    }

    $normalized = @()
    foreach ($item in $rawItems) {
        $worktree = Get-ObjectProperty $item 'worktree'
        $kind = Get-ObjectProperty $item 'kind'
        if ([string]::IsNullOrWhiteSpace([string]$kind)) {
            if ($null -ne $worktree) { $kind = 'worktree' } else { $kind = 'branch' }
        }
        $path = Get-ObjectProperty $item 'path'
        if ($null -eq $path -and $null -ne $worktree) { $path = Get-ObjectProperty $worktree 'path' }
        $isMain = Get-ObjectProperty $item 'is_main' $false
        if ($null -ne $worktree -and -not $isMain) {
            $isMain = [bool](Get-ObjectProperty $worktree 'main' $false)
        }
        $normalized += [pscustomobject]@{
            Branch = Get-ObjectProperty $item 'branch'
            Kind = [string]$kind
            Path = $path
            IsMain = [bool]$isMain
        }
    }
    return $normalized
}

function Get-WorktrunkItems {
    $response = ConvertFrom-NativeJson (Get-WorktrunkCommand) @('list', '--format=json') `
        'Failed to list worktrees' 'Worktrunk worktree list'
    return @(ConvertTo-WorktrunkItems $response)
}

function ConvertTo-NormalizedWindowsPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = $Path
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\' + $value.Substring(8)
    }
    elseif ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(4)
    }
    try { $value = [System.IO.Path]::GetFullPath($value) } catch { }

    $root = [System.IO.Path]::GetPathRoot($value)
    if ($value.Length -gt $root.Length) { $value = $value.TrimEnd('\', '/') }
    return $value.Replace('/', '\')
}

function Test-WindowsPathEqual {
    param([string]$Left, [string]$Right)
    $a = ConvertTo-NormalizedWindowsPath $Left
    $b = ConvertTo-NormalizedWindowsPath $Right
    if ($null -eq $a -or $null -eq $b) { return $false }
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-WindowsPathWithin {
    param([string]$Candidate, [string]$Root)
    $candidatePath = ConvertTo-NormalizedWindowsPath $Candidate
    $rootPath = ConvertTo-NormalizedWindowsPath $Root
    if ($null -eq $candidatePath -or $null -eq $rootPath) { return $false }
    if ($candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootPath.TrimEnd('\') + '\'
    return $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-HerdrWorktreeList {
    param([Parameter(Mandatory = $true)][string]$Cwd)
    return ConvertFrom-NativeJson (Get-HerdrCommand) @('worktree', 'list', '--cwd', $Cwd, '--json') `
        'Failed to query Herdr worktrees' 'Herdr worktree list'
}

function Get-OpenWorkspaceId {
    param([Parameter(Mandatory = $true)][string]$WorktreePath)

    $response = Get-HerdrWorktreeList (Get-Location).Path
    foreach ($worktree in @(Get-ObjectProperty (Get-ObjectProperty $response 'result') 'worktrees' @())) {
        if (Test-WindowsPathEqual (Get-ObjectProperty $worktree 'path') $WorktreePath) {
            return Get-ObjectProperty $worktree 'open_workspace_id'
        }
    }
    return $null
}

function Close-WorktrunkUi {
    param([string]$WorkspaceId, [string]$WorktreePath)

    $herdr = Get-HerdrCommand
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $null = Invoke-WorktrunkNativeCommand $herdr @('workspace', 'close', $WorkspaceId) `
            'Herdr workspace cleanup' "Worktree removed, but Herdr workspace close failed. Close workspace '$WorkspaceId' manually."
        return
    }
    if ([string]::IsNullOrWhiteSpace($WorktreePath)) { return }

    $normalized = ConvertTo-NormalizedWindowsPath $WorktreePath
    if ($normalized -match '^[A-Za-z]:\\$' -or $normalized -match '^\\\\[^\\]+\\[^\\]+\\?$') {
        return
    }

    $self = $env:HERDR_PANE_ID
    # Pane-list cleanup is only safe when the invoking pane can be excluded. A
    # popup has no HERDR_PANE_ID and must not guess which matching pane is itself.
    if ([string]::IsNullOrWhiteSpace($self)) { return }

    $response = ConvertFrom-NativeJson $herdr @('pane', 'list', '--json') `
        'Worktree removed, but failed to list Herdr panes for cleanup' 'Herdr pane cleanup list'
    $failedPanes = @()
    foreach ($pane in @(Get-ObjectProperty (Get-ObjectProperty $response 'result') 'panes' @())) {
        $paneId = [string](Get-ObjectProperty $pane 'pane_id')
        $cwd = [string](Get-ObjectProperty $pane 'cwd')
        if ($paneId -ne $self -and (Test-WindowsPathWithin $cwd $normalized)) {
            try {
                $null = Invoke-WorktrunkNativeCommand $herdr @('pane', 'close', $paneId) `
                    'Herdr pane cleanup' "Worktree removed, but failed to close Herdr pane '$paneId'."
            }
            catch { $failedPanes += $_.Exception.Message }
        }
    }
    if ($failedPanes.Count -gt 0) {
        $diagnostics = $failedPanes -join [Environment]::NewLine
        Throw-WorktrunkNativeError 'Worktree removed, but Herdr pane cleanup failed. Close the affected panes manually' `
            'Herdr pane cleanup' 1 $diagnostics
    }
}

function Select-WorktrunkBranch {
    param(
        [Parameter(Mandatory = $true)][string[]]$Candidates,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Header,
        [switch]$AllowQuery
    )

    if ($null -eq (Get-Command 'fzf' -ErrorAction SilentlyContinue)) {
        if ($AllowQuery) { return Read-Host 'Branch' }
        throw "fzf was not found on PATH. Install it with 'winget install junegunn.fzf'."
    }

    $arguments = @()
    if ($AllowQuery) { $arguments += '--print-query' }
    $arguments += @('--reverse', '--info=inline')
    $arguments += Get-WorktrunkFzfArguments
    if ($AllowQuery) { $arguments += '--bind=alt-enter:print-query' }
    $arguments += @("--prompt=$Prompt", "--header=$Header")

    $output = @($Candidates | & fzf @arguments)
    $status = $LASTEXITCODE
    if ($status -eq 130) { return $null }
    if ($status -ne 0 -and -not ($status -eq 1 -and $AllowQuery)) {
        Throw-WorktrunkNativeError 'fzf selection failed' 'fzf branch selection' $status `
            'fzf diagnostics were streamed to the terminal above.'
    }
    if ($output.Count -eq 0) { return $null }
    return [string]$output[$output.Count - 1]
}

function ConvertTo-PowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-NushellLiteral {
    param([AllowEmptyString()][string]$Value)
    if (-not $Value.Contains("'")) { return "'$Value'" }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-PaneShellName {
    param([Parameter(Mandatory = $true)][string]$PaneId)

    $herdr = Get-HerdrCommand
    $lastFailure = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 100 }
        try {
            $response = ConvertFrom-NativeJson $herdr @('pane', 'process-info', '--pane', $PaneId) `
                'Unable to inspect pane process' 'Herdr pane process inspection'
            $info = Get-ObjectProperty (Get-ObjectProperty $response 'result') 'process_info'
            $shellPid = Get-ObjectProperty $info 'shell_pid'
            foreach ($process in @(Get-ObjectProperty $info 'foreground_processes' @())) {
                if ((Get-ObjectProperty $process 'pid') -eq $shellPid) {
                    $name = [string](Get-ObjectProperty $process 'name')
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-ObjectProperty $process 'argv0') }
                    if (-not [string]::IsNullOrWhiteSpace($name)) { return [System.IO.Path]::GetFileName($name).TrimStart('-') }
                }
            }
            if ($null -ne $shellPid) {
                $process = Get-Process -Id ([int]$shellPid) -ErrorAction SilentlyContinue
                if ($null -ne $process) { return $process.ProcessName }
            }
        }
        catch { $lastFailure = $_ }
    }
    if ($null -ne $lastFailure) { throw $lastFailure }
    # Do not guess: sending PowerShell syntax to cmd.exe or another configured
    # shell is worse than declining tab mode with a clear error.
    return $null
}

function Get-TabSwitchCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ShellName,
        [Parameter(Mandatory = $true)][string]$RelabelScript,
        [Parameter(Mandatory = $true)][string]$Herdr,
        [Parameter(Mandatory = $true)][string]$TabId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$StartCwd,
        [Parameter(Mandatory = $true)][string[]]$WorktrunkArguments
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ShellName).ToLowerInvariant()
    if ($baseName -eq 'powershell' -or $baseName -eq 'pwsh') {
        $quoted = @($WorktrunkArguments | ForEach-Object { ConvertTo-PowerShellLiteral $_ })
        $switch = 'git-wt ' + ($quoted -join ' ')
        $relabel = @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            $RelabelScript, $Herdr, $TabId, $Name, $StartCwd) |
            ForEach-Object { ConvertTo-PowerShellLiteral $_ }
        return "$switch; if (`$?) { & $($relabel -join ' ') }"
    }
    if ($baseName -eq 'nu' -or $baseName -eq 'nushell') {
        $quoted = @($WorktrunkArguments | ForEach-Object { ConvertTo-NushellLiteral $_ })
        $switch = 'git-wt ' + ($quoted -join ' ')
        $relabelValues = @($RelabelScript, $Herdr, $TabId, $Name, $StartCwd) |
            ForEach-Object { ConvertTo-NushellLiteral $_ }
        # Wrapping in print propagates integration failures and aborts the chain.
        # Worktrunk v0.60's with-env leaves LAST_EXIT_CODE absent or stale on success.
        return "print -n ($switch); powershell.exe -NoProfile -ExecutionPolicy Bypass -File $($relabelValues -join ' ')"
    }
    throw "Tab mode supports PowerShell and Nushell on Windows; pane shell '$ShellName' is unsupported."
}

function Wait-ForKey {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -NoNewline
    if ($env:WORKTRUNK_NONINTERACTIVE -ne '1' -and -not [Console]::IsInputRedirected) {
        [void][Console]::ReadKey($true)
    }
    Write-Host
}
