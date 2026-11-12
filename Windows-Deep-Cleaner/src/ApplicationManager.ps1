# =============================================================================
#  ApplicationManager.ps1
#  Liet ke Win32/MSI + Store apps, phan loai, de xuat xem xet, go co xac nhan
# =============================================================================

$Script:AppRules = @{
    Driver   = '(driver|chipset|realtek|nvidia|amd software|radeon|intel\(r\)|intel .*(graphics|management|wireless|bluetooth|serial io|rapid storage|optane)|synaptics|elan|alps|dolby|dts|waves maxx|conexant|qualcomm|broadcom|mediatek|killer|thunderbolt|bluetooth|touchpad|firmware|bios|hp support|dell (update|command|supportassist)|lenovo (vantage|system update)|asus|armoury|msi center|logitech g hub|razer synapse|corsair icue)'
    Runtime  = '(visual c\+\+|redistributable|\.net|dotnet|runtime|framework|directx|webview2|java\(tm\)|java \d|jre|jdk|openjdk|vcredist|xna|silverlight|python \d|node\.js|windows sdk|windows app ?sdk|vclibs|ui\.xaml|desktop ?app ?installer)'
    Security = '(antivirus|anti-virus|security|defender|firewall|vpn|kaspersky|eset|norton|mcafee|bitdefender|avast|avg |avira|malwarebytes|sophos|trend micro|fortinet|forticlient|openvpn|wireguard|cisco (anyconnect|secure)|globalprotect|bitlocker|veracrypt|crowdstrike|sentinel|symantec|webroot|panda|comodo|zonealarm|nordvpn|expressvpn|protonvpn|tailscale|zerotier)'
}
$Script:SystemPublishers = '^(microsoft corporation|microsoft windows|microsoft)$'
$Script:SystemNames = '(^windows |^microsoft (edge|update health|onedrive|gameinput)|update for|security update|hotfix|kb\d{6,}|windows driver package|microsoft edge webview)'

function Get-Win32Apps {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($p in $paths) {
        $entries = @()
        try { $entries = @(Get-ItemProperty -Path $p -ErrorAction SilentlyContinue) } catch { }
        foreach ($e in $entries) {
            $name = [string]$e.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($e.SystemComponent -eq 1) { continue }
            if ($e.ParentKeyName -or $e.ParentDisplayName) { continue }       # ban cap nhat con
            if ([string]$e.ReleaseType -match 'update|hotfix|security') { continue }
            $key = ("{0}|{1}" -f $name, $e.DisplayVersion).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $installDate = $null
            if ([string]$e.InstallDate -match '^\d{8}$') {
                try { $installDate = [datetime]::ParseExact([string]$e.InstallDate, 'yyyyMMdd', $null) } catch { }
            }
            $size = $null
            if ($e.EstimatedSize) { try { $size = [int64]$e.EstimatedSize * 1KB } catch { } }
            $isMsi = ($e.WindowsInstaller -eq 1) -or ($e.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$' -and [string]$e.UninstallString -match 'msiexec')

            $apps.Add([pscustomobject]@{
                    Id              = 0
                    Type            = $(if ($isMsi) { 'MSI' } else { 'Win32' })
                    Name            = $name.Trim()
                    Publisher       = ([string]$e.Publisher).Trim()
                    Version         = [string]$e.DisplayVersion
                    InstallDate     = $(if ($installDate) { $installDate.ToString('yyyy-MM-dd') } else { '' })
                    SizeBytes       = $size
                    InstallLocation = [string]$e.InstallLocation
                    DisplayIcon     = [string]$e.DisplayIcon
                    UninstallString = [string]$e.UninstallString
                    ProductCode     = $(if ($e.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') { $e.PSChildName } else { '' })
                    Scope           = $(if ($p -like 'HKCU*') { 'User' } else { 'Machine' })
                    PackageFullName = ''
                    Group           = ''
                    Status          = ''
                    LastUsed        = ''
                    Evidence        = ''
                })
        }
    }
    return $apps
}

function Get-StoreApps {
    $apps = New-Object System.Collections.Generic.List[object]
    try { $pkgs = @(Get-AppxPackage -ErrorAction Stop) } catch {
        Write-Log "Khong liet ke duoc Store apps: $($_.Exception.Message)" -Level WARN
        return $apps
    }
    foreach ($p in $pkgs) {
        if ($p.IsFramework -or $p.IsResourcePackage -or $p.IsBundle) { continue }
        $nonRemovable = $false
        try { $nonRemovable = [bool]$p.NonRemovable } catch { }
        $sig = [string]$p.SignatureKind
        $publisher = ''
        if ($p.Publisher -match 'O=([^,]+)') { $publisher = $Matches[1].Trim('"') } else { $publisher = [string]$p.Publisher }
        $displayName = $p.Name
        $installDate = ''
        $size = $null
        if ($p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) {
            try { $installDate = (Get-Item -LiteralPath $p.InstallLocation -Force).CreationTime.ToString('yyyy-MM-dd') } catch { }
        }
        $apps.Add([pscustomobject]@{
                Id              = 0
                Type            = 'Store'
                Name            = $displayName
                Publisher       = $publisher
                Version         = [string]$p.Version
                InstallDate     = $installDate
                SizeBytes       = $size
                InstallLocation = [string]$p.InstallLocation
                DisplayIcon     = ''
                UninstallString = "Remove-AppxPackage -Package $($p.PackageFullName)"
                ProductCode     = ''
                Scope           = 'User'
                PackageFullName = $p.PackageFullName
                Group           = $(if ($sig -eq 'System' -or $nonRemovable) { 'System' } else { '' })
                Status          = ''
                LastUsed        = ''
                Evidence        = ''
            })
    }
    return $apps
}

function Get-PrefetchIndex {
    # Map ten exe (lowercase) -> thoi diem chay cuoi (LastWriteTime cua file .pf)
    $idx = @{}
    $pf = Join-Path $env:SystemRoot 'Prefetch'
    try {
        $files = @(Get-ChildItem -LiteralPath $pf -Filter '*.pf' -File -ErrorAction Stop)
        foreach ($f in $files) {
            if ($f.Name -match '^(.+\.exe)-[0-9A-F]{8}\.pf$') {
                $exe = $Matches[1].ToLowerInvariant()
                if (-not $idx.ContainsKey($exe) -or $idx[$exe] -lt $f.LastWriteTime) { $idx[$exe] = $f.LastWriteTime }
            }
        }
    } catch {
        Write-Log 'Khong doc duoc Prefetch (can quyen Admin hoac Prefetch bi tat) - se khong danh gia muc do su dung.' -Level WARN
        return $null
    }
    if ($idx.Count -eq 0) { return $null }
    return $idx
}

function Get-AppExeNames {
    param([object]$App)
    $names = New-Object System.Collections.Generic.List[string]
    $loc = $App.InstallLocation
    if ($loc) { $loc = $loc.Trim('"', ' ') }
    if ($loc -and (Test-Path -LiteralPath $loc -PathType Container)) {
        try {
            Get-ChildItem -LiteralPath $loc -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Select-Object -First 50 | ForEach-Object {
                    if ($_.Name -notmatch '^(unins|uninst|uninstall|setup|install|update|updater|crash|helper|elevat|notif)') { $names.Add($_.Name.ToLowerInvariant()) }
                }
        } catch { }
    }
    if ($App.DisplayIcon -match '([^\\/"]+\.exe)') {
        $n = $Matches[1].ToLowerInvariant()
        if ($n -notmatch '^(unins|uninst|uninstall|setup|msiexec)') { $names.Add($n) }
    }
    return @($names | Select-Object -Unique)
}

function Set-AppClassification {
    param([object]$App, [hashtable]$Prefetch, [int]$InactiveDays)
    $text = ("{0} {1}" -f $App.Name, $App.Publisher).ToLowerInvariant()

    if ($App.Group -eq 'System') { }
    elseif ($text -match $Script:AppRules.Security) { $App.Group = 'Security' }
    elseif ($text -match $Script:AppRules.Runtime) { $App.Group = 'Runtime' }
    elseif ($text -match $Script:AppRules.Driver) { $App.Group = 'Driver' }
    elseif ($App.Name -match $Script:SystemNames -or ($App.Type -eq 'Store' -and $App.Publisher -match '^Microsoft Corporation$' -and $App.Name -match '^Microsoft\.(Windows|UI|VCLibs|NET|Services|Xbox(GameOverlay|IdentityProvider|SpeechToText)|AAD|Advertising|Desktop|Sec|LockApp|ECApp|Win32WebViewHost|BioEnrollment|CredDialogHost|AccountsControl)')) { $App.Group = 'System' }
    elseif ([string]::IsNullOrWhiteSpace($App.Publisher)) { $App.Group = 'UnknownPublisher' }
    else { $App.Group = 'User' }

    switch ($App.Group) {
        'System' { $App.Status = 'Protected'; $App.Evidence = 'Ung dung he thong - khong tu go' }
        'Driver' { $App.Status = 'Protected'; $App.Evidence = 'Driver/phan mem phan cung - bao ve' }
        'Runtime' { $App.Status = 'Protected'; $App.Evidence = 'Runtime/framework - bao ve mac dinh' }
        'Security' { $App.Status = 'Protected'; $App.Evidence = 'Security/antivirus/VPN - bao ve mac dinh' }
        'UnknownPublisher' { $App.Status = 'ManualCheck'; $App.Evidence = 'Khong ro publisher - can kiem tra thu cong' }
        default { $App.Status = 'NoUsageData'; $App.Evidence = 'Ung dung nguoi dung - khong du du lieu su dung tin cay' }
    }

    # Danh gia muc do su dung CHI khi co bang chung Prefetch (dau vet thuc thi do Windows ghi)
    if ($Prefetch -and $App.Type -ne 'Store') {
        $exes = Get-AppExeNames $App
        $last = $null; $hit = $null
        foreach ($x in $exes) {
            if ($Prefetch.ContainsKey($x) -and (-not $last -or $Prefetch[$x] -gt $last)) { $last = $Prefetch[$x]; $hit = $x }
        }
        if ($last) {
            $App.LastUsed = $last.ToString('yyyy-MM-dd')
            $age = [int]((Get-Date) - $last).TotalDays
            if ($App.Status -in @('NoUsageData', 'ManualCheck')) {
                if ($age -ge $InactiveDays) {
                    $App.Status = 'NeedsReview'
                    $App.Evidence = "Prefetch: lan chay cuoi cua $hit cach day $age ngay (>= $InactiveDays). Can nguoi dung xac nhan."
                } else {
                    $App.Status = 'InUse'
                    $App.Evidence = "Prefetch: $hit chay gan day ($age ngay truoc)"
                }
            }
        }
    }
}

function Invoke-AppScan {
    param([int]$InactiveDays = 180)
    Write-Log 'Liet ke ung dung Win32/MSI va Microsoft Store...' -Level INFO
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($a in Get-Win32Apps) { $all.Add($a) }
    foreach ($a in Get-StoreApps) { $all.Add($a) }
    $prefetch = Get-PrefetchIndex
    $i = 0
    foreach ($a in ($all | Sort-Object Name)) {
        $i++
        $a.Id = $i
        Set-AppClassification -App $a -Prefetch $prefetch -InactiveDays $InactiveDays
    }
    $sorted = @($all | Sort-Object Id)
    Write-Log ("  {0} ung dung; can xem xet: {1}; khong ro publisher: {2}; duoc bao ve: {3}" -f $sorted.Count,
        @($sorted | Where-Object Status -eq 'NeedsReview').Count,
        @($sorted | Where-Object Status -eq 'ManualCheck').Count,
        @($sorted | Where-Object Status -eq 'Protected').Count)
    return [pscustomobject]@{ Apps = $sorted; PrefetchAvailable = [bool]$prefetch }
}

# -------------------------------------------------------------- Uninstall ----
function Split-CommandLine {
    # Tach "C:\path\app.exe" /args  ->  @{ Exe; Args }
    param([string]$Cmd)
    $Cmd = $Cmd.Trim()
    if ($Cmd.StartsWith('"')) {
        $end = $Cmd.IndexOf('"', 1)
        if ($end -lt 0) { return $null }
        return @{ Exe = $Cmd.Substring(1, $end - 1); Args = $Cmd.Substring($end + 1).Trim() }
    }
    $m = [regex]::Match($Cmd, '^(.+?\.exe)(\s+.*)?$', 'IgnoreCase')
    if ($m.Success) { return @{ Exe = $m.Groups[1].Value; Args = $m.Groups[2].Value.Trim() } }
    return $null
}

function Get-UninstallPlan {
    param([object]$App)
    if ($App.Type -eq 'Store') {
        return @{ Kind = 'Appx'; Display = "Remove-AppxPackage -Package $($App.PackageFullName)" }
    }
    if ($App.ProductCode -and ($App.Type -eq 'MSI' -or $App.UninstallString -match 'msiexec')) {
        return @{ Kind = 'Msi'; Exe = "$env:SystemRoot\System32\msiexec.exe"; Args = "/x $($App.ProductCode)"; Display = "msiexec.exe /x $($App.ProductCode)" }
    }
    if (-not $App.UninstallString) { return @{ Kind = 'None'; Reason = 'Khong co UninstallString' } }
    $sp = Split-CommandLine ([Environment]::ExpandEnvironmentVariables($App.UninstallString))
    if (-not $sp) { return @{ Kind = 'None'; Reason = "Khong phan tich duoc lenh: $($App.UninstallString)" } }
    if (-not (Test-Path -LiteralPath $sp.Exe -PathType Leaf)) { return @{ Kind = 'None'; Reason = "Trinh go cai dat khong ton tai: $($sp.Exe)" } }
    $exeN = ConvertTo-NormalPath $sp.Exe
    foreach ($bad in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'), "$env:USERPROFILE\Downloads")) {
        if ($bad -and (Test-PathUnder $exeN (ConvertTo-NormalPath $bad))) { return @{ Kind = 'None'; Reason = "Trinh go cai dat nam o vi tri khong tin cay: $($sp.Exe)" } }
    }
    return @{ Kind = 'Exe'; Exe = $sp.Exe; Args = $sp.Args; Display = $App.UninstallString }
}

function Invoke-AppUninstall {
    param([object]$App)
    if ($App.Status -eq 'Protected') {
        Write-Log "Tu choi go ung dung duoc bao ve: $($App.Name) ($($App.Group))" -Level WARN
        Add-ActionRecord 'ApplicationManager' 'Uninstall' $App.Name 'Skipped' 0 'Ung dung duoc bao ve'
        return
    }
    $plan = Get-UninstallPlan $App
    Write-Host ''
    Write-Host "Ung dung   : $($App.Name)" -ForegroundColor Cyan
    Write-Host "Publisher  : $($App.Publisher)"
    Write-Host "Version    : $($App.Version)"
    Write-Host "Dung luong : $(if ($App.SizeBytes) { Format-Size $App.SizeBytes } else { 'khong ro' })"
    Write-Host "Lan dung cuoi (Prefetch): $(if ($App.LastUsed) { $App.LastUsed } else { 'khong co du lieu' })"
    Write-Host "Danh gia   : $($App.Evidence)"
    if ($plan.Kind -eq 'None') {
        Write-Log "Khong the go $($App.Name): $($plan.Reason)" -Level WARN
        Add-ActionRecord 'ApplicationManager' 'Uninstall' $App.Name 'Skipped' 0 $plan.Reason
        return
    }
    Write-Host "Phuong thuc: $($plan.Display)"
    if (-not (Confirm-Action "Go cai dat '$($App.Name)' bang trinh go chinh thuc?")) {
        Add-ActionRecord 'ApplicationManager' 'Uninstall' $App.Name 'Cancelled' 0
        return
    }
    try {
        switch ($plan.Kind) {
            'Appx' { Remove-AppxPackage -Package $App.PackageFullName -ErrorAction Stop; $code = 0 }
            default {
                $sp = @{ FilePath = $plan.Exe; Wait = $true; PassThru = $true }
                if ($plan.Args) { $sp.ArgumentList = $plan.Args }
                $proc = Start-Process @sp
                $code = $proc.ExitCode
            }
        }
        if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) {
            Write-Log "Da go: $($App.Name) (exit $code$(if ($code -ne 0) { ' - can khoi dong lai' }))" -Level OK
            Add-ActionRecord 'ApplicationManager' 'Uninstall' $App.Name 'Done' ([int64]$App.SizeBytes) "Exit $code"
        } else {
            $Script:Stats.Errors++
            Write-Log "Trinh go cai dat $($App.Name) tra ve ma $code (co the nguoi dung da huy)" -Level WARN
            Add-ActionRecord 'ApplicationManager' 'Uninstall' $App.Name 'Error' 0 "Exit $code"
        }
    } catch {
        $Script:Stats.Errors++
        Write-Log "Loi khi go $($App.Name): $($_.Exception.Message)" -Level ERROR
        Add-ActionRecord 'ApplicationManager' 'Uninstall' $App.Name 'Error' 0 $_.Exception.Message
    }
}

function Invoke-AppReviewMenu {
    param([object]$AppScan)
    $cands = @($AppScan.Apps | Where-Object { $_.Status -in @('NeedsReview', 'ManualCheck', 'NoUsageData', 'InUse') })
    if ($cands.Count -eq 0) { Write-Host 'Khong co ung dung nao co the go.' -ForegroundColor Gray; return }
    $order = @{ NeedsReview = 0; ManualCheck = 1; NoUsageData = 2; InUse = 3 }
    $cands = @($cands | Sort-Object @{ e = { $order[$_.Status] } }, Name)
    Write-Host ''
    Write-Host '--- Ung dung co the go (ung dung he thong/driver/runtime/security da bi an) ---' -ForegroundColor Cyan
    Write-Host 'NeedsReview = co bang chung Prefetch khong chay lau ngay; NoUsageData = khong du du lieu (KHONG co nghia la khong dung)' -ForegroundColor DarkGray
    $cands | Format-Table Id, Status, Name, Publisher, Version, LastUsed, @{n = 'Size'; e = { if ($_.SizeBytes) { Format-Size $_.SizeBytes } else { '' } } } -AutoSize | Out-Host
    $raw = Read-Host 'Nhap Id ung dung muon go (cach nhau boi dau phay), Enter de bo qua'
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $ids = @($raw -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $selected = @($cands | Where-Object { $ids -contains $_.Id })
    if ($selected.Count -eq 0) { Write-Host 'Khong co Id hop le.' -ForegroundColor Yellow; return }
    Write-Host "Da chon $($selected.Count) ung dung. Moi ung dung se duoc xac nhan rieng." -ForegroundColor Yellow
    foreach ($a in $selected) { Invoke-AppUninstall $a }
}
