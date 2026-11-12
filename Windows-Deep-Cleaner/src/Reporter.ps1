# =============================================================================
#  Reporter.ps1
#  HTML report, CSV export, JSON history
# =============================================================================

function ConvertTo-Html5Safe {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-HtmlTable {
    param([object[]]$Rows, [string[]]$Columns, [hashtable]$Headers = @{}, [string]$Id = '', [hashtable]$Format = @{})
    $sb = New-Object System.Text.StringBuilder
    if (-not $Rows -or $Rows.Count -eq 0) { return '<p class="muted">Khong co du lieu.</p>' }
    if ($Id) { [void]$sb.Append("<input class=`"filter`" placeholder=`"Loc...`" oninput=`"filterTable(this,'$Id')`">") }
    [void]$sb.Append("<div class=`"tw`"><table id=`"$Id`"><thead><tr>")
    foreach ($c in $Columns) {
        $h = if ($Headers.ContainsKey($c)) { $Headers[$c] } else { $c }
        [void]$sb.Append("<th>$(ConvertTo-Html5Safe $h)</th>")
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            $v = $r.$c
            if ($Format.ContainsKey($c)) { $v = & $Format[$c] $v $r }
            $cls = ''
            if ($c -eq 'Status') { $cls = " class=`"st st-$(ConvertTo-Html5Safe $r.$c)`"" }
            [void]$sb.Append("<td$cls>$(ConvertTo-Html5Safe $v)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function Get-ReportCss {
    return @'
:root{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--muted:#667085;--line:#e4e7ec;--accent:#2563eb;
--ok:#15803d;--okbg:#dcfce7;--warn:#b45309;--warnbg:#fef3c7;--prot:#1d4ed8;--protbg:#dbeafe;--skip:#475467;--skipbg:#eaecf0;--err:#b42318;--errbg:#fee4e2}
@media (prefers-color-scheme:dark){:root{--bg:#0f1218;--card:#171b23;--fg:#e6e8ec;--muted:#98a2b3;--line:#2a303b;--accent:#60a5fa;
--ok:#4ade80;--okbg:#14321f;--warn:#fbbf24;--warnbg:#3a2c0b;--prot:#93c5fd;--protbg:#172a4a;--skip:#cbd5e1;--skipbg:#262c36;--err:#fca5a5;--errbg:#3b1414}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1280px;margin:0 auto;padding:24px 16px 64px}h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 12px}
.muted{color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.card .v{font-size:24px;font-weight:600}.card .k{color:var(--muted);font-size:13px}
.groups{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.g{border-radius:10px;padding:12px 14px;border:1px solid var(--line);background:var(--card)}
.g b{display:block;margin-bottom:4px}.g-ok b{color:var(--ok)}.g-warn b{color:var(--warn)}.g-prot b{color:var(--prot)}.g-skip b{color:var(--skip)}
.tw{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{position:sticky;top:0;background:var(--card);font-weight:600}td{word-break:break-all}
.st{font-weight:600;white-space:nowrap;word-break:normal}.st-CanClean,.st-Done,.st-Deleted,.st-InUse{color:var(--ok)}
.st-PendingReview,.st-NeedsReview,.st-ManualCheck{color:var(--warn)}.st-Protected{color:var(--prot)}
.st-Skipped,.st-NoUsageData,.st-Cancelled{color:var(--skip)}.st-Error{color:var(--err)}
.filter{margin:0 0 8px;padding:6px 10px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);width:min(360px,100%)}
.note{background:var(--warnbg);color:var(--fg);border-radius:8px;padding:10px 14px;margin-top:12px}
details{margin-top:8px}summary{cursor:pointer;color:var(--accent)}
'@
}

function Export-ScanReport {
    <#
      Xuat bao cao HTML + CSV. Tra ve hashtable cac duong dan file.
      $Data: pscustomobject { Drives, Temp, RecycleBin, DeliveryOpt, Storage, Apps, Browser, IsAdmin, Mode }
    #>
    param([Parameter(Mandatory)][object]$Data, [Parameter(Mandatory)][string]$ReportDir, [string]$Title = 'Bao cao quet', [switch]$IsResult)

    if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $prefix = if ($IsResult) { 'result' } else { 'scan' }
    $out = @{}
    $maxRows = [int]$Script:Config.Settings.htmlMaxRows
    if ($maxRows -le 0) { $maxRows = 500 }

    # ---------- CSV ----------
    if ($Data.Storage -and $Data.Storage.Items.Count -gt 0) {
        $out.OldFilesCsv = Join-Path $ReportDir "old-files_$ts.csv"
        $Data.Storage.Items | Sort-Object SizeBytes -Descending |
            Select-Object Id, Delete, Status, Category, CategoryLabel, SizeMB, SizeBytes, AgeDays, LastWriteTime, Drive, Extension, Path, Reason |
            Export-Csv -LiteralPath $out.OldFilesCsv -NoTypeInformation -Encoding UTF8
    }
    if ($Data.Apps -and $Data.Apps.Apps.Count -gt 0) {
        $out.AppsCsv = Join-Path $ReportDir "applications_$ts.csv"
        $Data.Apps.Apps | Select-Object Id, Status, Group, Type, Name, Publisher, Version, InstallDate,
        @{n = 'SizeMB'; e = { if ($_.SizeBytes) { [math]::Round($_.SizeBytes / 1MB, 1) } else { '' } } }, LastUsed, Evidence, InstallLocation, UninstallString |
            Export-Csv -LiteralPath $out.AppsCsv -NoTypeInformation -Encoding UTF8
    }
    if ($Script:ActionLog.Count -gt 0) {
        $out.ActionsCsv = Join-Path $ReportDir "actions_$ts.csv"
        $Script:ActionLog | Export-Csv -LiteralPath $out.ActionsCsv -NoTypeInformation -Encoding UTF8
    }

    # ---------- So lieu tong hop ----------
    $tempBytes = [int64]0; $tempCount = 0
    foreach ($t in @($Data.Temp)) { if ($t) { $tempBytes += $t.Bytes; $tempCount += $t.Count } }
    $browserBytes = [int64]0
    foreach ($b in @($Data.Browser)) { if ($b) { $browserBytes += $b.Bytes } }
    $rbBytes = if ($Data.RecycleBin) { [int64]$Data.RecycleBin.Bytes } else { 0 }
    $doBytes = if ($Data.DeliveryOpt) { [int64]$Data.DeliveryOpt.Bytes } else { 0 }
    $canClean = $tempBytes + $browserBytes + $rbBytes + $doBytes

    $items = @()
    if ($Data.Storage -and $Data.Storage.Items) { $items = @($Data.Storage.Items | ForEach-Object { $_ }) }
    $pending = @($items | Where-Object { $_.Status -eq 'PendingReview' })
    $pendingBytes = [int64]0; foreach ($x in $pending) { $pendingBytes += [int64]$x.SizeBytes }
    $canCleanFiles = @($items | Where-Object { $_.Status -eq 'CanClean' })
    $protItems = @($items | Where-Object { $_.Status -eq 'Protected' })
    $apps = @()
    if ($Data.Apps -and $Data.Apps.Apps) { $apps = @($Data.Apps.Apps | ForEach-Object { $_ }) }
    $appsReview = @($apps | Where-Object { $_.Status -in @('NeedsReview', 'ManualCheck') })
    if (-not $IsResult) { $Script:Stats.EstimatedBytes = $canClean }

    $fmtSize = { param($v, $r) if ($v) { Format-Size ([double]$v) } else { '' } }

    # ---------- HTML ----------
    $h = New-Object System.Text.StringBuilder
    [void]$h.Append("<!doctype html><html lang=`"vi`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>Windows Deep Cleaner</title><style>$(Get-ReportCss)</style></head><body><main>")
    [void]$h.Append("<h1>Windows Deep Cleaner &mdash; $(ConvertTo-Html5Safe $Title)</h1>")
    [void]$h.Append("<div class=`"muted`">$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &middot; May: $(ConvertTo-Html5Safe $env:COMPUTERNAME) &middot; Admin: $(if ($Data.IsAdmin) { 'Co' } else { 'Khong (mot so muc bi gioi han)' }) &middot; Che do: $(ConvertTo-Html5Safe $Data.Mode)</div>")

    [void]$h.Append('<div class="grid">')
    $cards = @(
        @('Dung luong co the don (cache/temp/Recycle Bin)', (Format-Size $canClean)),
        @("File cu hon $($Data.Storage.Days) ngay can xem xet", ('{0:N0} ({1})' -f $pending.Count, (Format-Size $pendingBytes))),
        @('Ung dung can xem xet', ('{0:N0}' -f $appsReview.Count)),
        @('O dia da quet', ('{0}' -f @($Data.Drives).Count))
    )
    if ($IsResult) {
        $cards += , @('Dung luong THUC TE da giai phong', (Format-Size $Script:Stats.FreedBytes))
        $cards += , @('Da xoa / bo qua / loi', ('{0:N0} / {1:N0} / {2:N0}' -f $Script:Stats.Deleted, $Script:Stats.Skipped, $Script:Stats.Errors))
    }
    foreach ($c in $cards) { [void]$h.Append("<div class=`"card`"><div class=`"v`">$(ConvertTo-Html5Safe $c[1])</div><div class=`"k`">$(ConvertTo-Html5Safe $c[0])</div></div>") }
    [void]$h.Append('</div>')
    if ($IsResult) {
        [void]$h.Append("<div class=`"note`">Dung luong du kien (luc quet): <b>$(Format-Size $Script:Stats.EstimatedBytes)</b> &middot; Dung luong thuc te da giai phong: <b>$(Format-Size $Script:Stats.FreedBytes)</b>. File chuyen vao Recycle Bin chi giai phong dung luong sau khi Recycle Bin duoc lam trong.</div>")
    }

    [void]$h.Append('<h2>Nhom trang thai</h2><div class="groups">')
    [void]$h.Append("<div class=`"g g-ok`"><b>Co the don</b>Temp $(Format-Size $tempBytes) ($tempCount file), cache trinh duyet $(Format-Size $browserBytes), Recycle Bin $(Format-Size $rbBytes), Delivery Optimization $(Format-Size $doBytes), file tam rai rac: $($canCleanFiles.Count)</div>")
    [void]$h.Append("<div class=`"g g-warn`"><b>Cho duyet</b>$($pending.Count) file ca nhan/bo cai cu ($(Format-Size $pendingBytes)); $($appsReview.Count) ung dung can xem xet</div>")
    [void]$h.Append("<div class=`"g g-prot`"><b>Duoc bao ve</b>$($Data.Storage.ProtectedCount) thu muc (du lieu ca nhan, ma nguon, backup, database, he thong) + $($protItems.Count) file; $(@($apps | Where-Object Status -eq 'Protected').Count) ung dung he thong/driver/runtime/security</div>")
    [void]$h.Append("<div class=`"g g-skip`"><b>Bi bo qua</b>$($Data.Storage.SkippedCount) muc khong doc duoc / symlink / khong du quyen</div>")
    [void]$h.Append('</div>')
    [void]$h.Append("<div class=`"note`">File khong thay doi trong $($Data.Storage.Days) ngay chi la file <b>cu</b>, khong phai bang chung file khong con can thiet. Ngay cai dat / Last Access khong duoc dung de ket luan ung dung khong con duoc su dung.</div>")

    # O dia
    [void]$h.Append('<h2>O dia</h2>')
    $driveRows = @($Data.Drives | ForEach-Object {
            $ds = if ($Data.Storage) { $Data.Storage.DriveStats | Where-Object Drive -eq $_.Name | Select-Object -First 1 } else { $null }
            [pscustomobject]@{
                Drive = $_.Name; Label = $_.Label; FS = $_.FileSystem
                Size = Format-Size $_.SizeBytes; Free = Format-Size $_.FreeBytes
                OldFiles = $(if ($ds) { '{0:N0}' -f $ds.OldFiles } else { '' })
                OldBytes = $(if ($ds) { Format-Size $ds.OldBytes } else { '' })
                Review = $(if ($ds) { Format-Size $ds.ReviewableBytes } else { '' })
                Seconds = $(if ($ds) { $ds.Seconds } else { '' })
            }
        })
    [void]$h.Append((New-HtmlTable -Rows $driveRows -Columns Drive, Label, FS, Size, Free, OldFiles, OldBytes, Review, Seconds -Headers @{ OldFiles = 'File cu'; OldBytes = 'Dung luong file cu'; Review = 'Co the duyet'; Seconds = 'Thoi gian quet (s)' }))

    # System cleaner
    [void]$h.Append('<h2>System Cleaner</h2>')
    $sysRows = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Data.Temp)) { if ($t) { $sysRows.Add([pscustomobject]@{ Muc = $t.Name; ViTri = $t.Path; SoFile = $t.Count; DungLuong = Format-Size $t.Bytes; ChinhSach = "Tu dong (file cu hon $($Script:Config.Settings.tempFileDays) ngay)" }) } }
    if ($Data.RecycleBin) { $sysRows.Add([pscustomobject]@{ Muc = 'Recycle Bin'; ViTri = '-'; SoFile = $Data.RecycleBin.Count; DungLuong = Format-Size $Data.RecycleBin.Bytes; ChinhSach = 'Xac nhan rieng' }) }
    if ($Data.DeliveryOpt) { $sysRows.Add([pscustomobject]@{ Muc = 'Delivery Optimization'; ViTri = $Data.DeliveryOpt.Path; SoFile = ''; DungLuong = Format-Size $Data.DeliveryOpt.Bytes; ChinhSach = 'Xac nhan rieng (cmdlet chinh thuc)' }) }
    $sysRows.Add([pscustomobject]@{ Muc = 'DISM Component Store'; ViTri = 'WinSxS'; SoFile = ''; DungLuong = 'Khong uoc tinh truoc'; ChinhSach = 'StartComponentCleanup, KHONG dung /ResetBase' })
    [void]$h.Append((New-HtmlTable -Rows $sysRows.ToArray() -Columns Muc, ViTri, SoFile, DungLuong, ChinhSach -Headers @{ Muc = 'Muc'; ViTri = 'Vi tri'; SoFile = 'So file'; DungLuong = 'Dung luong'; ChinhSach = 'Chinh sach' }))

    if (@($Data.Browser).Count -gt 0 -and $Data.Browser[0]) {
        [void]$h.Append('<h2>Cache trinh duyet</h2>')
        $bRows = @($Data.Browser | ForEach-Object { [pscustomobject]@{ Browser = $_.Name; Files = $_.Count; Size = Format-Size $_.Bytes; Running = $(if ($_.Running) { 'Dang chay' } else { '' }) } })
        [void]$h.Append((New-HtmlTable -Rows $bRows -Columns Browser, Files, Size, Running -Headers @{ Running = 'Trang thai' }))
        [void]$h.Append('<p class="muted">Chi xoa thu muc cache. Khong xoa password, cookie, session, bookmarks, history hay profile.</p>')
    }

    # File cu theo nhom
    if ($Data.Storage) {
        [void]$h.Append("<h2>File cu hon $($Data.Storage.Days) ngay theo nhom</h2>")
        $cRows = @($Data.Storage.CategoryStats | Where-Object { $_.Count -gt 0 } | ForEach-Object {
                $ci = $Script:CategoryInfo[$_.Category]
                [pscustomobject]@{ Nhom = $ci.Label; Status = $ci.Status; SoFile = '{0:N0}' -f $_.Count; DungLuong = Format-Size $_.Bytes; LietKe = $_.Listed; ChinhSach = $ci.Policy }
            })
        [void]$h.Append((New-HtmlTable -Rows $cRows -Columns Nhom, Status, SoFile, DungLuong, LietKe, ChinhSach -Headers @{ Nhom = 'Nhom'; SoFile = 'So file'; DungLuong = 'Dung luong'; LietKe = "Liet ke (>= $($Data.Storage.MinSizeMB) MB)"; ChinhSach = 'Chinh sach' }))

        $top = @($items | Where-Object { $_.Status -ne 'Protected' } | Sort-Object SizeBytes -Descending | Select-Object -First $maxRows)
        [void]$h.Append("<h2>Top $($top.Count) file cu lon nhat co the duyet</h2>")
        if ($out.OldFilesCsv) { [void]$h.Append("<p class=`"muted`">Danh sach day du: $(ConvertTo-Html5Safe $out.OldFilesCsv). Dien YES vao cot <b>Delete</b> roi chon menu &quot;Ap dung CSV&quot; de xu ly tung file.</p>") }
        [void]$h.Append((New-HtmlTable -Rows $top -Columns Id, Status, CategoryLabel, SizeBytes, AgeDays, LastWriteTime, Path -Id 'tOld' -Headers @{ CategoryLabel = 'Nhom'; SizeBytes = 'Dung luong'; AgeDays = 'Tuoi (ngay)'; LastWriteTime = 'Last Modified' } -Format @{ SizeBytes = $fmtSize }))

        [void]$h.Append("<h2>Thu muc duoc bao ve / bi bo qua</h2>")
        [void]$h.Append("<details><summary>Duoc bao ve: $($Data.Storage.ProtectedCount) thu muc (hien toi da 300)</summary>")
        [void]$h.Append((New-HtmlTable -Rows @($Data.Storage.ProtectedDirs | Select-Object -First 300) -Columns Path, Reason -Id 'tProt'))
        [void]$h.Append('</details>')
        [void]$h.Append("<details><summary>Bi bo qua: $($Data.Storage.SkippedCount) muc (hien toi da 300)</summary>")
        [void]$h.Append((New-HtmlTable -Rows @($Data.Storage.SkippedDirs | Select-Object -First 300) -Columns Path, Reason -Id 'tSkip'))
        [void]$h.Append('</details>')
    }

    # Ung dung
    if ($apps.Count -gt 0) {
        [void]$h.Append('<h2>Ung dung</h2>')
        if (-not $Data.Apps.PrefetchAvailable) { [void]$h.Append('<div class="note">Khong doc duoc Prefetch (can quyen Admin hoac Prefetch bi tat) nen khong co du lieu su dung tin cay. Khong ung dung nao duoc gan nhan &quot;Can xem xet&quot; dua tren muc do su dung.</div>') }
        $appOrder = @{ NeedsReview = 0; ManualCheck = 1; NoUsageData = 2; InUse = 3; Protected = 4 }
        $aRows = @($apps | Sort-Object @{ e = { $appOrder[$_.Status] } }, Name)
        [void]$h.Append((New-HtmlTable -Rows $aRows -Columns Id, Status, Group, Type, Name, Publisher, Version, InstallDate, SizeBytes, LastUsed, Evidence -Id 'tApps' -Headers @{ SizeBytes = 'Dung luong'; LastUsed = 'Chay cuoi (Prefetch)'; Evidence = 'Danh gia' } -Format @{ SizeBytes = $fmtSize }))
    }

    # Thao tac
    if ($Script:ActionLog.Count -gt 0) {
        [void]$h.Append('<h2>Thao tac da thuc hien</h2>')
        $acts = @($Script:ActionLog | Where-Object { $_.Result -ne 'Deleted' -or $_.Module -notlike 'SystemCleaner/Temp*' } | Select-Object -Last $maxRows)
        $sumRows = @($Script:ActionLog | Group-Object Module, Result | ForEach-Object {
                $b = [int64]0; foreach ($x in $_.Group) { $b += [int64]$x.Bytes }
                [pscustomobject]@{ Module = $_.Group[0].Module; Status = $_.Group[0].Result; SoMuc = $_.Count; DungLuong = Format-Size $b }
            })
        [void]$h.Append((New-HtmlTable -Rows $sumRows -Columns Module, Status, SoMuc, DungLuong -Headers @{ Status = 'Ket qua'; SoMuc = 'So muc'; DungLuong = 'Dung luong' }))
        [void]$h.Append("<details><summary>Chi tiet ($($acts.Count) dong, khong gom tung file temp da xoa)</summary>")
        $actRows = @($acts | ForEach-Object { [pscustomobject]@{ Time = $_.Time; Module = $_.Module; Action = $_.Action; Status = $_.Result; Target = $_.Target; Bytes = $_.Bytes; Detail = $_.Detail } })
        [void]$h.Append((New-HtmlTable -Rows $actRows -Columns Time, Module, Action, Status, Target, Bytes, Detail -Id 'tAct' -Format @{ Bytes = $fmtSize }))
        [void]$h.Append('</details>')
    }

    [void]$h.Append("<p class=`"muted`" style=`"margin-top:32px`">Log: $(ConvertTo-Html5Safe $Script:LogFile)</p>")
    [void]$h.Append(@'
<script>
function filterTable(inp,id){var q=inp.value.toLowerCase();var rows=document.getElementById(id).tBodies[0].rows;
for(var i=0;i<rows.length;i++){rows[i].style.display=rows[i].textContent.toLowerCase().indexOf(q)>-1?'':'none';}}
</script></main></body></html>
'@)

    $out.Html = Join-Path $ReportDir "$($prefix)_report_$ts.html"
    [System.IO.File]::WriteAllText($out.Html, $h.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Log "Bao cao HTML: $($out.Html)" -Level OK
    if ($out.OldFilesCsv) { Write-Log "CSV file cu: $($out.OldFilesCsv)" -Level OK }
    if ($out.AppsCsv) { Write-Log "CSV ung dung: $($out.AppsCsv)" -Level OK }
    return $out
}

function Add-RunHistory {
    param([string]$ReportDir, [object]$Data, [hashtable]$Files, [string]$Mode)
    $histPath = Join-Path $ReportDir 'history.json'
    $hist = @()
    if (Test-Path -LiteralPath $histPath) {
        try { $hist = @(Get-Content -LiteralPath $histPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $hist = @() }
    }
    $entry = [pscustomobject]@{
        Time           = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        Mode           = $Mode
        Drives         = @($Data.Drives | ForEach-Object { $_.Name }) -join ','
        EstimatedBytes = $Script:Stats.EstimatedBytes
        FreedBytes     = $Script:Stats.FreedBytes
        Deleted        = $Script:Stats.Deleted
        Skipped        = $Script:Stats.Skipped
        Errors         = $Script:Stats.Errors
        Report         = $Files.Html
        Log            = $Script:LogFile
    }
    $hist = @($hist) + $entry | Select-Object -Last 100
    ConvertTo-Json -InputObject @($hist) -Depth 4 | Out-File -LiteralPath $histPath -Encoding UTF8
}
