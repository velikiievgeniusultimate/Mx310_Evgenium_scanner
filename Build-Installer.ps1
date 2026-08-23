Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSCommandPath
$build = Join-Path $root 'build'
$dist = Join-Path $root 'dist'
$buildId = Get-Date -Format 'yyyyMMddHHmmssfff'
$payload = Join-Path $build ('payload-' + $buildId)
$zip = Join-Path $build ('payload-' + $buildId + '.zip')

New-Item -ItemType Directory -Force -Path $payload, $dist | Out-Null

foreach ($name in @('assets','driver','licenses','runtime','src')) {
    Copy-Item (Join-Path $root $name) $payload -Recurse
}
foreach ($name in @('Install-MX310-Native.ps1','Restore-MX310-Windows-Security.ps1','Collect-MX310-Native-Diagnostics.ps1','Uninstall-MX310.ps1','Verify-MX310-Removal.ps1','THIRD_PARTY_NOTICES.txt','LICENSE','README.md','VERSION.txt')) {
    Copy-Item (Join-Path $root $name) $payload
}

Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal

$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) { throw 'C# compiler was not found.' }

$output = Join-Path $dist 'Mx310_Evgenium_scanner_Setup_ARM64.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ `
    "/out:$output" "/resource:$zip,payload.zip" `
    ("/win32icon:" + (Join-Path $root 'assets\mx310-teto-printer.ico')) `
    /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    (Join-Path $root 'installer\Bootstrapper.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $output)) { throw 'Installer compilation failed.' }

$debugUninstaller = Join-Path $dist 'Mx310_Evgenium_scanner_Debug_Uninstall.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ `
    "/out:$debugUninstaller" `
    ("/win32icon:" + (Join-Path $root 'assets\mx310-teto-printer.ico')) `
    ("/resource:" + (Join-Path $root 'Uninstall-MX310.ps1') + ',Uninstall-MX310.ps1') `
    ("/resource:" + (Join-Path $root 'Verify-MX310-Removal.ps1') + ',Verify-MX310-Removal.ps1') `
    /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll `
    (Join-Path $root 'installer\DebugUninstaller.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $debugUninstaller)) { throw 'Debug uninstaller compilation failed.' }

$hash = (Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant()
$uninstallHash = (Get-FileHash $debugUninstaller -Algorithm SHA256).Hash.ToLowerInvariant()
@(
    ($hash + '  ' + [IO.Path]::GetFileName($output)),
    ($uninstallHash + '  ' + [IO.Path]::GetFileName($debugUninstaller))
) | Set-Content (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII
Write-Host ('Built: ' + $output)
Write-Host ('SHA256: ' + $hash)
Write-Host ('Debug uninstaller: ' + $debugUninstaller)
Write-Host ('SHA256: ' + $uninstallHash)
