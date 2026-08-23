param(
    [switch]$Elevated,
    [switch]$TestModeInstall,
    [string]$DesktopPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$driverPolicyId = '8F9CB695-5D48-48D6-A329-7202B44607E3'
$driverPolicyArgument = '{' + $driverPolicyId + '}'
$script:SecurityTransitionStarted = $false

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $childArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath.Replace('"', '""') + '" -Elevated'
    if ($TestModeInstall) { $childArgs += ' -TestModeInstall' }
    if ($DesktopPath) { $childArgs += ' -DesktopPath "' + $DesktopPath.Replace('"', '""') + '"' }
    $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $childArgs -Wait -PassThru
    exit $child.ExitCode
}

$packageRoot = Split-Path -Parent $PSCommandPath
$installRoot = Join-Path $env:ProgramData 'MX310-Native'
$appRoot = Join-Path $installRoot 'app'
$logRoot = Join-Path $installRoot 'logs'
$driverRoot = Join-Path $installRoot 'driver'
$stagingRoot = Join-Path $installRoot 'installer'
$securityBackupRoot = Join-Path $installRoot 'security-backup'
$policyBackupPath = Join-Path $securityBackupRoot ($driverPolicyArgument + '.cip')
$policyHashPath = Join-Path $securityBackupRoot 'windows-driver-policy.sha256'
$policyLocationPath = Join-Path $securityBackupRoot 'windows-driver-policy.location'
if (-not $DesktopPath) { $DesktopPath = [Environment]::GetFolderPath('Desktop') }
if (-not $DesktopPath) { $DesktopPath = Join-Path $env:USERPROFILE 'Desktop' }
New-Item -ItemType Directory -Force -Path $DesktopPath | Out-Null
$desktop = $DesktopPath
$continueShortcutPath = Join-Path $desktop '2 CONTINUE Canon MX310 install.lnk'
$restoreShortcutPath = Join-Path $desktop 'RESTORE Windows security after MX310.lnk'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logRoot ("install-{0}.log" -f $stamp)
$errorPath = Join-Path $desktop 'MX310-native-install-error.txt'
$transcriptStarted = $false

function Show-MX310Message([string]$Text, [string]$Title, [string]$Buttons, [string]$Icon) {
    Add-Type -AssemblyName System.Windows.Forms
    $buttonValue = [Enum]::Parse([System.Windows.Forms.MessageBoxButtons], $Buttons)
    $iconValue = [Enum]::Parse([System.Windows.Forms.MessageBoxIcon], $Icon)
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $buttonValue, $iconValue)
}

function Get-MX310Device {
    $found = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'USB\VID_04A9&PID_1728&MI_00\*'
    })
    if ($found.Count -eq 0) {
        throw 'Canon MX310 scanner interface MI_00 was not found. Connect and power on the MX310, then run the setup EXE again.'
    }
    if ($found.Count -gt 1) {
        throw ('More than one MX310 MI_00 interface was found: ' + (($found.InstanceId) -join '; '))
    }
    return $found[0]
}

function Get-MX310Service([string]$InstanceId) {
    try {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop
        return [string]$property.Data
    }
    catch {
        return ''
    }
}

function Assert-PackageFile([string]$RelativePath) {
    $full = Join-Path $packageRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw ('The package is incomplete. Missing file: ' + $RelativePath)
    }
    return $full
}

function Find-MX310WinUsbPackage {
    $searchRoots = @(
        (Join-Path $packageRoot 'driver'),
        $driverRoot,
        (Join-Path $env:USERPROFILE 'usb_driver')
    )
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($inf in @(Get-ChildItem -LiteralPath $root -Filter '*.inf' -File -ErrorAction SilentlyContinue)) {
            $text = Get-Content -LiteralPath $inf.FullName -Raw
            $hasExactHardwareId =
                ($text -match '(?i)USB\\VID_04A9&PID_1728&MI_00') -or
                ($text -match '(?im)^\s*DeviceID\s*=\s*"?VID_04A9&PID_1728&MI_00"?\s*$')
            if (-not $hasExactHardwareId) { continue }
            if ($text -notmatch '(?im)^\s*AddService\s*=\s*WinUSB\s*,') { continue }
            if ($text -notmatch '(?im)^\s*ServiceBinary\s*=\s*%12%\\WinUSB\.sys\s*$') { continue }
            if ($text -notmatch '(?im)^\s*%VendorName%\s*=\s*[^\r\n]*NTarm64\s*$') { continue }

            $catalogMatch = [regex]::Match($text, '(?im)^\s*CatalogFile(?:\.[^=\s]+)?\s*=\s*(.+?)\s*$')
            if (-not $catalogMatch.Success) { continue }
            $catalogName = $catalogMatch.Groups[1].Value.Trim().Trim('"')
            $catalogPath = Join-Path $inf.DirectoryName $catalogName
            if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) { continue }

            return [pscustomobject]@{
                Inf = $inf.FullName
                Cat = $catalogPath
            }
        }
    }
    return $null
}

function Add-PublicCertificateToMachineStore(
    [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
    [string]$StoreName
) {
    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    try {
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $alreadyPresent = @($store.Certificates | Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint }).Count -gt 0
        if (-not $alreadyPresent) {
            $publicOnly = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $Certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            )
            $store.Add($publicOnly)
        }
    }
    finally {
        $store.Close()
    }
}

function Trust-MX310WinUsbPackage($DriverPackage) {
    Write-Host ('Validated INF: ' + $DriverPackage.Inf)
    Write-Host ('Validated catalog: ' + $DriverPackage.Cat)

    $signature = Get-AuthenticodeSignature -LiteralPath $DriverPackage.Cat
    $certificate = $signature.SignerCertificate
    if ($null -eq $certificate) {
        throw 'The bundled WinUSB catalog has no signer certificate.'
    }
    if ($certificate.NotAfter -le (Get-Date)) {
        throw ('The bundled WinUSB certificate is expired: ' + $certificate.NotAfter)
    }
    Write-Host ('Catalog signer: ' + $certificate.Subject)
    Write-Host ('Catalog certificate thumbprint: ' + $certificate.Thumbprint)

    Add-PublicCertificateToMachineStore $certificate 'Root'
    Add-PublicCertificateToMachineStore $certificate 'TrustedPublisher'
    $certificate.Thumbprint | Set-Content -LiteralPath (Join-Path $installRoot 'driver-cert-thumbprint.txt') -Encoding ASCII

    Start-Sleep -Seconds 1
    $trustedSignature = Get-AuthenticodeSignature -LiteralPath $DriverPackage.Cat
    Write-Host ('Catalog signature after trust import: ' + $trustedSignature.Status)
    if ($trustedSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw ('The bundled catalog is still not trusted: ' + $trustedSignature.StatusMessage)
    }
    return $certificate
}

function Copy-DriverPackageToProgramData($DriverPackage) {
    New-Item -ItemType Directory -Force -Path $driverRoot | Out-Null
    Copy-Item -LiteralPath $DriverPackage.Inf -Destination (Join-Path $driverRoot ([IO.Path]::GetFileName($DriverPackage.Inf))) -Force
    Copy-Item -LiteralPath $DriverPackage.Cat -Destination (Join-Path $driverRoot ([IO.Path]::GetFileName($DriverPackage.Cat))) -Force
}

function Copy-PackageToStaging {
    $source = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\')
    $destination = [IO.Path]::GetFullPath($stagingRoot).TrimEnd('\')
    if ($source -ieq $destination) { return }

    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    Write-Host ('Copying the installer to persistent staging: ' + $stagingRoot)
    & robocopy.exe $packageRoot $stagingRoot /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -gt 7) {
        throw ('Could not copy the installer to ProgramData. Robocopy exit code: ' + $robocopyExit)
    }
}

function Register-Continuation {
    $stagedScript = Join-Path $stagingRoot 'Install-MX310-Native.ps1'
    if (-not (Test-Path -LiteralPath $stagedScript -PathType Leaf)) {
        throw ('Staged continuation script is missing: ' + $stagedScript)
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $stagedScript + '" -TestModeInstall -DesktopPath "' + $desktop.Replace('"', '""') + '"'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($continueShortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $stagingRoot
    $shortcut.Description = 'Continue Canon MX310 installation after the first normal reboot'
    $shortcut.Save()

    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOncePath -Force | Out-Null
    Set-ItemProperty -Path $runOncePath -Name 'MX310NativeContinue' -Value ('powershell.exe ' + $arguments) -Force
    Write-Host ('Continuation registered: ' + $continueShortcutPath)
}

function Unregister-Continuation {
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    Remove-ItemProperty -Path $runOncePath -Name 'MX310NativeContinue' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $continueShortcutPath) {
        Remove-Item -LiteralPath $continueShortcutPath -Force -ErrorAction SilentlyContinue
    }
}

function Normalize-PolicyId([string]$PolicyId) {
    return $PolicyId.Trim().Trim('{', '}').ToUpperInvariant()
}

function Mount-EfiSystemPartition {
    $letters = [char[]]'ZYXWVUTSRQPONMLKJIHGFED'
    $attempts = New-Object System.Collections.Generic.List[string]
    foreach ($letter in $letters) {
        $mountPoint = ([string]$letter) + ':'
        $root = $mountPoint + '\'
        if (Test-Path -LiteralPath $root) { continue }

        $output = @(& mountvol.exe $mountPoint /S 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Start-Sleep -Milliseconds 250
            if ([IO.Directory]::Exists($root)) {
                Write-Host ('EFI System Partition temporarily mounted at ' + $mountPoint)
                return [pscustomobject]@{
                    MountPoint = $mountPoint
                    Root = $root
                }
            }
            $cleanupOutput = @(& mountvol.exe $mountPoint /D 2>&1)
            throw ('The EFI System Partition mounted at ' + $mountPoint + ' but was not readable. It was immediately dismounted. Mount output: ' + ($output -join ' ') + '; dismount output: ' + ($cleanupOutput -join ' '))
        }
        $attempts.Add($mountPoint + ' exit ' + $exitCode + ': ' + ($output -join ' '))
    }
    throw ('Could not temporarily mount the EFI System Partition. No security settings were changed. Attempts: ' + ($attempts -join ' | '))
}

function Dismount-EfiSystemPartition($Mount) {
    if ($null -eq $Mount) { return }
    $output = @(& mountvol.exe $Mount.MountPoint /D 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('Could not dismount the EFI System Partition from ' + $Mount.MountPoint + '. Exit code ' + $exitCode + ': ' + ($output -join ' '))
    }
    Write-Host ('EFI System Partition dismounted from ' + $Mount.MountPoint)
}

function Get-DriverPolicyRecord([switch]$AllowFailure) {
    $ciTool = Join-Path $env:WINDIR 'System32\CiTool.exe'
    if (-not (Test-Path -LiteralPath $ciTool -PathType Leaf)) {
        if ($AllowFailure) { return $null }
        throw ('CiTool.exe was not found: ' + $ciTool)
    }
    try {
        $rawLines = @(& $ciTool -lp -json 2>&1)
        $ciExit = $LASTEXITCODE
        if ($ciExit -ne 0) {
            throw ('CiTool list-policies failed with exit code ' + $ciExit + ': ' + ($rawLines -join ' '))
        }
        $policyList = ($rawLines -join "`n") | ConvertFrom-Json
        return @($policyList.Policies | Where-Object {
            (Normalize-PolicyId ([string]$_.PolicyID)) -eq $driverPolicyId
        }) | Select-Object -First 1
    }
    catch {
        if ($AllowFailure) {
            Write-Host ('Windows Driver Policy query warning: ' + $_.Exception.Message) -ForegroundColor Yellow
            return $null
        }
        throw
    }
}

function Write-WindowsSecurityState {
    try {
        $secureBoot = Confirm-SecureBootUEFI
        Write-Host ('Secure Boot: ' + $secureBoot + ' (the installer does not change it)')
    }
    catch {
        Write-Host ('Secure Boot state could not be queried: ' + $_.Exception.Message)
    }

    $policy = Get-DriverPolicyRecord -AllowFailure
    if ($null -eq $policy) {
        Write-Host ('Windows Driver Policy ' + $driverPolicyArgument + ': not listed or not readable.')
    }
    else {
        Write-Host ('Windows Driver Policy {0}: IsEnforced={1}; IsAuthorized={2}' -f $policy.PolicyID, $policy.IsEnforced, $policy.IsAuthorized)
    }

    Write-Host 'Boot configuration (TESTSIGNING line, if present):'
    @(& bcdedit.exe /enum 2>&1) | Where-Object { [string]$_ -match '(?i)testsigning' } | ForEach-Object { Write-Host $_ }
}

function Assert-SecureBootOff {
    try {
        $secureBoot = Confirm-SecureBootUEFI
    }
    catch {
        throw ('Secure Boot state could not be verified. No security settings were changed. Details: ' + $_.Exception.Message)
    }
    if ($secureBoot) {
        throw 'Secure Boot is enabled, so Windows will reject TESTSIGNING. This installer will not change UEFI settings. No security settings were changed.'
    }
}

function Backup-WindowsDriverPolicy {
    $policy = Get-DriverPolicyRecord
    if ($null -eq $policy -or -not [bool]$policy.IsEnforced) {
        throw ('The enforced Windows Driver Policy ' + $driverPolicyArgument + ' is not active. No security settings were changed.')
    }

    $windowsPolicyRoot = Join-Path $env:WINDIR 'System32\CodeIntegrity\CiPolicies\Active'
    $candidates = @(Get-ChildItem -LiteralPath $windowsPolicyRoot -Filter '*.cip' -File -ErrorAction Stop | Where-Object {
        (Normalize-PolicyId $_.BaseName) -eq $driverPolicyId
    })

    $efiMount = $null
    $sourcePolicy = $null
    $sourceDescription = $null
    $sourceLocation = $null
    try {
        if ($candidates.Count -eq 1) {
            $sourcePolicy = $candidates[0].FullName
            $sourceDescription = $sourcePolicy
            $sourceLocation = 'windows'
        }
        elseif ($candidates.Count -gt 1) {
            throw ('More than one Windows copy of policy ' + $driverPolicyArgument + ' was found. No security settings were changed.')
        }
        else {
            Write-Host ('Policy ' + $driverPolicyArgument + ' is active and on disk, but not present in the Windows policy directory. Checking the EFI System Partition...') -ForegroundColor Yellow
            $efiMount = Mount-EfiSystemPartition
            $efiPolicyRoot = Join-Path $efiMount.Root 'EFI\Microsoft\Boot\CiPolicies\Active'
            $efiCandidates = @()
            if ([IO.Directory]::Exists($efiPolicyRoot)) {
                $efiCandidates = @(Get-ChildItem -LiteralPath $efiPolicyRoot -Filter '*.cip' -File -ErrorAction Stop | Where-Object {
                    (Normalize-PolicyId $_.BaseName) -eq $driverPolicyId
                })
            }
            if ($efiCandidates.Count -ne 1) {
                throw ('Could not identify exactly one EFI binary for active Windows Driver Policy ' + $driverPolicyArgument + '. Found: ' + $efiCandidates.Count + '. No security settings were changed.')
            }
            $sourcePolicy = $efiCandidates[0].FullName
            $sourceDescription = 'EFI System Partition\EFI\Microsoft\Boot\CiPolicies\Active\' + $efiCandidates[0].Name
            $sourceLocation = 'efi'
        }

        New-Item -ItemType Directory -Force -Path $securityBackupRoot | Out-Null
        Copy-Item -LiteralPath $sourcePolicy -Destination $policyBackupPath -Force
        $sourceHash = (Get-FileHash -LiteralPath $sourcePolicy -Algorithm SHA256).Hash.ToUpperInvariant()
        $backupHash = (Get-FileHash -LiteralPath $policyBackupPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($sourceHash -ne $backupHash) {
            throw 'The Windows Driver Policy backup hash does not match the active policy. No security settings were changed.'
        }
    }
    finally {
        if ($null -ne $efiMount) {
            Dismount-EfiSystemPartition $efiMount
        }
    }

    $backupHash | Set-Content -LiteralPath $policyHashPath -Encoding ASCII
    $sourceLocation | Set-Content -LiteralPath $policyLocationPath -Encoding ASCII
    @(
        'Mx310_Evgenium_scanner Windows security backup',
        ('Created: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Policy ID: ' + $driverPolicyArgument),
        ('Source: ' + $sourceDescription),
        ('Backup: ' + $policyBackupPath),
        ('SHA256: ' + $backupHash)
    ) | Set-Content -LiteralPath (Join-Path $securityBackupRoot 'README.txt') -Encoding UTF8
    Write-Host ('Windows Driver Policy backup verified: ' + $policyBackupPath)
    Write-Host ('Policy SHA256: ' + $backupHash)
}

function Assert-PolicyBackup {
    if (-not (Test-Path -LiteralPath $policyBackupPath -PathType Leaf)) {
        throw ('Windows Driver Policy backup is missing: ' + $policyBackupPath)
    }
    if (-not (Test-Path -LiteralPath $policyHashPath -PathType Leaf)) {
        throw ('Windows Driver Policy backup hash is missing: ' + $policyHashPath)
    }
    if (-not (Test-Path -LiteralPath $policyLocationPath -PathType Leaf)) {
        throw ('Windows Driver Policy location marker is missing: ' + $policyLocationPath)
    }
    $expected = (Get-Content -LiteralPath $policyHashPath -Raw).Trim().ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $policyBackupPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        throw ('Windows Driver Policy backup failed SHA256 verification. Expected ' + $expected + '; actual ' + $actual)
    }
    Write-Host ('Verified security backup SHA256: ' + $actual)
}

function Get-PolicyDeploymentPath([string]$Location, $EfiMount) {
    if ($Location -eq 'windows') {
        return Join-Path $env:WINDIR ('System32\CodeIntegrity\CiPolicies\Active\' + $driverPolicyArgument + '.cip')
    }
    if ($Location -eq 'efi') {
        if ($null -eq $EfiMount) { throw 'The EFI System Partition is not mounted.' }
        return Join-Path $EfiMount.Root ('EFI\Microsoft\Boot\CiPolicies\Active\' + $driverPolicyArgument + '.cip')
    }
    throw ('Unknown Windows Driver Policy location marker: ' + $Location)
}

function Remove-WindowsDriverPolicyFile {
    Assert-PolicyBackup
    $location = (Get-Content -LiteralPath $policyLocationPath -Raw).Trim().ToLowerInvariant()
    $efiMount = $null
    try {
        if ($location -eq 'efi') { $efiMount = Mount-EfiSystemPartition }
        $activePath = Get-PolicyDeploymentPath $location $efiMount
        if (-not (Test-Path -LiteralPath $activePath -PathType Leaf)) {
            throw ('The active Windows Driver Policy file is missing: ' + $activePath)
        }
        $activeHash = (Get-FileHash -LiteralPath $activePath -Algorithm SHA256).Hash.ToUpperInvariant()
        $backupHash = (Get-Content -LiteralPath $policyHashPath -Raw).Trim().ToUpperInvariant()
        if ($activeHash -ne $backupHash) {
            throw ('Refusing to remove the Windows Driver Policy because its SHA256 changed. Active: ' + $activeHash + '; backup: ' + $backupHash)
        }
        Remove-Item -LiteralPath $activePath -Force
        if (Test-Path -LiteralPath $activePath) {
            throw ('Windows Driver Policy file still exists after removal: ' + $activePath)
        }
        Write-Host ('Removed the verified policy file from its deployment location: ' + $activePath)
    }
    finally {
        if ($null -ne $efiMount) { Dismount-EfiSystemPartition $efiMount }
    }
}

function Restore-WindowsDriverPolicyFile {
    Assert-PolicyBackup
    $location = (Get-Content -LiteralPath $policyLocationPath -Raw).Trim().ToLowerInvariant()
    $efiMount = $null
    try {
        if ($location -eq 'efi') { $efiMount = Mount-EfiSystemPartition }
        $activePath = Get-PolicyDeploymentPath $location $efiMount
        $parent = Split-Path -Parent $activePath
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Copy-Item -LiteralPath $policyBackupPath -Destination $activePath -Force
        $activeHash = (Get-FileHash -LiteralPath $activePath -Algorithm SHA256).Hash.ToUpperInvariant()
        $backupHash = (Get-Content -LiteralPath $policyHashPath -Raw).Trim().ToUpperInvariant()
        if ($activeHash -ne $backupHash) {
            throw ('Restored Windows Driver Policy failed SHA256 verification. Active: ' + $activeHash + '; backup: ' + $backupHash)
        }
        Write-Host ('Restored and verified the policy file: ' + $activePath)
    }
    finally {
        if ($null -ne $efiMount) { Dismount-EfiSystemPartition $efiMount }
    }
}

function Install-EmergencyRestore {
    $restoreSource = Assert-PackageFile 'Restore-MX310-Windows-Security.ps1'
    $restoreInstalled = Join-Path $installRoot 'Restore-MX310-Windows-Security.ps1'
    Copy-Item -LiteralPath $restoreSource -Destination $restoreInstalled -Force

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($restoreShortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $restoreInstalled + '"'
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = 'Restore Windows Driver Policy and turn TESTSIGNING off'
    $shortcut.Save()
    Write-Host ('Emergency security restore shortcut: ' + $restoreShortcutPath)
}

function Invoke-CiToolChecked([string[]]$Arguments, [string]$Action) {
    $ciTool = Join-Path $env:WINDIR 'System32\CiTool.exe'
    $output = @(& $ciTool @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    Write-Host ($Action + ' exit code: ' + $exitCode)
    if ($exitCode -ne 0) {
        throw ($Action + ' failed with exit code ' + $exitCode + ': ' + ($output -join ' '))
    }
}

function Set-TestSigning([bool]$Enabled) {
    $value = $(if ($Enabled) { 'on' } else { 'off' })
    $output = @(& bcdedit.exe /set testsigning $value 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    Write-Host ('BCDEdit TESTSIGNING ' + $value + ' exit code: ' + $exitCode)
    if ($exitCode -ne 0) {
        throw ('BCDEdit could not set TESTSIGNING ' + $value + '. Exit code ' + $exitCode + ': ' + ($output -join ' '))
    }
}

function Invoke-WindowsSecurityRestore {
    Write-Host 'Restoring Windows security configuration...' -ForegroundColor Yellow
    Assert-PolicyBackup
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        Restore-WindowsDriverPolicyFile
    }
    catch {
        $errors.Add($_.Exception.Message)
        Write-Host ('Policy restore error: ' + $_.Exception.Message) -ForegroundColor Red
    }

    try {
        Set-TestSigning $false
    }
    catch {
        $errors.Add($_.Exception.Message)
        Write-Host ('TESTSIGNING restore error: ' + $_.Exception.Message) -ForegroundColor Red
    }

    if ($errors.Count -gt 0) {
        throw ('Automatic Windows security restoration was incomplete: ' + ($errors -join ' | ') + '. Run the RESTORE Windows security shortcut as Administrator.')
    }

    @(
        ('Restore commands completed: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Policy source: ' + $policyBackupPath),
        'TESTSIGNING requested: OFF',
        'A normal reboot is required to finish applying both settings.'
    ) | Set-Content -LiteralPath (Join-Path $securityBackupRoot 'restore-command-completed.txt') -Encoding UTF8
    Write-Host 'Windows Driver Policy file was restored and TESTSIGNING was set to OFF.' -ForegroundColor Green
    Write-Host 'A normal reboot is required to reactivate the restored configuration.' -ForegroundColor Yellow
}

function Prepare-TestModeInstall($DriverPackage) {
    Assert-SecureBootOff
    Trust-MX310WinUsbPackage $DriverPackage | Out-Null
    Copy-DriverPackageToProgramData $DriverPackage
    Copy-PackageToStaging
    Backup-WindowsDriverPolicy
    Install-EmergencyRestore

    $warning = @'
Windows 11 ARM64 kept the new Windows Driver Policy active even after option 7/F7.

Mx310_Evgenium_scanner can perform the binding in a controlled two-reboot sequence:

  1. Keep a verified copy of the exact active policy.
  2. Temporarily remove only policy {8F9CB695-5D48-48D6-A329-7202B44607E3}.
  3. Enable Windows TESTSIGNING and restart normally.
  4. Install Microsoft WinUSB only for Canon MX310 scanner interface MI_00.
  5. Restore the saved policy, turn TESTSIGNING off, and restart normally again.

Windows driver protection is reduced between the two reboots. Secure Boot, TPM,
BitLocker, Memory Integrity, and printer interfaces MI_01/MI_02 are not changed.

An emergency RESTORE Windows security shortcut has been created on the Desktop.

Start this sequence now?
'@
    $choice = Show-MX310Message $warning 'Mx310_Evgenium_scanner - temporary Windows security change' 'YesNo' 'Warning'
    if ($choice.ToString() -ne 'Yes') {
        Write-Host 'Cancelled before any Windows security setting was changed.' -ForegroundColor Yellow
        return $false
    }

    Register-Continuation
    Assert-PolicyBackup
    Write-Host ('Temporarily removing Windows Driver Policy ' + $driverPolicyArgument + '...') -ForegroundColor Yellow
    $script:SecurityTransitionStarted = $true
    Remove-WindowsDriverPolicyFile
    Set-TestSigning $true

    @(
        ('Temporary security transition started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Removed policy: ' + $driverPolicyArgument),
        'TESTSIGNING requested: ON',
        ('Continuation: ' + $continueShortcutPath)
    ) | Set-Content -LiteralPath (Join-Path $securityBackupRoot 'temporary-change-started.txt') -Encoding UTF8

    Write-Host 'Restarting normally. Installation will continue after sign-in...' -ForegroundColor Yellow
    Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 0'
    return $true
}

function Assert-TestModeStageReady {
    Assert-PolicyBackup
    $policy = Get-DriverPolicyRecord
    if ($null -ne $policy -and [bool]$policy.IsEnforced) {
        throw ('Windows Driver Policy ' + $driverPolicyArgument + ' is still enforced after the reboot. The driver was not attempted. Security will now be restored.')
    }
    Write-Host ('Verified: Windows Driver Policy ' + $driverPolicyArgument + ' is not enforced for this installation stage.') -ForegroundColor Green
    Write-Host 'Current TESTSIGNING-related BCDEdit output:'
    $testSigningLines = @(@(& bcdedit.exe /enum 2>&1) | Where-Object { [string]$_ -match '(?i)testsigning' })
    if ($testSigningLines.Count -eq 0) {
        Write-Host 'No localized TESTSIGNING line was found; pnputil will provide the authoritative installation result.' -ForegroundColor Yellow
    }
    else {
        $testSigningLines | ForEach-Object { Write-Host $_ }
    }
}

function Install-MX310WinUsbPackage($DriverPackage) {
    $certificate = Trust-MX310WinUsbPackage $DriverPackage
    Copy-DriverPackageToProgramData $DriverPackage

    Write-Host 'Installing the validated WinUSB INF with pnputil...'
    $pnpOutput = @(& pnputil.exe /add-driver $DriverPackage.Inf /install 2>&1)
    $pnpExit = $LASTEXITCODE
    $pnpOutput | ForEach-Object { Write-Host $_ }
    Write-Host ('pnputil exit code: ' + $pnpExit)

    foreach ($personalStore in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        try {
            @(Get-ChildItem -LiteralPath $personalStore -ErrorAction SilentlyContinue | Where-Object {
                $_.Thumbprint -eq $certificate.Thumbprint -and $_.HasPrivateKey
            }) | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host ('Private-key cleanup warning for ' + $personalStore + ': ' + $_.Exception.Message)
        }
    }

    if ($pnpExit -ne 0) {
        if ($pnpExit -eq -536870333) {
            throw 'Windows returned 0xE0000243 even with the enforcement policy removed and TESTSIGNING enabled. The failure is recorded; Windows security will now be restored before exit.'
        }
        throw ('pnputil failed with exit code ' + $pnpExit + '. Windows security will now be restored before exit.')
    }
}

try {
    New-Item -ItemType Directory -Force -Path $installRoot, $appRoot, $logRoot, $driverRoot | Out-Null
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host 'Mx310_Evgenium_scanner 1.0.4 - Windows 11 ARM64 installer'
    Write-Host ('Stage: ' + $(if ($TestModeInstall) { 'temporary test-mode installation' } else { 'prepare/normal install' }))
    Write-Host ('Log: ' + $logPath)
    Write-Host ''

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-Host ('OS: {0}; version {1}; architecture {2}' -f $os.Caption, $os.Version, $os.OSArchitecture)
    Write-Host ('CPU: ' + $cpu.Name)
    if (($os.OSArchitecture -notmatch 'ARM') -and ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64')) {
        throw 'This test package is only for Windows 11 ARM64.'
    }
    Write-WindowsSecurityState

    $vcRedist = Assert-PackageFile 'runtime\vc_redist.arm64.exe'
    Assert-PackageFile 'runtime\arm64\libusb-1.0.dll' | Out-Null
    Assert-PackageFile 'src\LibUsbTransport.cs' | Out-Null
    Assert-PackageFile 'src\PixmaMx310.cs' | Out-Null
    Assert-PackageFile 'src\MX310App.cs' | Out-Null
    Assert-PackageFile 'Restore-MX310-Windows-Security.ps1' | Out-Null

    $device = Get-MX310Device
    Write-Host ('Scanner interface: ' + $device.InstanceId)
    $service = Get-MX310Service $device.InstanceId
    Write-Host ('Current service: ' + $service)

    if ($TestModeInstall) {
        Assert-TestModeStageReady
    }

    if ($service -notmatch '^WinUSB$') {
        $driverPackage = Find-MX310WinUsbPackage
        if ($null -eq $driverPackage) {
            throw 'No validated WinUSB package for 04A9:1728 MI_00 was found. Re-extract this ZIP and try again.'
        }

        if (-not $TestModeInstall) {
            $prepared = Prepare-TestModeInstall $driverPackage
            if ($prepared) { exit 10 }
            exit 11
        }

        Write-Host 'Continuation stage: installing Microsoft WinUSB while the new Windows Driver Policy is temporarily inactive.' -ForegroundColor Yellow
        Install-MX310WinUsbPackage $driverPackage
        Start-Sleep -Seconds 2
        & pnputil.exe /scan-devices | Out-Host
        Start-Sleep -Seconds 2
        $device = Get-MX310Device
        $service = Get-MX310Service $device.InstanceId
    }

    if ($service -notmatch '^WinUSB$') {
        throw ('MI_00 is still not using WinUSB. Current service: "' + $service + '". Windows security will be restored before exit.')
    }
    Write-Host 'Verified: MX310 MI_00 is bound to Microsoft WinUSB.' -ForegroundColor Green

    Write-Host 'Installing/updating the Microsoft Visual C++ ARM64 runtime...'
    $vc = Start-Process -FilePath $vcRedist -ArgumentList '/install /quiet /norestart' -Wait -PassThru
    if ($vc.ExitCode -notin @(0, 1638, 3010)) {
        throw ('VC++ ARM64 runtime installer returned exit code ' + $vc.ExitCode)
    }
    if ($vc.ExitCode -eq 3010) {
        Write-Host 'VC++ runtime requested a normal reboot.'
    }

    $runningApps = @(Get-Process -Name 'MX310Scanner' -ErrorAction SilentlyContinue)
    if ($runningApps.Count -gt 0) {
        Write-Host 'Closing the running MX310 Scanner application before update...'
        $runningApps | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch { } }
        Start-Sleep -Seconds 2
        $stillRunning = @(Get-Process -Name 'MX310Scanner' -ErrorAction SilentlyContinue)
        if ($stillRunning.Count -gt 0) {
            $stillRunning | Stop-Process -Force
            Start-Sleep -Milliseconds 500
        }
    }

    $sourceRoot = Join-Path $appRoot 'src'
    $arm64Root = Join-Path $appRoot 'arm64'
    $x64Root = Join-Path $appRoot 'x64'
    New-Item -ItemType Directory -Force -Path $sourceRoot, $arm64Root, $x64Root | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageRoot 'src\LibUsbTransport.cs') -Destination $sourceRoot -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'src\PixmaMx310.cs') -Destination $sourceRoot -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'src\MX310App.cs') -Destination $sourceRoot -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'runtime\arm64\libusb-1.0.dll') -Destination $arm64Root -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'runtime\x64\libusb-1.0.dll') -Destination $x64Root -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'Collect-MX310-Native-Diagnostics.ps1') -Destination $installRoot -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'Restore-MX310-Windows-Security.ps1') -Destination $installRoot -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'Uninstall-MX310.ps1') -Destination $installRoot -Force

    $compilerCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $compiler) {
        throw '.NET Framework C# compiler csc.exe was not found.'
    }
    Write-Host ('Compiling native-capable AnyCPU scanner app with: ' + $compiler)
    $outputExe = Join-Path $appRoot 'MX310Scanner.exe'
    $sources = @(
        (Join-Path $sourceRoot 'LibUsbTransport.cs'),
        (Join-Path $sourceRoot 'PixmaMx310.cs'),
        (Join-Path $sourceRoot 'MX310App.cs')
    )
    $compileArgs = @(
        '/nologo',
        '/target:winexe',
        '/platform:anycpu',
        '/optimize+',
        '/codepage:65001',
        ('/win32icon:' + (Join-Path $packageRoot 'assets\mx310-teto-printer.ico')),
        ('/out:' + $outputExe),
        '/reference:System.dll',
        '/reference:System.Core.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll'
    ) + $sources
    & $compiler @compileArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputExe)) {
        throw ('C# compilation failed with exit code ' + $LASTEXITCODE)
    }

    $probeLog = Join-Path $logRoot ("probe-{0}.log" -f $stamp)
    Write-Host 'Running native WinUSB protocol probe...'
    $probe = Start-Process -FilePath $outputExe -ArgumentList @('--probe', ('"' + $probeLog + '"')) -Wait -PassThru
    if ($probe.ExitCode -ne 0) {
        throw ('Native MX310 probe failed with exit code ' + $probe.ExitCode + '. See ' + $probeLog)
    }
    Write-Host 'Native protocol probe succeeded.' -ForegroundColor Green

    $shell = New-Object -ComObject WScript.Shell
    $scanShortcut = $shell.CreateShortcut((Join-Path $desktop 'Mx310 Evgenium Scanner.lnk'))
    $scanShortcut.TargetPath = $outputExe
    $scanShortcut.IconLocation = $outputExe + ',0'
    $scanShortcut.WorkingDirectory = $appRoot
    $scanShortcut.Description = 'Canon MX310 native scanner for Windows 11 ARM64'
    $scanShortcut.Save()

    $diagShortcut = $shell.CreateShortcut((Join-Path $desktop 'Canon MX310 Collect diagnostics.lnk'))
    $diagShortcut.TargetPath = 'powershell.exe'
    $diagShortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'Collect-MX310-Native-Diagnostics.ps1') + '"'
    $diagShortcut.WorkingDirectory = $installRoot
    $diagShortcut.Description = 'Collect Canon MX310 native diagnostics'
    $diagShortcut.Save()

    if ($TestModeInstall) {
        Invoke-WindowsSecurityRestore
    }

    Unregister-Continuation
    if (Test-Path -LiteralPath $errorPath) {
        Remove-Item -LiteralPath $errorPath -Force
    }
    Write-Host ''
    Write-Host 'SUCCESS. Native probe passed. Use "Mx310 Evgenium Scanner" on the Desktop.' -ForegroundColor Green

    if ($TestModeInstall) {
        $restartText = @'
The MX310 WinUSB binding and native protocol probe succeeded.

The saved Windows Driver Policy file has been restored and
TESTSIGNING has been set to OFF.

A final NORMAL reboot is required to reactivate standard Windows protection.
The verified policy backup and emergency RESTORE shortcut are being kept.

Restart normally now?
'@
        $restartChoice = Show-MX310Message $restartText 'Canon MX310 installed - final security reboot' 'YesNo' 'Information'
        if ($restartChoice.ToString() -eq 'Yes') {
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 0'
        }
        else {
            Show-MX310Message 'Restart Windows normally as soon as possible. Protection remains reduced until that reboot.' 'Canon MX310 - reboot required' 'OK' 'Warning' | Out-Null
        }
    }
    exit 0
}
catch {
    $details = $_ | Out-String
    $restoreDetails = 'Security restoration was not required in this stage.'
    $mustRestore = $TestModeInstall -or $script:SecurityTransitionStarted

    Write-Host ''
    Write-Host ('INSTALLATION ERROR: ' + $_.Exception.Message) -ForegroundColor Red

    if ($mustRestore) {
        try {
            Invoke-WindowsSecurityRestore
            $restoreDetails = 'Automatic restore commands succeeded. A normal reboot is required.'
            Write-Host $restoreDetails -ForegroundColor Yellow
        }
        catch {
            $restoreDetails = 'AUTOMATIC SECURITY RESTORE ERROR: ' + $_.Exception.Message
            Write-Host $restoreDetails -ForegroundColor Red
        }
        try { Unregister-Continuation } catch { }
    }

    try {
        @(
            'Mx310_Evgenium_scanner installation error',
            ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
            ('Stage: ' + $(if ($TestModeInstall) { 'temporary test-mode installation' } else { 'prepare/normal install' })),
            ('Log: ' + $logPath),
            ('Security restoration: ' + $restoreDetails),
            '',
            $details
        ) | Set-Content -LiteralPath $errorPath -Encoding UTF8
        Write-Host ('Details: ' + $errorPath)
    }
    catch { }

    if ($mustRestore) {
        if ($restoreDetails -like 'Automatic restore commands succeeded*') {
            $errorPrompt = @'
The MX310 installation failed, but the Windows Driver Policy restore command
succeeded and TESTSIGNING was set to OFF.

Restart Windows normally now to finish restoring standard protection.
After restart, run Collect diagnostics.cmd and send the new ZIP.

Restart now?
'@
            $answer = Show-MX310Message $errorPrompt 'Canon MX310 failed - security reboot required' 'YesNo' 'Warning'
            if ($answer.ToString() -eq 'Yes') {
                Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 0'
            }
        }
        else {
            Show-MX310Message ('Automatic security restoration was incomplete. Run "RESTORE Windows security after MX310" on the Desktop as Administrator, then restart normally. Details are in ' + $errorPath) 'Canon MX310 - security restoration required' 'OK' 'Error' | Out-Null
        }
    }
    exit 1
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

