param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('picker-default', 'picker-current', 'picker-with-remotes', 'remover', 'merger', 'merger-no-squash')]
    [string]$Entrypoint
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Worktrunk.Common.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($env:HERDR_PLUGIN_CONTEXT_JSON)) {
        throw 'HERDR_PLUGIN_CONTEXT_JSON is missing.'
    }
    $context = $env:HERDR_PLUGIN_CONTEXT_JSON | ConvertFrom-Json
    $cwd = [string](Get-ObjectProperty $context 'workspace_cwd')
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $cwd = [string](Get-ObjectProperty $context 'focused_pane_cwd')
    }
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        throw 'The action context contains no workspace or focused-pane directory.'
    }

    $arguments = @(
        'plugin', 'pane', 'open',
        '--plugin', $(if ($env:HERDR_PLUGIN_ID) { $env:HERDR_PLUGIN_ID } else { 'worktrunk.windows' }),
        '--entrypoint', $Entrypoint,
        '--env', "WORKTRUNK_REPO_CWD=$cwd",
        '--focus'
    )

    if ((Get-WorktrunkPickerPlacement) -eq 'popup') {
        $arguments += @('--placement', 'popup')
        $width = Get-WorktrunkPopupDimension 'popup_width'
        $height = Get-WorktrunkPopupDimension 'popup_height'
        if ($null -ne $width) { $arguments += @('--width', $width) }
        if ($null -ne $height) { $arguments += @('--height', $height) }
        if ($env:HERDR_WORKSPACE_ID) {
            $arguments += @('--env', "HERDR_WORKSPACE_ID=$($env:HERDR_WORKSPACE_ID)")
        }
    }
    else {
        $arguments += @('--placement', 'split', '--direction', 'down')
    }

    $null = Invoke-WorktrunkNativeCommand (Get-HerdrCommand) $arguments `
        'Herdr plugin pane launch' 'Failed to open the Worktrunk pane'
    exit 0
}
catch {
    Report-WorktrunkError 'Worktrunk launcher' $_ -Notify
    exit 1
}
