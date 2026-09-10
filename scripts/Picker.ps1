param(
    [Parameter(Position = 0)]
    [ValidateSet('default', 'current', 'remotes')]
    [string]$Mode = 'default'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'Worktrunk.Common.ps1')

function Get-CandidateBranches {
    param([bool]$IncludeRemotes)

    $refs = @('refs/heads')
    if ($IncludeRemotes) { $refs += 'refs/remotes' }
    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $lines = @(& git for-each-ref '--format=%(refname) %(refname:short)' @refs 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Failed to list Git branches.' }
    foreach ($line in $lines) {
        $space = $line.IndexOf(' ')
        if ($space -lt 1) { continue }
        $full = $line.Substring(0, $space)
        $short = $line.Substring($space + 1)
        if ($full -match '/HEAD$') { continue }
        if (-not $seen.ContainsKey($short)) {
            $seen[$short] = $true
            $candidates.Add($short)
        }
    }

    foreach ($item in @(Get-WorktrunkItems)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Branch) -and -not $seen.ContainsKey([string]$item.Branch)) {
            $seen[[string]$item.Branch] = $true
            $candidates.Add([string]$item.Branch)
        }
    }
    return $candidates.ToArray()
}

try {
    if ($env:WORKTRUNK_REPO_CWD) {
        Set-Location -LiteralPath $env:WORKTRUNK_REPO_CWD
    }
    if (-not (Test-Path -LiteralPath (Get-Location).Path -PathType Container)) {
        throw 'The repository directory is unavailable.'
    }

    [void](Get-WorktrunkCommand)
    $createBase = $null
    $createBaseLabel = 'default branch'
    if ($Mode -eq 'current') {
        $createBase = '@'
        $currentBranch = (@(& git branch --show-current 2>$null) -join '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($currentBranch)) {
            $createBaseLabel = "current branch ($currentBranch)"
        }
        else {
            $currentCommit = (@(& git rev-parse --short HEAD 2>$null) -join '').Trim()
            if (-not [string]::IsNullOrWhiteSpace($currentCommit)) {
                $createBaseLabel = "current HEAD ($currentCommit)"
            }
            else { $createBaseLabel = 'current branch' }
        }
    }

    $includeRemotes = $Mode -eq 'remotes' -or (Get-WorktrunkShowRemoteBranches)
    $candidates = @(Get-CandidateBranches $includeRemotes)
    $header = "Enter on match: switch; type a new name: create from $createBaseLabel; Alt+Enter: force typed name; Esc: cancel"
    $name = Select-WorktrunkBranch $candidates 'worktree > ' $header -AllowQuery
    if ([string]::IsNullOrWhiteSpace($name)) { exit 0 }

    if ((Test-WorktrunkShortcut $name) -or (Test-WorktrunkRefExists $name)) {
        $worktrunkArguments = @('switch', $name)
    }
    else {
        $worktrunkArguments = @('switch', '--create', $name)
        if ($null -ne $createBase) { $worktrunkArguments += @('--base', $createBase) }
    }

    $herdr = Get-HerdrCommand
    if ((Get-WorktrunkOpenMode) -eq 'tab') {
        if ([string]::IsNullOrWhiteSpace($env:HERDR_WORKSPACE_ID)) {
            throw 'Tab mode requires a Herdr workspace context.'
        }
        $createdTabId = $null
        try {
            $tabResponse = ConvertFrom-NativeJson $herdr @(
                'tab', 'create', '--workspace', $env:HERDR_WORKSPACE_ID,
                '--cwd', (Get-Location).Path, '--label', $name, '--focus'
            ) 'Failed to open worktree tab'
            $tabResult = Get-ObjectProperty $tabResponse 'result'
            $rootPane = Get-ObjectProperty $tabResult 'root_pane'
            $newPane = [string](Get-ObjectProperty $rootPane 'pane_id')
            $tabId = [string](Get-ObjectProperty $rootPane 'tab_id')
            if ([string]::IsNullOrWhiteSpace($tabId)) {
                $tabId = [string](Get-ObjectProperty (Get-ObjectProperty $tabResult 'tab') 'tab_id')
            }
            if (-not [string]::IsNullOrWhiteSpace($tabId)) {
                # Record the tab before validating its root pane so a partial Herdr
                # response cannot leave a newly-created placeholder tab orphaned.
                $createdTabId = $tabId
            }
            if ([string]::IsNullOrWhiteSpace($newPane) -or [string]::IsNullOrWhiteSpace($tabId)) {
                throw 'Herdr returned no pane or tab ID for the new tab.'
            }

            $shellName = Get-PaneShellName $newPane
            if ([string]::IsNullOrWhiteSpace($shellName)) {
                throw 'Could not identify the new tab shell; refusing to send a shell-specific command.'
            }
            $line = Get-TabSwitchCommand $shellName (Join-Path $PSScriptRoot 'TabRelabel.ps1') `
                $herdr $tabId $name (Get-Location).Path $worktrunkArguments
            & $herdr pane run $newPane $line
            if ($LASTEXITCODE -ne 0) { throw 'Failed to send the Worktrunk command to the new tab.' }
            $createdTabId = $null
            exit 0
        }
        catch {
            if (-not [string]::IsNullOrWhiteSpace($createdTabId)) {
                & $herdr tab close $createdTabId *> $null
            }
            throw
        }
    }

    $worktrunk = Get-WorktrunkCommand
    $switchArguments = @($worktrunkArguments + @('--no-cd', '--format=json'))
    $result = ConvertFrom-NativeJson $worktrunk $switchArguments 'Worktrunk switch failed'
    $branch = [string](Get-ObjectProperty $result 'branch')
    $label = Get-WorktrunkSwitchLabel $branch $name
    $worktreePath = [string](Get-ObjectProperty $result 'path')

    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        $resolvedName = $name
        if (-not [string]::IsNullOrWhiteSpace($branch)) { $resolvedName = $branch }
        foreach ($item in @(Get-WorktrunkItems)) {
            if ($item.Kind -eq 'worktree' -and $item.Branch -eq $resolvedName) {
                $worktreePath = [string]$item.Path
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($worktreePath)) {
        throw "Worktrunk returned no worktree path for '$name'."
    }

    $source = Get-HerdrWorktreeList (Get-Location).Path
    $sourceResult = Get-ObjectProperty $source 'result'
    $sourceInfo = Get-ObjectProperty $sourceResult 'source'
    $repoRoot = [string](Get-ObjectProperty $sourceInfo 'repo_root')
    if ([string]::IsNullOrWhiteSpace($repoRoot)) { throw 'Herdr returned no repository root.' }

    $rootWorkspaceId = [string](Get-ObjectProperty $sourceInfo 'source_workspace_id')
    if ([string]::IsNullOrWhiteSpace($rootWorkspaceId)) {
        $repoLabel = [string](Get-ObjectProperty $sourceInfo 'repo_name')
        if ($repoLabel.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
            $repoLabel = $repoLabel.Substring(0, $repoLabel.Length - 4)
        }
        if (-not [string]::IsNullOrWhiteSpace($repoLabel)) {
            & $herdr workspace create --cwd $repoRoot --label $repoLabel --no-focus *> $null
            if ($LASTEXITCODE -ne 0) { throw 'Failed to create the repository workspace.' }
        }
    }

    $openArguments = @('worktree', 'open', '--cwd', $repoRoot, '--path', $worktreePath)
    if (-not (Test-WindowsPathEqual $worktreePath $repoRoot)) {
        $openArguments += @('--label', $label)
    }
    $openArguments += @('--focus', '--json')
    & $herdr @openArguments
    exit $LASTEXITCODE
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($env:WORKTRUNK_DEBUG -eq '1') { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
