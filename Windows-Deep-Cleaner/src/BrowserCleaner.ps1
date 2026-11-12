# =============================================================================
#  BrowserCleaner.ps1
#  Chi don thu muc CACHE. Khong dong vao password/cookie/session/history/profile.
# =============================================================================

function Get-BrowserDefinitions {
    $local = $env:LOCALAPPDATA
    return @(
        @{ Name = 'Google Chrome';  Process = 'chrome';  Type = 'Chromium'; UserData = Join-Path $local 'Google\Chrome\User Data' }
        @{ Name = 'Microsoft Edge'; Process = 'msedge';  Type = 'Chromium'; UserData = Join-Path $local 'Microsoft\Edge\User Data' }
        @{ Name = 'Brave';          Process = 'brave';   Type = 'Chromium'; UserData = Join-Path $local 'BraveSoftware\Brave-Browser\User Data' }
        @{ Name = 'Vivaldi';        Process = 'vivaldi'; Type = 'Chromium'; UserData = Join-Path $local 'Vivaldi\User Data' }
        @{ Name = 'Opera';          Process = 'opera';   Type = 'ChromiumFlat'; UserData = Join-Path $local 'Opera Software\Opera Stable' }
        @{ Name = 'Mozilla Firefox'; Process = 'firefox'; Type = 'Firefox'; UserData = Join-Path $local 'Mozilla\Firefox\Profiles' }
    )
}

function Get-BrowserCacheDirs {
    param([hashtable]$Browser)
    $dirs = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Browser.UserData)) { return $dirs }
    # Chi cac thu muc cache da biet - KHONG xoa ca profile
    $chromiumCache = @('Cache\Cache_Data', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache')
    switch ($Browser.Type) {
        'Chromium' {
            $profiles = @(Get-ChildItem -LiteralPath $Browser.UserData -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' -or $_.Name -eq 'Guest Profile' })
            foreach ($p in $profiles) {
                foreach ($c in $chromiumCache) {
                    $d = Join-Path $p.FullName $c
                    if (Test-Path -LiteralPath $d -PathType Container) { $dirs.Add($d) }
                }
            }
            foreach ($c in @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache')) {
                $d = Join-Path $Browser.UserData $c
                if (Test-Path -LiteralPath $d -PathType Container) { $dirs.Add($d) }
            }
        }
        'ChromiumFlat' {
            foreach ($c in $chromiumCache) {
                $d = Join-Path $Browser.UserData $c
                if (Test-Path -LiteralPath $d -PathType Container) { $dirs.Add($d) }
            }
        }
        'Firefox' {
            foreach ($p in @(Get-ChildItem -LiteralPath $Browser.UserData -Directory -ErrorAction SilentlyContinue)) {
                foreach ($c in @('cache2', 'startupCache', 'jumpListCache', 'thumbnails')) {
                    $d = Join-Path $p.FullName $c
                    if (Test-Path -LiteralPath $d -PathType Container) { $dirs.Add($d) }
                }
            }
        }
    }
    return $dirs
}

function Invoke-BrowserCacheScan {
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($b in Get-BrowserDefinitions) {
        $dirs = @(Get-BrowserCacheDirs $b)
        if ($dirs.Count -eq 0) { continue }
        $bytes = [int64]0; $count = 0
        foreach ($d in $dirs) {
            $files = Get-SafeFiles -Root $d
            foreach ($f in $files) { $bytes += $f.Length; $count++ }
        }
        $running = [bool](Get-Process -Name $b.Process -ErrorAction SilentlyContinue)
        $result.Add([pscustomobject]@{
                Name      = $b.Name
                Process   = $b.Process
                CacheDirs = $dirs
                Count     = $count
                Bytes     = $bytes
                Running   = $running
            })
        Write-Log ("  {0}: cache {1} ({2} file){3}" -f $b.Name, (Format-Size $bytes), $count, $(if ($running) { ' - DANG CHAY' } else { '' }))
    }
    return $result
}

function Invoke-BrowserCacheCleanup {
    param([object[]]$Scan)
    foreach ($b in $Scan) {
        if ($b.Bytes -eq 0) { continue }
        if (-not (Confirm-Action ("Don cache {0} ({1})?" -f $b.Name, (Format-Size $b.Bytes)))) { continue }
        if (Get-Process -Name $b.Process -ErrorAction SilentlyContinue) {
            Write-Host "$($b.Name) dang chay. Hay dong trinh duyet (khong tu dong tat), sau do nhan Enter." -ForegroundColor Yellow
            [void](Read-Host)
            if (Get-Process -Name $b.Process -ErrorAction SilentlyContinue) {
                Write-Log "$($b.Name) van dang chay - bo qua de tranh hong du lieu." -Level WARN
                Add-ActionRecord 'BrowserCleaner' 'CleanCache' $b.Name 'Skipped' 0 'Trinh duyet dang chay'
                $Script:Stats.Skipped++
                continue
            }
        }
        $before = $Script:Stats.FreedBytes
        foreach ($d in $b.CacheDirs) {
            $files = Get-SafeFiles -Root $d
            foreach ($f in $files) {
                [void](Remove-SafeFile -Path $f.FullName -AllowedRoots @($d) -Module "BrowserCleaner/$($b.Name)")
            }
        }
        Write-Log ("{0}: da giai phong {1}" -f $b.Name, (Format-Size ($Script:Stats.FreedBytes - $before))) -Level OK
    }
}
