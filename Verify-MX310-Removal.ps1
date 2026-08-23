param([string]$ReportPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
if (-not $ReportPath) { $ReportPath = Join-Path $env:TEMP ('Mx310-removal-verification-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$results = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name,[bool]$Found,[string]$Details) { $results.Add([pscustomobject]@{Check=$Name;Result=$(if($Found){'FOUND'}else{'CLEAN'});Details=$Details}) }

$devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\VID_04A9&PID_1728&MI_00\*' })
$bound = @($devices | Where-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction SilentlyContinue).Data -eq 'WinUSB' })
$boundIds = @($bound | ForEach-Object { [string]$_.InstanceId })
$enumKey='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\USB\VID_04A9&PID_1728&MI_00'
if(Test-Path $enumKey){
    Get-ChildItem $enumKey -ErrorAction SilentlyContinue|ForEach-Object{
        $properties=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $service=$null
        if($null-ne$properties){$serviceProperty=$properties.PSObject.Properties['Service'];if($null-ne$serviceProperty){$service=$serviceProperty.Value}}
        if($service-eq'WinUSB'){$boundIds+=('USB\VID_04A9&PID_1728&MI_00\'+$_.PSChildName)}
    }
}
$boundIds=@($boundIds|Sort-Object -Unique)
Add-Check 'MI_00 WinUSB binding' ($boundIds.Count -gt 0) ($boundIds-join '; ')

$packages = New-Object System.Collections.Generic.List[string]
$windowsInf = Join-Path $env:WINDIR 'INF'
Get-ChildItem $windowsInf -Filter 'oem*.inf' -File -ErrorAction SilentlyContinue | ForEach-Object {
    if((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'VID_04A9&PID_1728&MI_00'){$packages.Add($_.FullName)}
}
Add-Check 'MX310 package in Driver Store' ($packages.Count -gt 0) ($packages-join '; ')

$installRoot = Join-Path $env:ProgramData 'MX310-Native'
Add-Check 'ProgramData installation directory' (Test-Path $installRoot) $installRoot

$shortcuts = New-Object System.Collections.Generic.List[string]
foreach($desktop in @([Environment]::GetFolderPath('Desktop'),(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'OneDrive\Desktop'))|Where-Object{$_}|Sort-Object -Unique){
    Get-ChildItem $desktop -Filter '*MX310*.lnk' -ErrorAction SilentlyContinue | ForEach-Object{$shortcuts.Add($_.FullName)}
    Get-ChildItem $desktop -Filter '*Mx310*.lnk' -ErrorAction SilentlyContinue | ForEach-Object{if(-not$shortcuts.Contains($_.FullName)){$shortcuts.Add($_.FullName)}}
}
Add-Check 'Desktop shortcuts' ($shortcuts.Count -gt 0) ($shortcuts-join '; ')
$runOnce=$null
$runOnceObject=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'MX310NativeContinue' -ErrorAction SilentlyContinue
if($null-ne$runOnceObject){$runOnce=$runOnceObject.PSObject.Properties['MX310NativeContinue'].Value}
Add-Check 'RunOnce continuation' ($null-ne$runOnce) ([string]$runOnce)
$thumbprint='7FAC2BE69B249B4CD28E2D580326B8DA336666E6'
$certs=@(Get-ChildItem 'Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher' -ErrorAction SilentlyContinue|Where-Object{$_.Thumbprint-eq$thumbprint})
$certDetails=@($certs|ForEach-Object{[string]$_.PSParentPath})
Add-Check 'Bundled driver certificate' ($certs.Count-gt0) ($certDetails-join '; ')
$testLines=@(& bcdedit.exe /enum '{current}' 2>&1|Where-Object{[string]$_-match'(?i)testsigning'})
Add-Check 'TESTSIGNING enabled' (@($testLines|Where-Object{[string]$_-match'(?i)\b(yes|on)\b'}).Count-gt0) ($testLines-join' ')

$report=@('Mx310_Evgenium_scanner removal verification',('Time: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),'')
$report+=$results|ForEach-Object{'[{0}] {1}: {2}'-f$_.Result,$_.Check,$_.Details}
$found=@($results|Where-Object{$_.Result-eq'FOUND'}).Count
$report+='';$report+=$(if($found-eq0){'FINAL RESULT: CLEAN'}else{'FINAL RESULT: RESIDUES FOUND = '+$found})
$report|Set-Content $ReportPath -Encoding UTF8;$report|ForEach-Object{Write-Host $_}
if($found-eq0){exit 0}else{exit 3}
