$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$zig = if ($env:ZIG) { $env:ZIG } else { 'zig' }
$out = if ($env:TEAK_HEAVY_OUT) { $env:TEAK_HEAVY_OUT } else { Join-Path ([System.IO.Path]::GetTempPath()) ('teak-live-' + [guid]::NewGuid().ToString()) }
New-Item -ItemType Directory -Force -Path $out | Out-Null
$driver = Join-Path $out 'driver.exe'
& $zig build-exe -lc --dep teak "-Mroot=$root/tools/win32_live/driver.zig" "-Mteak=$root/src/teak.zig" "-femit-bin=$driver"
if ($LASTEXITCODE -ne 0) { throw 'Win32 driver build failed' }
$env:TEAK_GPU_FALLBACK = '1'
foreach ($example in @('chrome', 'effects')) {
    Push-Location (Join-Path $root "examples/$example")
    try {
        & $zig build ui-install -j4
        if ($LASTEXITCODE -ne 0) { throw "$example UI build failed" }
        $previousPath = $env:PATH
        $env:PATH = "$(Join-Path $PWD 'zig-out/bin');$previousPath"
        try {
            & $driver (Join-Path $PWD "zig-out/bin/$example-ui.exe") (Join-Path $out $example) $example
            if ($LASTEXITCODE -ne 0) { throw "$example live driver failed" }
        } finally { $env:PATH = $previousPath }
    } finally { Pop-Location }
}
Push-Location (Join-Path $root 'examples/sysmon')
try {
    & $zig build run -j4
    if ($LASTEXITCODE -ne 0) { throw 'sysmon sampler canary failed' }
    & $zig build shot -j4 -- (Join-Path $out 'sysmon-live.png') --live
    if ($LASTEXITCODE -ne 0) { throw 'sysmon live shot failed' }
    & $zig build shot -j4 -- (Join-Path $out 'sysmon-processes.png') --live --page processes
    if ($LASTEXITCODE -ne 0) { throw 'sysmon process shot failed' }
} finally { Pop-Location }
Write-Host "Win32 artifacts: $out"
