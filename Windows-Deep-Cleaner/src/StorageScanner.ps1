# =============================================================================
#  StorageScanner.ps1
#  Quet fixed drives tim file khong sua doi > N ngay, phan loai, de xuat duyet
# =============================================================================

$Script:CategoryMap = @{}
$Script:CategoryInfo = [ordered]@{
    'Temp'      = @{ Label = 'File tam';              Status = 'CanClean';      Policy = 'Co the don theo quy tac an toan (van can xac nhan)' }
    'Installer' = @{ Label = 'File cai dat/tai ve';   Status = 'PendingReview'; Policy = 'Liet ke de nguoi dung duyet' }
    'Media'     = @{ Label = 'Anh/video/audio';       Status = 'PendingReview'; Policy = 'Khong tu xoa - chi xoa khi nguoi dung chon' }
    'Document'  = @{ Label = 'Tai lieu';              Status = 'PendingReview'; Policy = 'Khong tu xoa - chi xoa khi nguoi dung chon' }
    'Source'    = @{ Label = 'Du an/ma nguon';        Status = 'Protected';     Policy = 'Bao ve' }
    'Database'  = @{ Label = 'Co so du lieu';         Status = 'Protected';     Policy = 'Bao ve' }
    'Backup'    = @{ Label = 'Backup/restore/VM';     Status = 'Protected';     Policy = 'Bao ve' }
    'System'    = @{ Label = 'File he thong';         Status = 'Protected';     Policy = 'Khong quet xoa tu dong' }
    'Unknown'   = @{ Label = 'Khong ro loai';         Status = 'Protected';     Policy = 'Giu nguyen' }
}

$exts = @{
    'Temp'      = '.tmp .temp .dmp .chk .crdownload .part .partial .download'
    'Installer' = '.iso .img .exe .msi .msix .msixbundle .appx .appxbundle .msp .zip .rar .7z .cab .tar .gz .tgz .bz2 .xz .dmg .apk'
    'Media'     = '.jpg .jpeg .png .gif .bmp .tif .tiff .webp .heic .heif .raw .cr2 .nef .arw .dng .psd .mp4 .mov .mkv .avi .wmv .flv .webm .m4v .mpg .mpeg .3gp .ts .mts .m2ts .mp3 .wav .flac .aac .m4a .ogg .wma .opus'
    'Document'  = '.pdf .doc .docx .xls .xlsx .xlsm .ppt .pptx .odt .ods .odp .rtf .txt .csv .md .epub .mobi .djvu .xps .one .pages .numbers .key'
    'Source'    = '.cs .vb .fs .js .mjs .cjs .ts .tsx .jsx .vue .svelte .py .ipynb .java .kt .kts .scala .go .rs .c .cc .cpp .cxx .h .hpp .m .mm .swift .php .rb .pl .lua .r .dart .sh .ps1 .psm1 .bat .cmd .gradle .sln .csproj .yml .yaml .toml .ini .json .xml'
    'Database'  = '.db .db3 .sqlite .sqlite3 .mdf .ldf .ndf .sql .dump .bson .frm .ibd .myd .myi .accdb .mdb .dbf .rdb .aof .wt .kdbx .realm .fdb .gdb'
    'Backup'    = '.bak .backup .bkp .bkf .tib .tibx .vbk .vib .vrb .gho .wim .esd .mrimg .adi .spf .vmdk .vhd .vhdx .avhdx .vdi .ova .ovf .qcow2 .vmsn .vmem .nvram .hds .pvm'
    'System'    = '.sys .dll .drv .ocx .cpl .mui .efi .cat .inf .msc .lnk'
}
foreach ($k in $exts.Keys) {
    foreach ($e in $exts[$k].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) { $Script:CategoryMap[$e] = $k }
}
Remove-Variable exts

function Get-FileCategory {
    param([System.IO.FileInfo]$File)
    $attr = $File.Attributes
    if (($attr -band [System.IO.FileAttributes]::System) -ne 0) { return 'System' }
    $name = $File.Name.ToLowerInvariant()
    if ($name -in @('pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'bootmgr', 'desktop.ini', 'thumbs.db', 'ntuser.dat')) { return 'System' }
    if ($name.StartsWith('ntuser.') -or $name.StartsWith('usrclass.')) { return 'System' }
    if ($name.StartsWith('~$')) { return 'Temp' }
    $ext = $File.Extension.ToLowerInvariant()
    if ($ext -and $Script:CategoryMap.ContainsKey($ext)) { return $Script:CategoryMap[$ext] }
    return 'Unknown'
}

function Invoke-StorageScan {
    param(
        [Parameter(Mandatory)][object[]]$Drives,
        [int]$Days = 180,
        [double]$MinSizeMB = 1
    )
    $cut = (Get-Date).AddDays(-$Days)
    $minBytes = [int64]($MinSizeMB * 1MB)
    $now = Get-Date

    $items = New-Object System.Collections.Generic.List[object]
    $protectedDirs = New-Object System.Collections.Generic.List[object]
    $skippedDirs = New-Object System.Collections.Generic.List[object]
    $catStats = @{}
    foreach ($k in $Script:CategoryInfo.Keys) { $catStats[$k] = [pscustomobject]@{ Category = $k; Count = 0; Bytes = [int64]0; Listed = 0 } }
    $driveStats = New-Object System.Collections.Generic.List[object]
    $counter = @{ Protected = 0; Skipped = 0 }
    $id = 0

    $onProtected = {
        param($p, $r)
        $counter.Protected++
        if ($protectedDirs.Count -lt 5000) { $protectedDirs.Add([pscustomobject]@{ Path = $p; Reason = $r }) }
    }.GetNewClosure()
    $onSkipped = {
        param($p, $r)
        $counter.Skipped++
        if ($skippedDirs.Count -lt 5000) { $skippedDirs.Add([pscustomobject]@{ Path = $p; Reason = $r }) }
    }.GetNewClosure()
    $filter = { param($f) $f.LastWriteTime -lt $cut }.GetNewClosure()

    foreach ($d in $Drives) {
        Write-Log "Quet o dia $($d.Root) (file khong sua doi > $Days ngay)..." -Level INFO
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $files = Get-SafeFiles -Root $d.Root -RespectProtection -OnProtected $onProtected -OnSkipped $onSkipped -FileFilter $filter
        $dCount = 0; $dBytes = [int64]0; $dReview = [int64]0
        foreach ($f in $files) {
            $len = [int64]0
            try { $len = $f.Length; $lwt = $f.LastWriteTime } catch {
                $counter.Skipped++
                if ($skippedDirs.Count -lt 5000) { $skippedDirs.Add([pscustomobject]@{ Path = $f.FullName; Reason = 'Metadata khong doc duoc (Unknown/Skipped)' }) }
                continue
            }
            $cat = Get-FileCategory $f
            $info = $Script:CategoryInfo[$cat]
            $cs = $catStats[$cat]
            $cs.Count++; $cs.Bytes += $len
            $dCount++; $dBytes += $len
            if ($info.Status -ne 'Protected') { $dReview += $len }

            if ($len -lt $minBytes -or $cat -eq 'System') { continue }
            $id++
            $cs.Listed++
            $items.Add([pscustomobject]@{
                    Id            = $id
                    Path          = $f.FullName
                    Drive         = $d.Name
                    Category      = $cat
                    CategoryLabel = $info.Label
                    Extension     = $f.Extension
                    SizeBytes     = $len
                    SizeMB        = [math]::Round($len / 1MB, 2)
                    LastWriteTime = $lwt.ToString('yyyy-MM-ddTHH:mm:ss')
                    AgeDays       = [int]($now - $lwt).TotalDays
                    Status        = $info.Status
                    Reason        = "Khong sua doi $([int]($now - $lwt).TotalDays) ngay; nhom '$($info.Label)': $($info.Policy)"
                    Delete        = ''
                })
        }
        $sw.Stop()
        $driveStats.Add([pscustomobject]@{
                Drive           = $d.Name
                Label           = $d.Label
                SizeBytes       = $d.SizeBytes
                FreeBytes       = $d.FreeBytes
                OldFiles        = $dCount
                OldBytes        = $dBytes
                ReviewableBytes = $dReview
                Seconds         = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            })
        Write-Log ("  {0}: {1} file cu ({2}), quet trong {3}s" -f $d.Name, $dCount, (Format-Size $dBytes), [math]::Round($sw.Elapsed.TotalSeconds, 1))
    }
    Write-Log "Thu muc duoc bao ve (khong quet): $($counter.Protected); bi bo qua: $($counter.Skipped)" -Level INFO

    return [pscustomobject]@{
        Days           = $Days
        MinSizeMB      = $MinSizeMB
        Items          = $items
        CategoryStats  = @($catStats.Values | Sort-Object Bytes -Descending)
        DriveStats     = $driveStats
        ProtectedDirs  = $protectedDirs
        ProtectedCount = $counter.Protected
        SkippedDirs    = $skippedDirs
        SkippedCount   = $counter.Skipped
    }
}

# -------------------------------------------------------- Apply selections ----
function Test-ItemUnchanged {
    # File phai con nguyen nhu luc quet (size + LastWriteTime) moi duoc xoa
    param([object]$Item)
    try {
        $fi = Get-Item -LiteralPath $Item.Path -Force -ErrorAction Stop
        if ($fi.PSIsContainer) { return 'La thu muc' }
        if ([int64]$fi.Length -ne [int64]$Item.SizeBytes) { return 'Kich thuoc da thay doi tu luc quet' }
        if ($fi.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') -ne [string]$Item.LastWriteTime) { return 'File da duoc sua tu luc quet' }
        return $null
    } catch { return 'Khong con ton tai / khong truy cap duoc' }
}

function Remove-ReviewedItems {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string[]]$DriveRoots,
        [switch]$Permanent
    )
    $total = [int64]0
    foreach ($it in $Items) { $total += [int64]$it.SizeBytes }
    Write-Host ''
    Write-Host ("Se xu ly {0} file, tong {1}." -f $Items.Count, (Format-Size $total)) -ForegroundColor Yellow
    Write-Host ($(if ($Permanent) { 'Che do: XOA VINH VIEN (khong qua Recycle Bin).' } else { 'Che do: chuyen vao Recycle Bin (co the khoi phuc khi Recycle Bin chua bi lam trong).' })) -ForegroundColor Yellow
    if (-not (Confirm-Action 'Ban chac chan muon tiep tuc?' -StrongConfirm)) {
        Write-Log 'Nguoi dung huy thao tac xoa file da duyet.' -Level INFO
        return
    }
    $i = 0
    foreach ($it in $Items) {
        $i++
        Write-Progress -Activity 'Xoa file da duyet' -Status "$i / $($Items.Count)" -PercentComplete ([math]::Min(100, $i * 100 / [math]::Max(1, $Items.Count)))
        if ($it.Status -eq 'Protected') {
            $Script:Stats.Skipped++
            Add-ActionRecord 'StorageScanner' 'Delete' $it.Path 'Skipped' 0 'Nhom duoc bao ve'
            continue
        }
        $chg = Test-ItemUnchanged $it
        if ($chg) {
            $Script:Stats.Skipped++
            Write-Log "Bo qua: $($it.Path) - $chg" -Level SKIP -Quiet
            Add-ActionRecord 'StorageScanner' 'Delete' $it.Path 'Skipped' 0 $chg
            continue
        }
        [void](Remove-SafeFile -Path $it.Path -AllowedRoots $DriveRoots -Module 'StorageScanner' -CheckProtection -ToRecycleBin:(-not $Permanent))
    }
    Write-Progress -Activity 'Xoa file da duyet' -Completed
    Write-Log 'Hoan tat xu ly file da duyet.' -Level OK
}

function Invoke-ReviewByCategory {
    param([object]$Scan, [string[]]$DriveRoots)
    $selectable = @($Scan.Items | Where-Object { $_.Status -ne 'Protected' })
    if ($selectable.Count -eq 0) { Write-Host 'Khong co file nao co the chon.' -ForegroundColor Gray; return }

    $groups = @($selectable | Group-Object Category | ForEach-Object {
            $b = [int64]0; foreach ($x in $_.Group) { $b += [int64]$x.SizeBytes }
            [pscustomobject]@{ Category = $_.Name; Label = $Script:CategoryInfo[$_.Name].Label; Count = $_.Count; Bytes = $b; Items = $_.Group }
        } | Sort-Object Bytes -Descending)

    while ($true) {
        Write-Host ''
        Write-Host '--- File cu theo nhom (chi nhom khong duoc bao ve) ---' -ForegroundColor Cyan
        for ($i = 0; $i -lt $groups.Count; $i++) {
            Write-Host ("  [{0}] {1,-22} {2,8} file  {3,12}" -f ($i + 1), $groups[$i].Label, $groups[$i].Count, (Format-Size $groups[$i].Bytes))
        }
        Write-Host '  [D] Mo file CSV de chon tung file (dien YES vao cot Delete), sau do dung menu "Ap dung CSV"'
        Write-Host '  [0] Quay lai'
        $c = Read-Host 'Chon nhom'
        if ($c -eq '0' -or [string]::IsNullOrWhiteSpace($c)) { return }
        if ($c -match '^[dD]$') { return 'OpenCsv' }
        $n = 0
        if (-not [int]::TryParse($c, [ref]$n) -or $n -lt 1 -or $n -gt $groups.Count) { continue }
        $g = $groups[$n - 1]

        Write-Host ''
        Write-Host "Top 20 file lon nhat trong nhom '$($g.Label)':" -ForegroundColor Cyan
        $g.Items | Sort-Object SizeBytes -Descending | Select-Object -First 20 |
            Format-Table @{n = 'MB'; e = { $_.SizeMB } }, AgeDays, Path -AutoSize | Out-Host
        Write-Host '  [A] Xu ly TAT CA file trong nhom   [L] Chi file lon hon N MB   [0] Huy'
        $m = Read-Host 'Lua chon'
        $sel = $null
        switch -Regex ($m) {
            '^[aA]$' { $sel = $g.Items }
            '^[lL]$' {
                $mb = 0
                if ([double]::TryParse((Read-Host 'Nguong MB'), [ref]$mb)) { $sel = @($g.Items | Where-Object { $_.SizeMB -ge $mb }) }
            }
            default { $sel = $null }
        }
        if ($sel -and @($sel).Count -gt 0) {
            Remove-ReviewedItems -Items @($sel) -DriveRoots $DriveRoots
            # Bo cac muc da xu ly khoi danh sach
            $done = @{}; foreach ($x in @($sel)) { $done[$x.Path] = $true }
            $g.Items = @($g.Items | Where-Object { -not $done.ContainsKey($_.Path) -and (Test-Path -LiteralPath $_.Path) })
            $g.Count = $g.Items.Count
            $b = [int64]0; foreach ($x in $g.Items) { $b += [int64]$x.SizeBytes }; $g.Bytes = $b
        }
    }
}

function Invoke-ApplyReviewCsv {
    param([Parameter(Mandatory)][string]$CsvPath, [string[]]$DriveRoots, [switch]$Permanent)
    if (-not (Test-Path -LiteralPath $CsvPath)) { Write-Log "Khong tim thay CSV: $CsvPath" -Level ERROR; return }
    $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
    $chosen = @($rows | Where-Object { ([string]$_.Delete).Trim() -match '^(yes|y|x|1|true|xoa)$' })
    Write-Log "CSV: $($rows.Count) dong, $($chosen.Count) dong duoc danh dau Delete." -Level INFO
    $valid = New-Object System.Collections.Generic.List[object]
    foreach ($r in $chosen) {
        if ($r.Status -eq 'Protected') {
            Write-Log "Bo qua (nhom duoc bao ve): $($r.Path)" -Level SKIP
            $Script:Stats.Skipped++
            Add-ActionRecord 'StorageScanner' 'Delete' $r.Path 'Skipped' 0 'Nhom duoc bao ve'
            continue
        }
        $valid.Add($r)
    }
    if ($valid.Count -eq 0) { Write-Host 'Khong co muc hop le de xu ly.' -ForegroundColor Gray; return }
    Remove-ReviewedItems -Items $valid.ToArray() -DriveRoots $DriveRoots -Permanent:$Permanent
}
