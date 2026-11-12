<#
.SYNOPSIS
    Windows Deep Cleaner - quet va don dep Windows an toan (Preview truoc, xac nhan ro rang).

.PARAMETER PreviewOnly
    Chi quet va xuat bao cao, khong xoa gi.
.PARAMETER AutoSafeClean
    Khong hoi: chi don Temp/WER (file cu hon tempFileDays). Dung cho chay dinh ky.
.PARAMETER ApplyReviewFile
    Duong dan CSV old-files_*.csv da danh dau YES o cot Delete -> xu ly cac file do.
.PARAMETER Permanent
    Dung cung ApplyReviewFile: xoa vinh vien thay vi chuyen vao Recycle Bin.
.PARAMETER Drives
    Gioi han o dia quet, vd: -Drives C,D
.PARAMETER Days
    Ghi de oldFileDays trong settings.json.
.PARAMETER SkipStorageScan / SkipApps / SkipBrowser
    Bo qua module tuong ung.
.PARAMETER RegisterSchedule / UnregisterSchedule
    Tao / xoa Scheduled Task chay -AutoSafeClean hang tuan.
#>
[CmdletBinding()]
param(
    [switch]$PreviewOnly,
    [switch]$AutoSafeClean,
    [string]$ApplyReviewFile,
    [switch]$Permanent,
    [string[]]$Drives,
    [int]$Days = 0,
    [switch]$SkipStorageScan,
    [switch]$SkipApps,
    [switch]$SkipBrowser,
    [switch]$RegisterSchedule,
    [switch]$UnregisterSchedule
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Script:AppRoot = Split-Path -Parent $PSScriptRoot
$Script:NonInteractive = [bool]$AutoSafeClean

. (Join-Path $PSScriptRoot 'SafetyController.ps1')
. (Join-Path $PSScriptRoot 'SystemCleaner.ps1')
. (Join-Path $PSScriptRoot 'StorageScanner.ps1')
. (Join-Path $PSScriptRoot 'ApplicationManager.ps1')
. (Join-Path $PSScriptRoot 'BrowserCleaner.ps1')
. (Join-Path $PSScriptRoot 'Reporter.ps1')

$configDir = Join-Path $Script:AppRoot 'config'
$reportDir = Join-Path $Script:AppRoot 'reports'
$logDir = Join-Path $Script:AppRoot 'logs'

[void](Initialize-Log -LogDir $logDir)
try { $cfg = Initialize-Safety -ConfigDir $configDir }
catch { Write-Log "Loi cau hinh: $($_.Exception.Message)" -Level ERROR; exit 1 }
$S = $cfg.Settings
if ($Days -le 0) { $Days = [int]$S.oldFileDays }
$isAdmin = Test-IsAdmin

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  WINDOWS DEEP CLEANER  -  Preview truoc, xoa khi duoc xac nhan' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Log "Bat dau. Admin: $isAdmin. Log: $Script:LogFile"
if (-not $isAdmin) { Write-Log 'Khong co quyen Administrator: Windows Temp, DISM, Prefetch, Delivery Optimization se bi gioi han.' -Level WARN }

# ------------------------------------------------------- Scheduled task ----
if ($RegisterSchedule -or $UnregisterSchedule) {
    $taskName = $S.scheduledTask.name
    if (-not $isAdmin) { Write-Log 'Can quyen Administrator de tao/xoa Scheduled Task.' -Level ERROR; exit 1 }
    if ($UnregisterSchedule) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Da xoa Scheduled Task '$taskName'." -Level OK
        exit 0
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -AutoSafeClean" -f $PSCommandPath)
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $S.scheduledTask.dayOfWeek -At $S.scheduledTask.time
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest -LogonType Interactive
    $settingsTask = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries:$false -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settingsTask -Force | Out-Null
    Write-Log "Da tao Scheduled Task '$taskName': $($S.scheduledTask.dayOfWeek) $($S.scheduledTask.time), chi don Temp an toan." -Level OK
    exit 0
}

# ------------------------------------------------------------- Drives ------
$fixed = @(Get-FixedDrives -Only $Drives)
if ($fixed.Count -eq 0) { Write-Log 'Khong tim thay fixed drive nao.' -Level ERROR; exit 1 }
Write-Log ("Fixed drives: {0}" -f (($fixed | ForEach-Object { "$($_.Name) ($(Format-Size $_.FreeBytes) trong / $(Format-Size $_.SizeBytes))" }) -join ', '))
$driveRoots = @($fixed | ForEach-Object { $_.Root })

# ---------------------------------------------------- Apply reviewed CSV ---
if ($ApplyReviewFile) {
    Invoke-ApplyReviewCsv -CsvPath $ApplyReviewFile -DriveRoots $driveRoots -Permanent:$Permanent
    $data = [pscustomobject]@{ Drives = $fixed; Temp = @(); RecycleBin = $null; DeliveryOpt = $null; Storage = $null; Apps = $null; Browser = @(); IsAdmin = $isAdmin; Mode = 'ApplyReviewFile' }
    $files = Export-ScanReport -Data $data -ReportDir $reportDir -Title 'Ket qua xu ly CSV' -IsResult
    Add-RunHistory -ReportDir $reportDir -Data $data -Files $files -Mode 'ApplyReviewFile'
    if ($S.openReportAfterScan) { try { Start-Process $files.Html } catch { } }
    exit 0
}

# ----------------------------------------------------------- Auto clean ----
if ($AutoSafeClean) {
    Write-Log "AutoSafeClean: chi don Temp/WER file cu hon $($S.tempFileDays) ngay." -Level ACTION
    $temp = Invoke-TempScan -Days $S.tempFileDays
    foreach ($t in $temp) { $Script:Stats.EstimatedBytes += $t.Bytes }
    [void](Invoke-TempCleanup -ScanResults $temp)
    $data = [pscustomobject]@{ Drives = $fixed; Temp = $temp; RecycleBin = $null; DeliveryOpt = $null; Storage = $null; Apps = $null; Browser = @(); IsAdmin = $isAdmin; Mode = 'AutoSafeClean' }
    $files = Export-ScanReport -Data $data -ReportDir $reportDir -Title 'Don dep tu dong (Temp)' -IsResult
    Add-RunHistory -ReportDir $reportDir -Data $data -Files $files -Mode 'AutoSafeClean'
    Write-Log ("Hoan tat. Giai phong {0}; xoa {1}, bo qua {2}, loi {3}." -f (Format-Size $Script:Stats.FreedBytes), $Script:Stats.Deleted, $Script:Stats.Skipped, $Script:Stats.Errors) -Level OK
    exit 0
}

# ------------------------------------------------------------- Scan --------
Write-Host ''
Write-Log '[1/5] Quet Temp...' -Level INFO
$temp = Invoke-TempScan -Days $S.tempFileDays

Write-Log '[2/5] Recycle Bin & Delivery Optimization...' -Level INFO
$rb = Get-RecycleBinInfo
Write-Log "  Recycle Bin: $($rb.Count) muc, $(Format-Size $rb.Bytes)"
$doInfo = Get-DeliveryOptimizationInfo
Write-Log "  Delivery Optimization cache: $(Format-Size $doInfo.Bytes)"

$storage = $null
if (-not $SkipStorageScan) {
    Write-Log "[3/5] Quet file cu hon $Days ngay tren $($fixed.Count) o dia (co the mat vai phut)..." -Level INFO
    $storage = Invoke-StorageScan -Drives $fixed -Days $Days -MinSizeMB ([double]$S.minOldFileSizeMB)
} else { Write-Log '[3/5] Bo qua Storage Scanner.' -Level SKIP }

$appScan = $null
if (-not $SkipApps -and $S.scanApplications) {
    Write-Log '[4/5] Liet ke ung dung...' -Level INFO
    $appScan = Invoke-AppScan -InactiveDays ([int]$S.appInactivityDays)
} else { Write-Log '[4/5] Bo qua Application Manager.' -Level SKIP }

$browser = @()
if (-not $SkipBrowser -and $S.scanBrowserCache) {
    Write-Log '[5/5] Quet cache trinh duyet...' -Level INFO
    $browser = @(Invoke-BrowserCacheScan)
} else { Write-Log '[5/5] Bo qua Browser Cache.' -Level SKIP }

$data = [pscustomobject]@{
    Drives = $fixed; Temp = $temp; RecycleBin = $rb; DeliveryOpt = $doInfo; Storage = $storage
    Apps = $appScan; Browser = $browser; IsAdmin = $isAdmin; Mode = $(if ($PreviewOnly) { 'Preview' } else { 'Preview + Interactive' })
}
$scanFiles = Export-ScanReport -Data $data -ReportDir $reportDir -Title 'Bao cao quet (Preview)'
if ($S.openReportAfterScan) { try { Start-Process $scanFiles.Html } catch { } }

if ($PreviewOnly) {
    Add-RunHistory -ReportDir $reportDir -Data $data -Files $scanFiles -Mode 'Preview'
    Write-Log 'Che do Preview: khong co gi bi xoa.' -Level OK
    exit 0
}

# ------------------------------------------------------- Interactive -------
function Get-TempTotal { $b = [int64]0; $c = 0; foreach ($t in $temp) { $b += $t.Bytes; $c += $t.Count }; return @($c, $b) }

$didSomething = $false
while ($true) {
    $tt = Get-TempTotal
    $bb = [int64]0; foreach ($b in $browser) { $bb += $b.Bytes }
    $pend = if ($storage) { @($storage.Items | Where-Object { $_.Status -ne 'Protected' }).Count } else { 0 }
    $appc = if ($appScan) { @($appScan.Apps | Where-Object { $_.Status -ne 'Protected' }).Count } else { 0 }
    Write-Host ''
    Write-Host '=================== MENU DON DEP ===================' -ForegroundColor Cyan
    Write-Host ("  [1] Don Temp/WER an toan        ({0} file, {1})" -f $tt[0], (Format-Size $tt[1]))
    Write-Host  '  [2] DISM Component Store Cleanup (khong /ResetBase)'
    Write-Host ("  [3] Lam trong Recycle Bin        ({0} muc, {1})" -f $rb.Count, (Format-Size $rb.Bytes))
    Write-Host ("  [4] Xoa Delivery Optimization    ({0})" -f (Format-Size $doInfo.Bytes))
    Write-Host ("  [5] Don cache trinh duyet        ({0})" -f (Format-Size $bb))
    Write-Host ("  [6] Duyet file cu theo nhom      ({0} file co the chon)" -f $pend)
    Write-Host  '  [7] Ap dung file CSV da danh dau (cot Delete = YES)'
    Write-Host ("  [8] Go ung dung                  ({0} ung dung khong duoc bao ve)" -f $appc)
    Write-Host  '  [9] Mo lai bao cao Preview'
    Write-Host  '  [0] Ket thuc va xuat bao cao ket qua'
    $choice = Read-Host 'Lua chon'
    switch ($choice) {
        '1' {
            if ($tt[0] -eq 0) { Write-Host 'Khong co file Temp du dieu kien.' -ForegroundColor Gray; break }
            if (Confirm-Action ("Xoa {0} file tam cu hon {1} ngay ({2})?" -f $tt[0], $S.tempFileDays, (Format-Size $tt[1]))) {
                [void](Invoke-TempCleanup -ScanResults $temp)
                $temp = Invoke-TempScan -Days $S.tempFileDays
                $didSomething = $true
            }
        }
        '2' {
            if (Confirm-Action 'Chay DISM /StartComponentCleanup? (co the mat 5-30 phut, khong dung /ResetBase)') { Invoke-ComponentCleanup; $didSomething = $true }
        }
        '3' {
            if ($rb.Count -eq 0) { Write-Host 'Recycle Bin dang trong.' -ForegroundColor Gray; break }
            Write-Host 'Canh bao: sau khi lam trong, cac file trong Recycle Bin KHONG the khoi phuc bang cach thong thuong.' -ForegroundColor Yellow
            if (Confirm-Action ("Lam trong Recycle Bin ({0} muc, {1})?" -f $rb.Count, (Format-Size $rb.Bytes)) -StrongConfirm) {
                Clear-RecycleBinSafe -Info $rb; $rb = Get-RecycleBinInfo; $didSomething = $true
            }
        }
        '4' {
            if (Confirm-Action ("Xoa Delivery Optimization cache ({0}) bang cmdlet chinh thuc?" -f (Format-Size $doInfo.Bytes))) {
                Clear-DeliveryOptimizationSafe -Info $doInfo; $doInfo = Get-DeliveryOptimizationInfo; $didSomething = $true
            }
        }
        '5' {
            if ($browser.Count -eq 0) { Write-Host 'Khong tim thay cache trinh duyet.' -ForegroundColor Gray; break }
            Invoke-BrowserCacheCleanup -Scan $browser; $browser = @(Invoke-BrowserCacheScan); $didSomething = $true
        }
        '6' {
            if (-not $storage) { Write-Host 'Storage Scanner da bi bo qua.' -ForegroundColor Gray; break }
            $r = Invoke-ReviewByCategory -Scan $storage -DriveRoots $driveRoots
            if ($r -eq 'OpenCsv' -and $scanFiles.OldFilesCsv) { try { Start-Process $scanFiles.OldFilesCsv } catch { } }
            $storage.Items = @($storage.Items | Where-Object { Test-Path -LiteralPath $_.Path })
            $didSomething = $true
        }
        '7' {
            $default = $scanFiles.OldFilesCsv
            $p = Read-Host "Duong dan CSV (Enter = $default)"
            if ([string]::IsNullOrWhiteSpace($p)) { $p = $default }
            if ($p) { Invoke-ApplyReviewCsv -CsvPath $p.Trim('"') -DriveRoots $driveRoots; $didSomething = $true }
        }
        '8' {
            if (-not $appScan) { Write-Host 'Application Manager da bi bo qua.' -ForegroundColor Gray; break }
            Invoke-AppReviewMenu -AppScan $appScan; $didSomething = $true
        }
        '9' { try { Start-Process $scanFiles.Html } catch { } }
        '0' { break }
        default { }
    }
    if ($choice -eq '0') { break }
}

# --------------------------------------------------------- Result ----------
$data.Temp = $temp; $data.RecycleBin = $rb; $data.DeliveryOpt = $doInfo; $data.Browser = $browser
if ($didSomething) {
    $resFiles = Export-ScanReport -Data $data -ReportDir $reportDir -Title 'Ket qua don dep' -IsResult
    Add-RunHistory -ReportDir $reportDir -Data $data -Files $resFiles -Mode 'Interactive'
    if ($S.openReportAfterScan) { try { Start-Process $resFiles.Html } catch { } }
} else {
    Add-RunHistory -ReportDir $reportDir -Data $data -Files $scanFiles -Mode 'Preview'
}
Write-Log ("Ket thuc. Thuc te giai phong {0}; da xoa {1}, bo qua {2}, loi {3}." -f (Format-Size $Script:Stats.FreedBytes), $Script:Stats.Deleted, $Script:Stats.Skipped, $Script:Stats.Errors) -Level OK
