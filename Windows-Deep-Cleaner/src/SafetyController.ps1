# =============================================================================
#  SafetyController.ps1
#  Config, logging, protected paths, safe enumeration, safe deletion
# =============================================================================

$Script:LogFile = $null
$Script:Config = $null
$Script:ProtectedPrefixes = @()
$Script:ProtectedWildcards = @()
$Script:ProtectedNameRegex = @()
$Script:ProjectMarkers = @{}
$Script:ProjectMarkerExt = @{}
$Script:SafeDirCache = @{}   # thu muc da xac minh khong phai reparse point

# Thong ke thao tac (dung cho bao cao ket qua)
$Script:Stats = [ordered]@{
    Deleted        = 0
    Skipped        = 0
    Errors         = 0
    FreedBytes     = [int64]0
    EstimatedBytes = [int64]0
}
$Script:ActionLog = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- Logging ----
function Initialize-Log {
    param([string]$LogDir)
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $Script:LogFile = Join-Path $LogDir ("cleanup_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    "Windows Deep Cleaner log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $Script:LogFile -Encoding UTF8
    return $Script:LogFile
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION', 'SKIP', 'OK')][string]$Level = 'INFO',
        [switch]$Quiet
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Script:LogFile) {
        try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    if (-not $Quiet) {
        $color = switch ($Level) {
            'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'ACTION' { 'Cyan' } 'OK' { 'Green' } 'SKIP' { 'DarkGray' } default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Add-ActionRecord {
    param([string]$Module, [string]$Action, [string]$Target, [string]$Result, [int64]$Bytes = 0, [string]$Detail = '')
    $Script:ActionLog.Add([pscustomobject]@{
            Time   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Module = $Module
            Action = $Action
            Target = $Target
            Result = $Result
            Bytes  = $Bytes
            Detail = $Detail
        })
}

# ----------------------------------------------------------------- Config ----
function Expand-ConfigPath {
    param([string]$Path)
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if ($p -match '%[^%]+%') { return $null }   # bien moi truong khong ton tai
    return $p
}

function ConvertTo-NormalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    $t = $full.TrimEnd('\', '/')
    if (-not $t) { $t = $full }
    return $t.ToLowerInvariant()
}

function Test-PathUnder {
    # True neu $Path nam trong (hoac bang) $Root. Ca hai da normalize.
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    return ($Path -eq $Root) -or $Path.StartsWith($Root + $sep)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Khong tim thay file cau hinh: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Initialize-Safety {
    param([string]$ConfigDir)

    $settings = Read-JsonFile (Join-Path $ConfigDir 'settings.json')
    $excl = Read-JsonFile (Join-Path $ConfigDir 'exclusions.json')
    $Script:Config = [pscustomobject]@{ Settings = $settings; Exclusions = $excl }

    $prefixes = New-Object System.Collections.Generic.List[string]
    $wild = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $excl.protectedPaths) {
        $p = Expand-ConfigPath $raw
        if (-not $p) { continue }
        if ($p.Contains('*')) { $wild.Add(($p.TrimEnd('\').ToLowerInvariant())) }
        else { $n = ConvertTo-NormalPath $p; if ($n) { $prefixes.Add($n) } }
    }

    # Known folders cua user hien tai (ke ca khi bi redirect sang o khac)
    foreach ($kf in 'Desktop', 'MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic', 'UserProfile') {
        try {
            $kp = [Environment]::GetFolderPath($kf)
            if ($kp -and $kf -ne 'UserProfile') { $prefixes.Add((ConvertTo-NormalPath $kp)) }
        } catch { }
    }
    try {
        $dl = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($dl) { $prefixes.Add((ConvertTo-NormalPath $dl)) }
    } catch { }

    $Script:ProtectedPrefixes = @($prefixes | Where-Object { $_ } | Select-Object -Unique)
    $Script:ProtectedWildcards = @($wild | Select-Object -Unique)
    $Script:ProtectedNameRegex = @($excl.protectedFolderNamePatterns | ForEach-Object {
            New-Object System.Text.RegularExpressions.Regex($_, 'IgnoreCase, Compiled')
        })
    $Script:ProjectMarkers = @{}
    foreach ($m in $excl.projectMarkers) { $Script:ProjectMarkers[$m.ToLowerInvariant()] = $true }
    $Script:ProjectMarkerExt = @{}
    foreach ($m in $excl.projectMarkerExtensions) { $Script:ProjectMarkerExt[$m.ToLowerInvariant()] = $true }

    return $Script:Config
}

# ------------------------------------------------------------- Protection ----
function Test-ProtectedPath {
    # Tra ve ly do (string) neu duong dan duoc bao ve, nguoc lai $null
    param([string]$Path)
    $n = ConvertTo-NormalPath $Path
    if (-not $n) { return 'Duong dan khong hop le' }
    foreach ($p in $Script:ProtectedPrefixes) {
        if (Test-PathUnder $n $p) { return "Protected path: $p" }
    }
    foreach ($w in $Script:ProtectedWildcards) {
        # So khop tung tien to cua duong dan voi mau wildcard
        $parts = $n.Split('\')
        $acc = ''
        for ($i = 0; $i -lt $parts.Length; $i++) {
            $acc = if ($i -eq 0) { $parts[0] } else { "$acc\$($parts[$i])" }
            if ($acc -like $w) { return "Protected path: $w" }
        }
    }
    # Kiem tra ten tung thu muc tren duong dan (bo qua ten o dia)
    $segs = $n.Split('\')
    for ($i = 1; $i -lt $segs.Length - 1; $i++) {
        $r = Test-ProtectedFolderName $segs[$i]
        if ($r) { return $r }
    }
    return $null
}

function Test-ProtectedFolderName {
    param([string]$Name)
    foreach ($rx in $Script:ProtectedNameRegex) {
        if ($rx.IsMatch($Name)) { return "Protected folder name: $Name (pattern '$($rx.ToString())')" }
    }
    return $null
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-ReparseInChain {
    # Kiem tra item va cac thu muc cha (den RootStop) co phai symlink/junction khong
    param([string]$Path, [string]$RootStop)
    $rootN = ConvertTo-NormalPath $RootStop
    $cur = $Path
    $verified = New-Object System.Collections.Generic.List[string]
    while ($cur) {
        $curKey = ConvertTo-NormalPath $cur
        if ($cur -ne $Path -and $Script:SafeDirCache.ContainsKey($curKey)) { break }
        if ($cur -ne $Path) { $verified.Add($curKey) }
        try {
            $info = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
            if (Test-IsReparsePoint $info) { return $true }
        } catch { return $true }   # khong doc duoc => coi nhu khong an toan
        $curN = ConvertTo-NormalPath $cur
        if ($rootN -and $curN -eq $rootN) { break }
        $parent = Split-Path -Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    foreach ($v in $verified) { $Script:SafeDirCache[$v] = $true }
    return $false
}

function Test-IsProjectDirectory {
    # $Children: mang FileSystemInfo da liet ke cua thu muc
    param([object[]]$Children)
    foreach ($c in $Children) {
        $nm = $c.Name.ToLowerInvariant()
        if ($Script:ProjectMarkers.ContainsKey($nm)) { return $c.Name }
        $ext = [System.IO.Path]::GetExtension($nm)
        if ($ext -and $Script:ProjectMarkerExt.ContainsKey($ext)) { return $c.Name }
    }
    return $null
}

# ------------------------------------------------------- Safe enumeration ----
function Get-SafeFiles {
    <#
      Duyet thu muc KHONG di theo symlink/junction.
      -RespectProtection: bo qua protected paths / ten thu muc / thu muc du an
      -OnProtected: scriptblock nhan (path, reason) khi gap thu muc duoc bao ve
      -OnSkipped: scriptblock nhan (path, reason) khi khong doc duoc
      Tra ve List[System.IO.FileInfo]
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$RespectProtection,
        [scriptblock]$OnProtected,
        [scriptblock]$OnSkipped,
        [scriptblock]$FileFilter
    )
    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    try { $stack.Push((New-Object System.IO.DirectoryInfo($Root))) } catch { return , $result }

    $count = 0
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $children = @($dir.EnumerateFileSystemInfos()) }
        catch {
            if ($OnSkipped) { & $OnSkipped $dir.FullName $_.Exception.Message }
            continue
        }

        if ($RespectProtection) {
            $marker = Test-IsProjectDirectory $children
            if ($marker) {
                if ($OnProtected) { & $OnProtected $dir.FullName "Thu muc du an/ma nguon (co '$marker')" }
                continue
            }
        }

        foreach ($c in $children) {
            if (Test-IsReparsePoint $c) {
                if ($OnSkipped) { & $OnSkipped $c.FullName 'Symbolic link / junction - khong di theo' }
                continue
            }
            if ($c -is [System.IO.DirectoryInfo]) {
                if ($RespectProtection) {
                    $reason = Test-ProtectedFolderName $c.Name
                    if (-not $reason) {
                        $n = ConvertTo-NormalPath $c.FullName
                        foreach ($p in $Script:ProtectedPrefixes) { if (Test-PathUnder $n $p) { $reason = "Protected path: $p"; break } }
                        if (-not $reason) {
                            foreach ($w in $Script:ProtectedWildcards) { if ($n -like $w) { $reason = "Protected path: $w"; break } }
                        }
                    }
                    if ($reason) {
                        if ($OnProtected) { & $OnProtected $c.FullName $reason }
                        continue
                    }
                }
                $stack.Push($c)
            } else {
                $count++
                if (($count % 20000) -eq 0) {
                    Write-Progress -Activity "Dang quet $Root" -Status "$count file - $($dir.FullName)"
                }
                if (-not $FileFilter -or (& $FileFilter $c)) { $result.Add($c) }
            }
        }
    }
    Write-Progress -Activity "Dang quet $Root" -Completed
    return , $result
}

# ---------------------------------------------------------- Safe deletion ----
function Test-SafeDeleteTarget {
    <#
      Kiem tra truoc khi xoa. Tra ve $null neu an toan, nguoc lai ly do.
      -AllowedRoots: duong dan dich PHAI nam ben trong mot trong cac root nay
      -CheckProtection: ap dung protected paths (dung cho file nguoi dung)
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [switch]$CheckProtection
    )
    $n = ConvertTo-NormalPath $Path
    if (-not $n) { return 'Duong dan khong hop le' }
    $root = $null
    foreach ($r in $AllowedRoots) {
        $rn = ConvertTo-NormalPath $r
        if ($rn -and $n -ne $rn -and (Test-PathUnder $n $rn)) { $root = $r; break }
    }
    if (-not $root) { return 'Nam ngoai pham vi cho phep' }
    if ($CheckProtection) {
        $pr = Test-ProtectedPath $Path
        if ($pr) { return $pr }
    }
    if (-not (Test-Path -LiteralPath $Path)) { return 'Khong con ton tai' }
    if (Test-ReparseInChain -Path $Path -RootStop $root) { return 'Co symbolic link/junction tren duong dan' }
    return $null
}

function Remove-SafeFile {
    <#
      Xoa mot file sau khi kiem tra an toan. Khong bao gio throw.
      -ToRecycleBin: dua vao Recycle Bin thay vi xoa vinh vien
      Tra ve: 'Deleted' | 'Skipped' | 'Error'
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [string]$Module = 'General',
        [switch]$CheckProtection,
        [switch]$ToRecycleBin
    )
    $why = Test-SafeDeleteTarget -Path $Path -AllowedRoots $AllowedRoots -CheckProtection:$CheckProtection
    if ($why) {
        $Script:Stats.Skipped++
        Write-Log "Bo qua: $Path - $why" -Level SKIP -Quiet
        Add-ActionRecord $Module 'Delete' $Path 'Skipped' 0 $why
        return 'Skipped'
    }
    $size = [int64]0
    try { $size = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length } catch { }
    try {
        if ($ToRecycleBin) {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        } else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        $Script:Stats.Deleted++
        $Script:Stats.FreedBytes += $size
        Write-Log "Da xoa: $Path ($([math]::Round($size/1MB,2)) MB)" -Level ACTION -Quiet
        Add-ActionRecord $Module ($(if ($ToRecycleBin) { 'RecycleBin' } else { 'Delete' })) $Path 'Deleted' $size
        return 'Deleted'
    } catch {
        $msg = $_.Exception.Message
        # File dang khoa / khong du quyen => bo qua, khong coi la loi nghiem trong
        if ($_.Exception -is [System.IO.IOException] -or $_.Exception -is [System.UnauthorizedAccessException] -or
            $msg -match 'being used|access.*denied|bi tu choi|dang duoc su dung') {
            $Script:Stats.Skipped++
            Write-Log "Bo qua (dang khoa/khong du quyen): $Path - $msg" -Level SKIP -Quiet
            Add-ActionRecord $Module 'Delete' $Path 'Skipped' 0 $msg
            return 'Skipped'
        }
        $Script:Stats.Errors++
        Write-Log "Loi khi xoa $Path - $msg" -Level ERROR -Quiet
        Add-ActionRecord $Module 'Delete' $Path 'Error' 0 $msg
        return 'Error'
    }
}

function Remove-EmptyDirectories {
    # Xoa thu muc rong ben trong Root (khong xoa Root), khong di theo reparse point
    param([string]$Root, [string]$Module = 'General')
    try {
        $dirs = Get-SafeDirectories -Root $Root
        foreach ($d in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
            try {
                if (-not ($d.EnumerateFileSystemInfos() | Select-Object -First 1)) {
                    $d.Delete($false)
                    Write-Log "Da xoa thu muc rong: $($d.FullName)" -Level ACTION -Quiet
                }
            } catch { }
        }
    } catch { }
}

function Get-SafeDirectories {
    param([string]$Root)
    $result = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    try { $stack.Push((New-Object System.IO.DirectoryInfo($Root))) } catch { return , $result }
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            foreach ($c in $d.EnumerateDirectories()) {
                if (Test-IsReparsePoint $c) { continue }
                $result.Add($c); $stack.Push($c)
            }
        } catch { }
    }
    return , $result
}

# ------------------------------------------------------------ Environment ----
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FixedDrives {
    param([string[]]$Only)
    $drives = @()
    try {
        $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name       = $_.DeviceID
                    Root       = "$($_.DeviceID)\"
                    Label      = $_.VolumeName
                    FileSystem = $_.FileSystem
                    SizeBytes  = [int64]$_.Size
                    FreeBytes  = [int64]$_.FreeSpace
                }
            })
    } catch {
        $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name.TrimEnd('\'); Root = $_.Name; Label = $_.VolumeLabel; FileSystem = $_.DriveFormat
                    SizeBytes = [int64]$_.TotalSize; FreeBytes = [int64]$_.AvailableFreeSpace
                }
            })
    }
    $drives = @($drives | Where-Object { $_.SizeBytes -gt 0 -and (Test-Path -LiteralPath $_.Root) })
    if ($Only -and $Only.Count -gt 0) {
        $want = $Only | ForEach-Object { $_.TrimEnd('\', ':').ToUpperInvariant() + ':' }
        $drives = @($drives | Where-Object { $want -contains $_.Name.ToUpperInvariant() })
    }
    return $drives
}

# ------------------------------------------------------------ Interaction ----
function Confirm-Action {
    param([string]$Message, [switch]$StrongConfirm)
    if ($Script:NonInteractive) { return $false }
    if ($StrongConfirm) {
        $ans = Read-Host "$Message`nGo 'XOA' de xac nhan (bat ky gia tri khac = huy)"
        return ($ans -ceq 'XOA')
    }
    $ans = Read-Host "$Message [y/N]"
    return ($ans -match '^(y|yes|c|co)$')
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$([int64]$Bytes) B"
}
