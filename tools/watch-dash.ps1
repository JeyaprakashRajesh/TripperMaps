# Shows the TripperMaps test stream on this PC (run in PowerShell from the project folder).
# Needs ffplay: winget install Gyan.FFmpeg   (or open tools\dash-preview.sdp in VLC instead)

# The real LAN address is the one on the adapter that has a default gateway (your router).
# Virtual adapters (WSL, Hyper-V, VPNs) have none, so they're skipped.
$lan = Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.InterfaceAlias -notmatch 'vEthernet|WSL|Hyper-V|VirtualBox|VMware|Loopback' } |
    Select-Object -First 1
if ($lan) {
    $ip = $lan.IPv4Address.IPAddress
    Write-Host "Type this IP into the app's 'PC IP address' field: $ip   (adapter: $($lan.InterfaceAlias))" -ForegroundColor Yellow
} else {
    Write-Host "Couldn't find a Wi-Fi/Ethernet adapter with a router. All IPv4 addresses:" -ForegroundColor Yellow
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)' } |
        Format-Table InterfaceAlias, IPAddress -AutoSize
}
if ($lan -and $lan.InterfaceAlias -match 'Apple|iPhone|Ethernet [0-9]') {
    Write-Host "Heads-up: this looks like iPhone USB tethering. Use the same Wi-Fi router for both instead." -ForegroundColor Red
}
Write-Host "If nothing shows, allow UDP 5000 once (admin PowerShell):"
Write-Host '  New-NetFirewallRule -DisplayName "TripperMaps test" -Direction Inbound -Protocol UDP -LocalPort 5000 -Action Allow'

# Find ffplay even if this shell started before FFmpeg was installed.
$ffplay = (Get-Command ffplay -ErrorAction SilentlyContinue).Source
if (-not $ffplay) {
    $cand = @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffplay.exe") +
            (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*" -Recurse -Filter ffplay.exe -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $ffplay = $cand | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $ffplay) { Write-Host "ffplay not found. Close PowerShell, open a new one and run this again (or use VLC)." -ForegroundColor Red; exit 1 }

Write-Host "Waiting for the stream from the iPhone... (close the window to stop)"
& $ffplay -protocol_whitelist file,udp,rtp -fflags nobuffer -flags low_delay -framedrop -window_title "Tripper Dash (526x300)" "$PSScriptRoot\dash-preview.sdp"
