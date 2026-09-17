param(
    [switch]$NoSquash
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'Worktrunk.Common.ps1')

try {
    if ($env:WORKTRUNK_REPO_CWD) { Set-Location -LiteralPath $env:WORKTRUNK_REPO_CWD }
    [void](Get-WorktrunkCommand)

    $mergeFlags = @(Get-WorktrunkMergeFlags)
    if ($NoSquash -and -not ($mergeFlags -contains '--no-squash')) {
        $mergeFlags += '--no-squash'
    }

    $items = @(Get-WorktrunkItems)
    $candidates = @($items | Where-Object {
        $_.Kind -eq 'worktree' -and -not [string]::IsNullOrWhiteSpace([string]$_.Branch) -and -not $_.IsMain
    } | ForEach-Object { [string]$_.Branch })
    if ($candidates.Count -eq 0) {
        Write-Host 'No mergeable worktrees (only the main worktree exists).' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        exit 0
    }

    $flagsLabel = $mergeFlags -join ' '
    if ($flagsLabel) { $flagsLabel = ' ' + $flagsLabel }
    $name = Select-WorktrunkBranch $candidates 'merge worktree > ' `
        "Enter: run git-wt merge$flagsLabel and remove the worktree; Esc: cancel"
    if ([string]::IsNullOrWhiteSpace($name)) { exit 0 }

    $selected = $items | Where-Object { $_.Kind -eq 'worktree' -and $_.Branch -eq $name } | Select-Object -First 1
    if ($null -eq $selected -or [string]::IsNullOrWhiteSpace([string]$selected.Path)) {
        throw "Could not resolve the worktree path for '$name'."
    }
    $worktreePath = [string]$selected.Path
    $workspaceId = Get-OpenWorkspaceId $worktreePath
    $worktrunk = Get-WorktrunkCommand

    $arguments = @('merge', '--no-remove', '-C', $worktreePath) + $mergeFlags
    Invoke-WorktrunkNativeCommand $worktrunk $arguments 'Worktrunk merge' `
        'Worktrunk merge failed' -Interactive

    $removeArguments = @('remove', '--foreground', $name)
    if ($mergeFlags -contains '--no-hooks') { $removeArguments += '--no-hooks' }
    Invoke-WorktrunkNativeCommand $worktrunk $removeArguments 'Worktrunk post-merge removal' `
        'Merged, but Worktrunk remove failed' -Interactive

    Close-WorktrunkUi $workspaceId $worktreePath
    exit 0
}
catch {
    Report-WorktrunkError 'Worktree merge' $_ -Wait
    exit 1
}
