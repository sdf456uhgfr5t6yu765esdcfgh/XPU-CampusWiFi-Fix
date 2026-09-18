@echo off
title XPU Campus WiFi Fix (Watchdog)
echo.
echo  ==========================================
echo   XPU Campus WiFi Fix - for XATU/XPU campus
echo   auto-fix + watchdog (auto-reconnect /
echo   roam to 5GHz / renew IP). Re-check 15s.
echo  ==========================================
echo  Press Q to quit the watchdog.
echo.
echo  Optional args:
echo    -Once        run once and exit
echo    -NoFix       diagnose only, no actions
echo    -SpeedTest   measure download speed (logged to speedlog.csv;
echo                 in watchdog mode it runs after pressing Q to exit)
echo    -Diagnose    full check: power-save/band/TCP/DNS/
echo                  latency/loss/IPv6 + fix suggestions
echo    -Tune        disable adapter power-save /
echo                 aggressive roaming (admin)
echo    -Untune      restore adapter settings (admin)
echo    -TcpFix      enable TCP autotuning (admin)
echo    -DnsFix      use public DNS 223.5.5.5 (admin,
echo                 auto backup + auto rollback on failure)
echo    -DnsRestore  restore original DNS (admin)
echo    -RenewIP     release/renew IP + clear DNS cache
echo    -FixIpv6     disable WLAN IPv6 (admin)
echo    -UnFixIpv6   re-enable WLAN IPv6 (admin)
echo    -ResetStack  reset IP stack + Winsock, reboot needed (admin)
echo.
if not exist "%~dp0Fix-CampusWiFi.ps1" (
    echo [X] Fix-CampusWiFi.ps1 not found next to this .bat.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-CampusWiFi.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
