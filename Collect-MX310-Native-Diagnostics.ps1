param([switch]$Elevated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath.Replace('"', '""') + '" -Elevated'
    $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $child.ExitCode
}

$desktop = [Environment]::GetFolderPath('Desktop')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $env:TEMP ("MX310-native-diagnostics-{0}" -f $stamp)
$zip = Join-Path $desktop ("MX310-native-diagnostics-{0}.zip" -f $stamp)
$installRoot = Join-Path $env:ProgramData 'MX310-Native'
$appExe = Join-Path $installRoot 'app\MX310Scanner.exe'

try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $report = Join-Path $work 'report.txt'
    "Mx310_Evgenium_scanner 1.0.4 diagnostics $stamp" | Set-Content -LiteralPath $report -Encoding UTF8

    "`r`n===== System =====" | Add-Content -LiteralPath $report
    Get-CimInstance Win32_OperatingSystem | Format-List Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime | Out-String | Add-Content -LiteralPath $report
    Get-CimInstance Win32_Processor | Format-List Name,Architecture | Out-String | Add-Content -LiteralPath $report
    [pscustomobject]@{
        ProcessArchitecture = $env:PROCESSOR_ARCHITECTURE
        ProcessorArchiteW6432 = $env:PROCESSOR_ARCHITEW6432
        PointerBits = [IntPtr]::Size * 8
        PowerShell = $PSVersionTable.PSVersion.ToString()
    } | Format-List | Out-String | Add-Content -LiteralPath $report

    "`r`n===== Windows security and boot state =====" | Add-Content -LiteralPath $report
    try {
        "SecureBoot: $(Confirm-SecureBootUEFI)" | Add-Content -LiteralPath $report
    }
    catch {
        "SecureBoot query error: $($_.Exception.Message)" | Add-Content -LiteralPath $report
    }
    & bcdedit.exe /enum 2>&1 |
        Set-Content -LiteralPath (Join-Path $work 'bcdedit-all.txt') -Encoding UTF8
    $ciTool = Join-Path $env:WINDIR 'System32\CiTool.exe'
    if (Test-Path -LiteralPath $ciTool) {
        & $ciTool -lp -json 2>&1 |
            Set-Content -LiteralPath (Join-Path $work 'citool-policies.json.txt') -Encoding UTF8
    }
    Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue |
        Format-List * | Out-String -Width 400 | Add-Content -LiteralPath $report

    "`r`n===== Windows Driver Policy files and MX310 security backup =====" | Add-Content -LiteralPath $report
    $activePolicyRoot = Join-Path $env:WINDIR 'System32\CodeIntegrity\CiPolicies\Active'
    if (Test-Path -LiteralPath $activePolicyRoot) {
        Get-ChildItem -LiteralPath $activePolicyRoot -Filter '*.cip' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName.Trim('{', '}') -in @('8F9CB695-5D48-48D6-A329-7202B44607E3', '784C4414-79F4-4C32-A6A5-F0FB42A51D0D') } |
            ForEach-Object {
                [pscustomobject]@{
                    Path = $_.FullName
                    Length = $_.Length
                    LastWriteTime = $_.LastWriteTime
                    SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                }
            } | Format-List | Out-String -Width 400 | Add-Content -LiteralPath $report
    }

    "`r`n--- EFI System Partition policy files ---" | Add-Content -LiteralPath $report
    $efiMountPoint = $null
    try {
        foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
            $candidateMount = ([string]$letter) + ':'
            $candidateRoot = $candidateMount + '\'
            if (Test-Path -LiteralPath $candidateRoot) { continue }
            $mountOutput = @(& mountvol.exe $candidateMount /S 2>&1)
            if ($LASTEXITCODE -eq 0) {
                Start-Sleep -Milliseconds 250
                if ([IO.Directory]::Exists($candidateRoot)) {
                    $efiMountPoint = $candidateMount
                    $efiRoot = $candidateRoot
                    break
                }
                $cleanupOutput = @(& mountvol.exe $candidateMount /D 2>&1)
                throw ('EFI mounted but was not readable; immediate dismount output: ' + ($cleanupOutput -join ' '))
            }
        }
        if ($null -eq $efiMountPoint) {
            'Could not temporarily mount the EFI System Partition.' | Add-Content -LiteralPath $report
        }
        else {
            $efiPolicyRoot = Join-Path $efiRoot 'EFI\Microsoft\Boot\CiPolicies\Active'
            ('Temporary mount point: ' + $efiMountPoint) | Add-Content -LiteralPath $report
            ('Policy directory: ' + $efiPolicyRoot) | Add-Content -LiteralPath $report
            if ([IO.Directory]::Exists($efiPolicyRoot)) {
                Get-ChildItem -LiteralPath $efiPolicyRoot -Filter '*.cip' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName.Trim('{', '}') -in @('8F9CB695-5D48-48D6-A329-7202B44607E3', '784C4414-79F4-4C32-A6A5-F0FB42A51D0D') } |
                    ForEach-Object {
                        [pscustomobject]@{
                            EfiPath = 'EFI\Microsoft\Boot\CiPolicies\Active\' + $_.Name
                            Length = $_.Length
                            LastWriteTime = $_.LastWriteTime
                            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                        }
                    } | Format-List | Out-String -Width 400 | Add-Content -LiteralPath $report
            }
        }
    }
    catch {
        ('EFI policy inventory error: ' + $_.Exception.Message) | Add-Content -LiteralPath $report
    }
    finally {
        if ($null -ne $efiMountPoint) {
            $dismountOutput = @(& mountvol.exe $efiMountPoint /D 2>&1)
            ('EFI dismount exit code: ' + $LASTEXITCODE + '; output: ' + ($dismountOutput -join ' ')) | Add-Content -LiteralPath $report
        }
    }

    $securityBackupRoot = Join-Path $installRoot 'security-backup'
    if (Test-Path -LiteralPath $securityBackupRoot) {
        Get-ChildItem -LiteralPath $securityBackupRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ne '.cip' } |
            ForEach-Object {
                "`r`n--- $($_.Name) ---" | Add-Content -LiteralPath $report
                Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue | Add-Content -LiteralPath $report
            }
        Get-ChildItem -LiteralPath $securityBackupRoot -Filter '*.cip' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    BackupPath = $_.FullName
                    Length = $_.Length
                    SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                }
            } | Format-List | Out-String -Width 400 | Add-Content -LiteralPath $report
    }

    "`r`n===== MX310 MI_00 device =====" | Add-Content -LiteralPath $report
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'USB\VID_04A9&PID_1728&MI_00\*'
    })
    $devices | Format-List * | Out-String -Width 300 | Add-Content -LiteralPath $report
    foreach ($device in $devices) {
        "`r`nProperties for $($device.InstanceId)" | Add-Content -LiteralPath $report
        Get-PnpDeviceProperty -InstanceId $device.InstanceId -ErrorAction SilentlyContinue |
            Sort-Object KeyName | Format-Table KeyName,Type,Data -AutoSize | Out-String -Width 400 |
            Add-Content -LiteralPath $report
        $safeName = ($device.InstanceId -replace '[^A-Za-z0-9_.-]', '_')
        & pnputil.exe /enum-devices /instanceid $device.InstanceId /drivers 2>&1 |
            Set-Content -LiteralPath (Join-Path $work ("pnputil-{0}.txt" -f $safeName)) -Encoding UTF8
    }

    "`r`n===== Signed PnP drivers =====" | Add-Content -LiteralPath $report
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object {
        $_.DeviceID -like 'USB\VID_04A9&PID_1728*'
    } | Format-List * | Out-String -Width 400 | Add-Content -LiteralPath $report

    "`r`n===== bundled driver certificate =====" | Add-Content -LiteralPath $report
    $thumbprintFile = Join-Path $installRoot 'driver-cert-thumbprint.txt'
    if (Test-Path -LiteralPath $thumbprintFile) {
        $thumbprint = (Get-Content -LiteralPath $thumbprintFile -Raw).Trim()
        "Recorded thumbprint: $thumbprint" | Add-Content -LiteralPath $report
        foreach ($storePath in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPublisher', 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
            Get-ChildItem -LiteralPath $storePath -ErrorAction SilentlyContinue | Where-Object {
                $_.Thumbprint -eq $thumbprint
            } | Select-Object @{Name='Store';Expression={$storePath}},Subject,Issuer,Thumbprint,NotBefore,NotAfter,HasPrivateKey |
                Format-List | Out-String | Add-Content -LiteralPath $report
        }
    }
    else {
        'No recorded catalog certificate thumbprint.' | Add-Content -LiteralPath $report
    }

    if (Test-Path -LiteralPath $appExe) {
        $probeLog = Join-Path $work 'native-probe.log'
        $probe = Start-Process -FilePath $appExe -ArgumentList @('--probe', ('"' + $probeLog + '"')) -Wait -PassThru
        "`r`nNative probe exit code: $($probe.ExitCode)" | Add-Content -LiteralPath $report
    }
    else {
        "`r`nNative app not found: $appExe" | Add-Content -LiteralPath $report
    }

    if (Test-Path -LiteralPath (Join-Path $installRoot 'logs')) {
        Copy-Item -LiteralPath (Join-Path $installRoot 'logs') -Destination (Join-Path $work 'installed-logs') -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $installRoot 'driver')) {
        Copy-Item -LiteralPath (Join-Path $installRoot 'driver') -Destination (Join-Path $work 'programdata-driver-package') -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $installRoot 'installer\driver')) {
        Copy-Item -LiteralPath (Join-Path $installRoot 'installer\driver') -Destination (Join-Path $work 'staged-driver-package') -Recurse -Force
    }
    $userDriver = Join-Path $env:USERPROFILE 'usb_driver'
    if (Test-Path -LiteralPath $userDriver) {
        Copy-Item -LiteralPath $userDriver -Destination (Join-Path $work 'user-driver-package') -Recurse -Force
    }
    $localLogs = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MX310-Native\logs'
    if (Test-Path -LiteralPath $localLogs) {
        Copy-Item -LiteralPath $localLogs -Destination (Join-Path $work 'scan-logs') -Recurse -Force
    }
    $desktopError = Join-Path $desktop 'MX310-native-install-error.txt'
    if (Test-Path -LiteralPath $desktopError) {
        Copy-Item -LiteralPath $desktopError -Destination $work -Force
    }

    $setupApi = Join-Path $env:WINDIR 'INF\setupapi.dev.log'
    if (Test-Path -LiteralPath $setupApi) {
        Select-String -LiteralPath $setupApi -Pattern 'VID_04A9&PID_1728','MX310','WinUSB','zadig','libwdi' -Context 8,16 |
            ForEach-Object { $_.ToString() } |
            Set-Content -LiteralPath (Join-Path $work 'setupapi-mx310-winusb.txt') -Encoding UTF8
    }

    try {
        Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 300 -ErrorAction Stop |
            Where-Object {
                $_.Message -match '04A9|1728|MX310|WinUSB|libwdi|8F9CB695|784C4414' -or
                $_.Id -in @(3004, 3033, 3076, 3077, 3089)
            } | Select-Object TimeCreated,Id,LevelDisplayName,Message |
            Format-List | Out-String -Width 500 |
            Set-Content -LiteralPath (Join-Path $work 'codeintegrity-events.txt') -Encoding UTF8
    }
    catch {
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $work 'codeintegrity-events-error.txt') -Encoding UTF8
    }

    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Host ('Diagnostics created: ' + $zip) -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ('Diagnostics error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

