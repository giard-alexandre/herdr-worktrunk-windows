param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Herdr,
    [Parameter(Mandatory = $true, Position = 1)][string]$TabId,
    [Parameter(Mandatory = $true, Position = 2)][string]$Name,
    [Parameter(Mandatory = $true, Position = 3)][string]$StartCwd
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'Worktrunk.Common.ps1')

try {
    $branchResult = Invoke-WorktrunkNativeCommand 'git' @('branch', '--show-current') `
        'Git tab branch lookup' 'Failed to inspect the switched Git branch'
    $branch = ($branchResult.Output -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) { exit 0 }

    $current = (Get-Location).Path
    if ($branch -ne $Name -and (Test-WindowsPathEqual $current $StartCwd) -and
        -not (Test-WorktrunkShortcut $Name) -and
        -not $Name.EndsWith("/$branch", [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "git-wt switch did not move this shell into the worktree. Run 'git-wt config shell install', restart PowerShell, then run 'git-wt switch $Name'."
        $label = $Name
    }
    else {
        $label = Get-WorktrunkSwitchLabel $branch $Name
    }

    $null = Invoke-WorktrunkNativeCommand $Herdr @('tab', 'rename', $TabId, $label) `
        'Herdr tab relabel' 'Failed to rename the Worktrunk tab'
    exit 0
}
catch {
    Report-WorktrunkError 'Worktrunk tab relabel' $_ -Notify
    exit 1
}
