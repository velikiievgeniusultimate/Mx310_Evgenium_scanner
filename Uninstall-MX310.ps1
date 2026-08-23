param([switch]$Elevated, [string]$ReportPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$devicePattern = 'USB\VID_04A9&PID_1728&MI_00\*'
$installRoot = Join-Path $env:ProgramData 'MX310-Native'
$restoreScript = Join-Path $installRoot 'Restore-MX310-Windows-Security.ps1'
$thumbprintFile = Join-Path $installRoot 'driver-cert-thumbprint.txt'
$policyId = '8F9CB695-5D48-48D6-A329-7202B44607E3'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Administrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath.Replace('"','""') + '" -Elevated'
    if ($ReportPath) { $arguments += ' -ReportPath "' + $ReportPath.Replace('"','""') + '"' }
    $child = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $child.ExitCode
}

Add-Type -AssemblyName System.Windows.Forms
$answer = [Windows.Forms.MessageBox]::Show("Remove Mx310 Evgenium Scanner completely for a clean installation test?`r`n`r`nPrinter and fax interfaces MI_01/MI_02 will not be changed.",'Mx310_Evgenium_scanner - debug uninstall',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 2 }
if (-not $ReportPath) { $ReportPath = Join-Path $env:TEMP ('Mx310-removal-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$log = New-Object System.Collections.Generic.List[string]
function Add-Log([string]$Text) { $log.Add(('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'),$Text)); Write-Host $Text }

try {
    Add-Log 'Starting debug uninstall.'
    $ciTool = Join-Path $env:WINDIR 'System32\CiTool.exe'
    $policyList = ((@(& $ciTool -lp -json 2>&1) -join "`n") | ConvertFrom-Json)
    $policy = @($policyList.Policies | Where-Object { ([string]$_.PolicyID).Trim('{}') -eq $policyId }) | Select-Object -First 1
    if ($null -eq $policy -or -not [bool]$policy.IsEnforced) {
        if (Test-Path $restoreScript) {
            Add-Log 'Security policy is not enforced. Running restore before cleanup.'
            $restore = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$restoreScript+'"'),'-Elevated') -Wait -PassThru
            if ($restore.ExitCode -ne 0) { throw 'Security restore failed. Cleanup stopped.' }
            throw 'Security restored. Restart Windows, then run this uninstaller again.'
        }
        throw 'Windows Driver Policy is not enforced. Cleanup stopped.'
    }
    Add-Log 'Windows Driver Policy is enforced.'
    $testSigning = @(& bcdedit.exe /enum '{current}' 2>&1 | Where-Object { [string]$_ -match '(?i)testsigning' })
    if (@($testSigning | Where-Object { [string]$_ -match '(?i)\b(yes|on)\b' }).Count -gt 0) { throw 'TESTSIGNING is enabled. Cleanup stopped.' }
    Add-Log 'TESTSIGNING is off.'

    $devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like $devicePattern })
    $driverNames = @($devices | ForEach-Object {
        $value = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
        if ($value -match '^oem\d+\.inf$') { [string]$value }
    } | Sort-Object -Unique)
    foreach ($driverName in $driverNames) {
        Add-Log ('Removing driver package ' + $driverName)
        $output = @(& pnputil.exe /delete-driver $driverName /uninstall /force 2>&1)
        $output | ForEach-Object { Add-Log ([string]$_) }
        if ($LASTEXITCODE -ne 0) { throw ('pnputil failed with exit code ' + $LASTEXITCODE) }
    }

    if (Test-Path $thumbprintFile) {
        $thumbprint = (Get-Content $thumbprintFile -Raw).Trim()
        foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher')) {
            @(Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumbprint }) | Remove-Item -Force
        }
        Add-Log 'Removed bundled certificate.'
    }
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'MX310NativeContinue' -ErrorAction SilentlyContinue
    foreach ($desktop in @([Environment]::GetFolderPath('Desktop'),(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'OneDrive\Desktop')) | Where-Object { $_ } | Sort-Object -Unique) {
        foreach ($name in @('Mx310 Evgenium Scanner.lnk','Canon MX310 Scanner.lnk','Canon MX310 Collect diagnostics.lnk','2 CONTINUE Canon MX310 install.lnk','RESTORE Windows security after MX310.lnk')) {
            $shortcut = Join-Path $desktop $name
            if (Test-Path $shortcut) { Remove-Item $shortcut -Force; Add-Log ('Removed shortcut ' + $shortcut) }
        }
    }
    if (Test-Path $installRoot) { Remove-Item $installRoot -Recurse -Force; Add-Log ('Removed ' + $installRoot) }
    & pnputil.exe /scan-devices | Out-Null
    Add-Log 'Cleanup commands completed.'
}
catch {
    Add-Log ('ERROR: ' + $_.Exception.Message)
    $log | Set-Content $ReportPath -Encoding UTF8
    [Windows.Forms.MessageBox]::Show($_.Exception.Message+"`r`n`r`nReport: "+$ReportPath,'Mx310 debug uninstall',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
$log | Set-Content $ReportPath -Encoding UTF8
exit 0

