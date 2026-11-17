# Shows the TripperMaps test stream on this PC (run in PowerShell from the project folder).
# Needs ffplay: winget install Gyan.FFmpeg   (or open tools\dash-preview.sdp in VLC instead)
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match 'Wi-Fi|Ethernet' -and $_.IPAddress -notmatch '^169' } | Select-Object -First 1).IPAddress
Write-Host "Type this IP into the app's 'PC IP address' field: $ip" -ForegroundColor Yellow
Write-Host "If nothing shows, allow UDP 5000 once (admin PowerShell):"
Write-Host '  New-NetFirewallRule -DisplayName "TripperMaps test" -Direction Inbound -Protocol UDP -LocalPort 5000 -Action Allow'
ffplay -protocol_whitelist file,udp,rtp -fflags nobuffer -flags low_delay -framedrop -window_title "Tripper Dash (526x300)" "$PSScriptRoot\dash-preview.sdp"
