# Optional real Worktrunk v0.60 integration test. No binary or wrapper stubs.
# Supply the exact upstream git-wt.nu and git-wt binary; requires nu and git.
param(
    [Parameter(Mandatory = $true)][string]$WorktrunkBinary,
    [Parameter(Mandatory = $true)][string]$IntegrationScript
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Worktrunk.Common.ps1')
$WorktrunkBinary = (Resolve-Path -LiteralPath $WorktrunkBinary).Path
$IntegrationScript = (Resolve-Path -LiteralPath $IntegrationScript).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('herdr-nu-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory $root | Out-Null
try {
    $repo = Join-Path $root 'repo'
    & git init --quiet --initial-branch=main $repo
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & git -C $repo -c user.email=test@example.com -c user.name=test commit --quiet --allow-empty -m init
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    $config = Join-Path $root 'config.toml'
    [IO.File]::WriteAllText($config, 'worktree-path = "../{{ repo }}.{{ branch }}"', $utf8)
    $count = 0
    foreach ($state in @('absent', 'stale')) {
        foreach ($success in @($true, $false)) {
            $marker = Join-Path $root 'relabel.json'
            Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
            $branch = 'feature-' + $state
            $wtArgs = @('switch', '--create', '--no-hooks', $branch)
            if (-not $success) { $wtArgs = @('switch', '--no-hooks', 'nonexistent-branch') }
            $line = Get-TabSwitchCommand 'nu' 'relabel.ps1' 'herdr' 'tab-1' $branch $repo $wtArgs
            $statusSetup = 'hide-env -i LAST_EXIT_CODE'
            if ($state -eq 'stale') { $statusSetup = '$env.LAST_EXIT_CODE = 73' }
            # Only the terminal relabel executable is replaced: capture invocation
            # and cwd after the real wrapper has processed its cd directive.
            $source = @(
                ('source ' + (ConvertTo-NushellLiteral $IntegrationScript)),
                ('$env.WORKTRUNK_BIN = ' + (ConvertTo-NushellLiteral $WorktrunkBinary)),
                ('$env.WORKTRUNK_CONFIG_PATH = ' + (ConvertTo-NushellLiteral $config)),
                ('cd ' + (ConvertTo-NushellLiteral $repo)),
                ('def --wrapped powershell.exe [...args] { {cwd: $env.PWD, args: $args} | to json | save --force ' + (ConvertTo-NushellLiteral $marker) + ' }'),
                $statusSetup,
                $line
            ) -join "`n"
            $testFile = Join-Path $root 'test.nu'
            [IO.File]::WriteAllText($testFile, $source, $utf8)
            & nu --no-config-file $testFile
            $status = $LASTEXITCODE
            if ($success) {
                if ($status -ne 0 -or -not (Test-Path -LiteralPath $marker)) { throw "Nushell success did not relabel ($state, exit $status)" }
                $capture = [IO.File]::ReadAllText($marker) | ConvertFrom-Json
                $expected = Join-Path $root ('repo.' + $branch)
                if (-not (Test-WindowsPathEqual $capture.cwd $expected)) { throw "Wrapper did not cd: $($capture.cwd)" }
                if (($capture.args -join '|') -ne "-NoProfile|-ExecutionPolicy|Bypass|-File|relabel.ps1|herdr|tab-1|$branch|$repo") { throw 'Wrong relabel argv' }
            }
            else {
                if ($status -eq 0) { throw "Nushell failure was swallowed ($state)" }
                if (Test-Path -LiteralPath $marker) { throw "Nushell failure relabeled ($state)" }
            }
            $count++
        }
    }
    Write-Host "Real Nushell integration passed ($count cases: absent/stale status, success/failure)."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
