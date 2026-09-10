param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Herdr,
    [Parameter(Mandatory = $true, Position = 1)][string]$TabId,
    [Parameter(Mandatory = $true, Position = 2)][string]$Name,
    [Parameter(Mandatory = $true, Position = 3)][string]$StartCwd
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Worktrunk.Common.ps1')

try {
    $branch = (@(& git branch --show-current 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) { exit 0 }

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

    & $Herdr tab rename $TabId $label *> $null
    exit $LASTEXITCODE
}
catch {
    Write-Warning $_.Exception.Message
    exit 0
}
