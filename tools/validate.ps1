[CmdletBinding()]
param(
    [string]$Plugin
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Find-Python {
    if ($env:MELANGE_PYTHON -and (Test-Path $env:MELANGE_PYTHON)) {
        return $env:MELANGE_PYTHON
    }
    $portable = Join-Path $repoRoot "..\WUMFix\tools\python\python.exe"
    if (Test-Path $portable) {
        return (Resolve-Path $portable).Path
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) { return "py" }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { return "python" }
    throw "No Python found. Set MELANGE_PYTHON, or install Python, or check out WUMFix next to this repo."
}

$python = Find-Python
Write-Host "Using Python: $python"

$testScript = Join-Path $repoRoot "tools\tests\test_store.py"
if ($python -eq "py") {
    & py -3 $testScript -v
} else {
    & $python $testScript -v
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$storeArgs = @(Join-Path $repoRoot "tools\store.py"), "validate"
if ($Plugin) { $storeArgs += $Plugin } else { $storeArgs += "--all" }
if ($python -eq "py") {
    & py -3 @storeArgs
} else {
    & $python @storeArgs
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$indexArgs = @(Join-Path $repoRoot "tools\store.py"), "index", "--check"
if ($python -eq "py") {
    & py -3 @indexArgs
} else {
    & $python @indexArgs
}
exit $LASTEXITCODE
