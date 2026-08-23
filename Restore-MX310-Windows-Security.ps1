param([switch]$Elevated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$driverPolicyId = '8F9CB695-5D48-48D6-A329-7202B44607E3'
$driverPolicyArgument = '{' + $driverPolicyId + '}'
$installRoot = Join-Path $env:ProgramData 'MX310-Native'
$backupRoot = Join-Path $installRoot 'security-backup'
$policyBackupPath = Join-Path $backupRoot ($driverPolicyArgument + '.cip')
$policyHashPath = Join-Path $backupRoot 'windows-driver-policy.sha256'
$policyLocationPath = Join-Path $backupRoot 'windows-driver-policy.location'
$desktop = [Environment]::GetFolderPath('Desktop')
$errorPath = Join-Path $desktop 'MX310-security-restore-error.txt'
$logRoot = Join-Path $installRoot 'logs'
$logPath = Join-Path $logRoot ('security-restore-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$transcriptStarted = $false

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

function Show-RestoreMessage([string]$Text, [string]$Title, [string]$Buttons, [string]$Icon) {
    Add-Type -AssemblyName System.Windows.Forms
    $buttonValue = [Enum]::Parse([System.Windows.Forms.MessageBoxButtons], $Buttons)
    $iconValue = [Enum]::Parse([System.Windows.Forms.MessageBoxIcon], $Icon)
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $buttonValue, $iconValue)
}

function Normalize-PolicyId([string]$PolicyId) {
    return $PolicyId.Trim().Trim('{', '}').ToUpperInvariant()
}

function Mount-EfiSystemPartition {
    $letters = [char[]]'ZYXWVUTSRQPONMLKJIHGFED'
    foreach ($letter in $letters) {
        $mountPoint = ([string]$letter) + ':'
        $root = $mountPoint + '\'
        if (Test-Path -LiteralPath $root) { continue }
        $output = @(& mountvol.exe $mountPoint /S 2>&1)
        if ($LASTEXITCODE -eq 0 -and [IO.Directory]::Exists($root)) {
            return [pscustomobject]@{ MountPoint = $mountPoint; Root = $root }
        }
    }
    throw 'Could not temporarily mount the EFI System Partition.'
}

function Dismount-EfiSystemPartition($Mount) {
    if ($null -eq $Mount) { return }
    $output = @(& mountvol.exe $Mount.MountPoint /D 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('Could not dismount the EFI System Partition from ' + $Mount.MountPoint + ': ' + ($output -join ' '))
    }
}

function Restore-WindowsDriverPolicyFile {
    $location = (Get-Content -LiteralPath $policyLocationPath -Raw).Trim().ToLowerInvariant()
    $efiMount = $null
    try {
        if ($location -eq 'efi') {
            $efiMount = Mount-EfiSystemPartition
            $activePath = Join-Path $efiMount.Root ('EFI\Microsoft\Boot\CiPolicies\Active\' + $driverPolicyArgument + '.cip')
        }
        elseif ($location -eq 'windows') {
            $activePath = Join-Path $env:WINDIR ('System32\CodeIntegrity\CiPolicies\Active\' + $driverPolicyArgument + '.cip')
        }
        else {
            throw ('Unknown Windows Driver Policy location marker: ' + $location)
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $activePath) | Out-Null
        Copy-Item -LiteralPath $policyBackupPath -Destination $activePath -Force
        $restoredHash = (Get-FileHash -LiteralPath $activePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($restoredHash -ne $actual) {
            throw ('Restored policy failed SHA256 verification. Restored: ' + $restoredHash + '; backup: ' + $actual)
        }
        Write-Host ('Restored and verified Windows Driver Policy: ' + $activePath)
    }
    finally {
        if ($null -ne $efiMount) { Dismount-EfiSystemPartition $efiMount }
    }
}

function Get-DriverPolicyRecord {
    $ciTool = Join-Path $env:WINDIR 'System32\CiTool.exe'
    $rawLines = @(& $ciTool -lp -json 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('CiTool list-policies failed with exit code ' + $exitCode + ': ' + ($rawLines -join ' '))
    }
    $policyList = ($rawLines -join "`n") | ConvertFrom-Json
    return @($policyList.Policies | Where-Object {
        (Normalize-PolicyId ([string]$_.PolicyID)) -eq $driverPolicyId
    }) | Select-Object -First 1
}

function Invoke-CiToolChecked([string[]]$Arguments, [string]$Action) {
    $ciTool = Join-Path $env:WINDIR 'System32\CiTool.exe'
    if (-not (Test-Path -LiteralPath $ciTool -PathType Leaf)) {
        throw ('CiTool.exe was not found: ' + $ciTool)
    }
    $output = @(& $ciTool @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    Write-Host ($Action + ' exit code: ' + $exitCode)
    if ($exitCode -ne 0) {
        throw ($Action + ' failed with exit code ' + $exitCode + ': ' + ($output -join ' '))
    }
}

function Set-TestSigningOff {
    $output = @(& bcdedit.exe /set testsigning off 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    Write-Host ('BCDEdit TESTSIGNING off exit code: ' + $exitCode)
    if ($exitCode -ne 0) {
        throw ('BCDEdit could not set TESTSIGNING off. Exit code ' + $exitCode + ': ' + ($output -join ' '))
    }
}

try {
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
    Write-Host 'Mx310_Evgenium_scanner - Windows security restoration'
    Write-Host ('Log: ' + $logPath)

    if (-not (Test-Path -LiteralPath $policyBackupPath -PathType Leaf)) {
        throw ('The saved Windows Driver Policy binary is missing: ' + $policyBackupPath)
    }
    if (-not (Test-Path -LiteralPath $policyHashPath -PathType Leaf)) {
        throw ('The saved Windows Driver Policy hash is missing: ' + $policyHashPath)
    }
    if (-not (Test-Path -LiteralPath $policyLocationPath -PathType Leaf)) {
        throw ('The saved Windows Driver Policy location marker is missing: ' + $policyLocationPath)
    }
    $expected = (Get-Content -LiteralPath $policyHashPath -Raw).Trim().ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $policyBackupPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        throw ('The policy backup failed SHA256 verification. Expected ' + $expected + '; actual ' + $actual)
    }
    Write-Host ('Verified policy backup SHA256: ' + $actual)

    $errors = New-Object System.Collections.Generic.List[string]
    try {
        Restore-WindowsDriverPolicyFile
    }
    catch {
        $errors.Add($_.Exception.Message)
        Write-Host ('Policy restore error: ' + $_.Exception.Message) -ForegroundColor Red
    }

    try {
        Set-TestSigningOff
    }
    catch {
        $errors.Add($_.Exception.Message)
        Write-Host ('TESTSIGNING restore error: ' + $_.Exception.Message) -ForegroundColor Red
    }

    if ($errors.Count -gt 0) {
        throw ('Windows security restoration was incomplete: ' + ($errors -join ' | '))
    }

    @(
        ('Manual restore commands completed: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Policy source: ' + $policyBackupPath),
        ('SHA256: ' + $actual),
        'TESTSIGNING requested: OFF',
        'A normal reboot is required.'
    ) | Set-Content -LiteralPath (Join-Path $backupRoot 'manual-restore-command-completed.txt') -Encoding UTF8

    if (Test-Path -LiteralPath $errorPath) {
        Remove-Item -LiteralPath $errorPath -Force
    }
    $choice = Show-RestoreMessage 'The saved Windows Driver Policy file was restored and TESTSIGNING was set to OFF. Restart Windows normally now to finish restoring protection?' 'Canon MX310 - Windows security restored' 'YesNo' 'Information'
    if ($choice.ToString() -eq 'Yes') {
        Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 0'
    }
    exit 0
}
catch {
    $details = $_ | Out-String
    @(
        'Mx310_Evgenium_scanner Windows security restore error',
        ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Log: ' + $logPath),
        '',
        $details
    ) | Set-Content -LiteralPath $errorPath -Encoding UTF8
    Write-Host ('SECURITY RESTORE ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Show-RestoreMessage ('Windows security restoration was incomplete. Details: ' + $errorPath) 'Canon MX310 - restore failed' 'OK' 'Error' | Out-Null
    exit 1
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

