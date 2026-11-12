# =============================================================================
#  SystemCleaner.ps1
#  Temp, Windows Error Reporting, DISM, Recycle Bin, Delivery Optimization
# =============================================================================

function Get-TempTargets {
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $add = {
        param($name, $path)
        if (-not $path) { return }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { return }
        try { $full = (Get-Item -LiteralPath $path -Force).FullName } catch { return }
        $key = ConvertTo-NormalPath $full
        # Khong bao gio chap nhan root o dia hoac thu muc qua ngan lam vung temp
        if ($key.Length -le 3 -or $seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $list.Add([pscustomobject]@{ Name = $name; Path = $full })
    }

    & $add 'User Temp' $env:TEMP
    & $add 'User Temp' ([System.IO.Path]::GetTempPath())
    & $add 'Windows Temp' (Join-Path $env:SystemRoot 'Temp')
    & $add 'Windows Error Reporting (Archive)' (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
    & $add 'Windows Error Reporting (Queue)' (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
    foreach ($p in @($Script:Config.Settings.additionalTempPaths)) {
        $e = Expand-ConfigPath $p
        if ($e) { & $add 'Temp bo sung' $e }
    }
    return $list
}

function Invoke-TempScan {
    param([int]$Days)
    $cut = (Get-Date).AddDays(-$Days)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in Get-TempTargets) {
        Write-Log "Quet Temp: $($t.Path)" -Quiet
        $filter = { param($f) $f.LastWriteTime -lt $cut }.GetNewClosure()
        $files = Get-SafeFiles -Root $t.Path -FileFilter $filter
        $bytes = [int64]0
        foreach ($f in $files) { $bytes += $f.Length }
        $results.Add([pscustomobject]@{
                Name  = $t.Name
                Path  = $t.Path
                Files = $files
                Count = $files.Count
                Bytes = $bytes
            })
        Write-Log ("  {0}: {1} file cu hon {2} ngay, {3}" -f $t.Name, $files.Count, $Days, (Format-Size $bytes))
    }
    return $results
}

function Invoke-TempCleanup {
    param([object[]]$ScanResults)
    $freedBefore = $Script:Stats.FreedBytes
    foreach ($r in $ScanResults) {
        if ($r.Count -eq 0) { continue }
        Write-Log "Dang don: $($r.Name) - $($r.Path)" -Level ACTION
        $i = 0
        foreach ($f in $r.Files) {
            $i++
            if (($i % 500) -eq 0) { Write-Progress -Activity "Don $($r.Name)" -Status "$i / $($r.Count)" -PercentComplete ([math]::Min(100, $i * 100 / $r.Count)) }
            [void](Remove-SafeFile -Path $f.FullName -AllowedRoots @($r.Path) -Module 'SystemCleaner/Temp')
        }
        Write-Progress -Activity "Don $($r.Name)" -Completed
        Remove-EmptyDirectories -Root $r.Path -Module 'SystemCleaner/Temp'
    }
    $freed = $Script:Stats.FreedBytes - $freedBefore
    Write-Log "Temp: da giai phong $(Format-Size $freed)" -Level OK
    return $freed
}

# ------------------------------------------------------------------- DISM ----
function Invoke-ComponentCleanup {
    if (-not (Test-IsAdmin)) {
        Write-Log 'DISM can quyen Administrator - bo qua.' -Level WARN
        Add-ActionRecord 'SystemCleaner/DISM' 'StartComponentCleanup' 'WinSxS' 'Skipped' 0 'Khong co quyen Admin'
        return
    }
    $sys = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    $freeBefore = if ($sys) { [int64]$sys.Free } else { 0 }
    Write-Log 'Chay: DISM /Online /Cleanup-Image /StartComponentCleanup (khong dung /ResetBase). Co the mat 5-30 phut...' -Level ACTION
    try {
        $p = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" `
            -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' `
            -Wait -NoNewWindow -PassThru
        $sys = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
        $freed = if ($sys) { [math]::Max(0, [int64]$sys.Free - $freeBefore) } else { 0 }
        if ($p.ExitCode -eq 0) {
            Write-Log "DISM hoan tat. Dung luong trong tang them ~ $(Format-Size $freed)" -Level OK
            Add-ActionRecord 'SystemCleaner/DISM' 'StartComponentCleanup' 'WinSxS' 'Done' $freed
            $Script:Stats.FreedBytes += $freed
        } else {
            $Script:Stats.Errors++
            Write-Log "DISM ket thuc voi ma loi $($p.ExitCode)" -Level ERROR
            Add-ActionRecord 'SystemCleaner/DISM' 'StartComponentCleanup' 'WinSxS' 'Error' 0 "ExitCode $($p.ExitCode)"
        }
    } catch {
        $Script:Stats.Errors++
        Write-Log "Khong chay duoc DISM: $($_.Exception.Message)" -Level ERROR
        Add-ActionRecord 'SystemCleaner/DISM' 'StartComponentCleanup' 'WinSxS' 'Error' 0 $_.Exception.Message
    }
}

# ------------------------------------------------------------ Recycle Bin ----
function Get-RecycleBinInfo {
    $info = [pscustomobject]@{ Count = 0; Bytes = [int64]0; Available = $false }
    try {
        $shell = New-Object -ComObject Shell.Application
        $items = $shell.NameSpace(10).Items()
        $cnt = 0; $bytes = [int64]0
        foreach ($it in $items) {
            $cnt++
            try { $bytes += [int64]$it.Size } catch { }
        }
        $info.Count = $cnt; $info.Bytes = $bytes; $info.Available = $true
    } catch {
        Write-Log "Khong doc duoc Recycle Bin: $($_.Exception.Message)" -Level WARN -Quiet
    }
    return $info
}

function Clear-RecycleBinSafe {
    param([object]$Info)
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        $Script:Stats.FreedBytes += $Info.Bytes
        Write-Log "Da lam trong Recycle Bin ($($Info.Count) muc, $(Format-Size $Info.Bytes)). Cac file nay KHONG the khoi phuc tu Recycle Bin nua." -Level OK
        Add-ActionRecord 'SystemCleaner/RecycleBin' 'Empty' 'Recycle Bin' 'Done' $Info.Bytes "$($Info.Count) muc"
    } catch {
        $Script:Stats.Errors++
        Write-Log "Loi khi lam trong Recycle Bin: $($_.Exception.Message)" -Level ERROR
        Add-ActionRecord 'SystemCleaner/RecycleBin' 'Empty' 'Recycle Bin' 'Error' 0 $_.Exception.Message
    }
}

# --------------------------------------------------- Delivery Optimization ----
function Get-DeliveryOptimizationInfo {
    $info = [pscustomobject]@{ Bytes = [int64]0; Supported = $false; Path = $null }
    $info.Supported = [bool](Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)
    $path = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    if (Test-Path -LiteralPath $path) {
        $info.Path = $path
        $files = Get-SafeFiles -Root $path
        foreach ($f in $files) { $info.Bytes += $f.Length }
    }
    return $info
}

function Clear-DeliveryOptimizationSafe {
    param([object]$Info)
    if (-not $Info.Supported) {
        Write-Log 'He thong khong co cmdlet Delete-DeliveryOptimizationCache - bo qua (khong xoa thu cong).' -Level WARN
        Add-ActionRecord 'SystemCleaner/DeliveryOptimization' 'Delete' 'DO Cache' 'Skipped' 0 'Khong ho tro'
        return
    }
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        $Script:Stats.FreedBytes += $Info.Bytes
        Write-Log "Da xoa Delivery Optimization cache (~$(Format-Size $Info.Bytes))." -Level OK
        Add-ActionRecord 'SystemCleaner/DeliveryOptimization' 'Delete' 'DO Cache' 'Done' $Info.Bytes
    } catch {
        $Script:Stats.Errors++
        Write-Log "Loi Delivery Optimization: $($_.Exception.Message)" -Level ERROR
        Add-ActionRecord 'SystemCleaner/DeliveryOptimization' 'Delete' 'DO Cache' 'Error' 0 $_.Exception.Message
    }
}
