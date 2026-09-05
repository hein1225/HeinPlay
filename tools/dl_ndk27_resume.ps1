# Robust resume download via System.Net.HttpClient streaming + Range + retry
$ErrorActionPreference = 'Stop'
$zip = "D:\AndroidSDK\ndk\_dl_ndk27_full.zip"
$url = "https://dl.google.com/android/repository/android-ndk-r27b-windows.zip"

Add-Type -AssemblyName System.Net.Http

function Get-RemoteLength {
    $h = [System.Net.Http.HttpClient]::new()
    $h.Timeout = [TimeSpan]::FromMinutes(2)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $url)
        $resp = $h.SendAsync($req).GetAwaiter().GetResult()
        return [long]$resp.Content.Headers.ContentLength
    } finally { $h.Dispose() }
}

if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
$remote = Get-RemoteLength
Write-Host ">> server Content-Length: $remote"

$maxAttempts = 40
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $have = 0L
    if (Test-Path $zip) { $have = (Get-Item $zip).Length }
    Write-Host ">> [$attempt/$maxAttempts] have: $([math]::Round($have/1MB,1)) MB / $([math]::Round($remote/1MB,1)) MB"
    if ($have -ge $remote) { Write-Host ">> complete"; break }

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    try {
        $msg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
        $msg.Headers.UserAgent.ParseAdd("Mozilla/5.0")
        if ($have -gt 0) {
            $msg.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($have, $null)
            Write-Host ">> resume from $have"
        }
        $resp = $client.SendAsync($msg, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { Write-Host ">> HTTP $($resp.StatusCode)"; Start-Sleep 5; continue }
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $isPartial = ($resp.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
        if ($isPartial -and $have -gt 0) {
            $mode = [System.IO.FileMode]::Append
            Write-Host ">> 206 partial, append"
        } else {
            $mode = [System.IO.FileMode]::Create
            Write-Host ">> 200 full, create"
        }
        $fs = [System.IO.File]::Open($zip, $mode)
        $buf = New-Object byte[] 1048576
        $total = $have
        $ok = $true
        try {
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $fs.Write($buf, 0, $n)
                $total += $n
            }
        } catch {
            Write-Host ">> stream interrupted: $($_.Exception.Message)"
            $ok = $false
            Start-Sleep 3
        } finally {
            $fs.Close()
            $stream.Dispose()
            if ($resp) { $resp.Dispose() }
        }
        $after = (Get-Item $zip).Length
        Write-Host ">> after this round: $([math]::Round($after/1MB,1)) MB"
        if ($after -ge $remote) { Write-Host ">> download done"; break }
    } finally { $client.Dispose() }
}

$final = (Get-Item $zip).Length
Write-Host ">> final: $final ($([math]::Round($final/1MB,1)) MB) / remote $remote"
if ($final -ge $remote -and $final -gt 500MB) { Write-Host "NDK27_DOWNLOAD_OK size=$final" }
else { Write-Host "NDK27_DOWNLOAD_INCOMPLETE size=$final"; exit 1 }
