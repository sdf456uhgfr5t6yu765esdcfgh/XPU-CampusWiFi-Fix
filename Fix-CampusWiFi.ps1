#Requires -Version 5.1
# ============================================================================
# 开源合规声明 (Compliance Notice)
# 本工具仅用于个人日常网络排障: 诊断并修复本地无线连接问题。
# 请遵守所在学校 / 单位的网络管理规定使用; 禁止用于绕过、篡改或干预
# 校园网络认证 / 计费 / 调度系统。违规使用产生的后果由使用者自行承担。
# 作者不提供任何担保, 详见 LICENSE (MIT)。
# ============================================================================

<#
  Fix-CampusWiFi.ps1  (v3.1 开源版 - 校园网综合修复)

  一键诊断 + 自动修复 + 持续守护, 覆盖校园网"网速差"的常见根因:
    1. 网卡 LPR/DTIM 省电休眠 -> 周期性卡顿        (Tune / 守护)
    2. 停在 2.4GHz 拥塞频段 -> 自动强制漫游 5GHz    (Once / 守护)
    3. TCP 自动调优被关/受限 -> 吞吐低              (TcpFix)
    4. 校园 DNS 慢/挂 -> 切公共 DNS 并自动回滚      (DnsFix / DnsRestore)
    5. IP 租约失效 / Portal 掉线 -> 自动 release/renew (RenewIP / 守护)
    6. 校园 IPv6 黑洞 -> 可禁用 WLAN 上的 IPv6      (FixIpv6 / UnFixIpv6)
    7. 协议栈损坏 -> 核选项重置, 需重启             (ResetStack)
    8. 晚高峰出口拥塞 / AP 侧问题 -> 诊断定位 + 测速日志 (Diagnose / SpeedTest)

  默认模式(双击运行):
    诊断当前 WiFi 链接 -> 掉线自动重连, 信号弱强制漫游(优先 5GHz),
    公网不通自动续 IP -> 进入持续守护: 每 15 秒复查, 变差立即修复。
    按 Q 键退出。

  参数一览:
    [守护相关]
    -Once          只诊断+修复一次, 不进守护循环
    -NoFix         仅诊断, 不做任何修复动作
    -SpeedTest     结束时测真实下载速度 (20MB Cloudflare), 结果记入 speedlog.csv
    [适配器层]
    -Tune          关网卡省电 + 激进漫游 (admin)
    -Untune        恢复 -Tune 修改 (admin)
    [协议层]
    -TcpFix        启用 TCP 自动调优 systemnormal (admin)
    -DnsFix        切公共 DNS 223.5.5.5/119.29.29.29, 自动备份+失败自动回滚 (admin)
    -DnsRestore    恢复原 DNS (admin)
    -FixIpv6       禁用 WLAN IPv6 (admin; 部分校园业务依赖 IPv6, 需要时 -UnFixIpv6)
    -UnFixIpv6     恢复 WLAN IPv6 (admin)
    [网络层]
    -RenewIP       ipconfig release/renew + 清 DNS 缓存 (免管理员)
    -ResetStack    netsh int ip reset + winsock reset, 需重启 (admin, 核选项)
    [诊断]
    -Diagnose      全面体检 7 项, 输出问题清单 + 建议参数 (只读, 免管理员)

  解析基于 VALUE (信号含%, RSSI 为负数, BSSID 是 MAC, 速率为整数), 与系统语言无关。
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$NoFix,
    [switch]$SpeedTest,
    [switch]$Tune,
    [switch]$Untune,
    [switch]$Diagnose,
    [switch]$TcpFix,
    [switch]$DnsFix,
    [switch]$DnsRestore,
    [switch]$RenewIP,
    [switch]$FixIpv6,
    [switch]$UnFixIpv6,
    [switch]$ResetStack
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# 自动探测无线适配器名: 中文系统一般 "WLAN", 英文系统 "Wi-Fi"
function Get-WlanAlias {
    $w = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match '(?i)wireless|wi-?fi' })
    $up = @($w | Where-Object { $_.Status -eq 'Up' })
    if ($up.Count -gt 0) { return $up[0].Name }
    if ($w.Count -gt 0) { return $w[0].Name }
    return 'WLAN'
}
$iface = Get-WlanAlias

function Write-Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "    [!] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "    [X] $m" -ForegroundColor Red }
function Write-Info($m) { Write-Host "    $m" }

function Is-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RequireAdmin {
    param([string]$What)
    if (Is-Admin) { return $true }
    Write-Err ("$What 需要管理员权限。请右键 Fix-CampusWiFi.bat -> 以管理员身份运行 (或终端: powershell -ExecutionPolicy Bypass -File Fix-CampusWiFi.ps1 <参数>, 管理员模式)。")
    return $false
}

function Get-WlanInfo {
    # 读取当前接口状态, 基于值解析, 语言无关
    $Text = ((netsh wlan show interfaces) -join [Environment]::NewLine)
    if ($Text -match "(?i)no wireless interface") { return $null }
    $i = [ordered]@{ Ssid = ""; Bssid = ""; Band = ""; Channel = ""; RxRate = 0; TxRate = 0; Signal = -1; Rssi = -999 }
    $rows = @()
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -notmatch "^([^:]+?)\s*[:]\s*(.*)$") { continue }
        $rows += [pscustomobject]@{ Key = $matches[1].Trim(); Val = $matches[2].Trim() }
    }
    $ints = @()
    foreach ($r in $rows) {
        if ($r.Key -match "(?i)^ssid$") { $i.Ssid = $r.Val }
        elseif ($r.Val -match "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$") { $i.Bssid = $r.Val.ToLower() }
        elseif ($r.Val -match "^\d+%\s*$") { $i.Signal = [int]($r.Val -replace "%","") }
        elseif ($r.Val -match "^-\d+$") { $i.Rssi = [int]$r.Val }
        elseif ($r.Val -match "(?i)GHz") { $i.Band = $r.Val }
        # 排除 QoS 行, 避免 0 值混入速率数组
        elseif ($r.Val -match "^\d+$" -and $r.Key -notmatch "(?i)qos|mscs|map|configured|allowed") { $ints += [int]$r.Val }
    }
    if ($ints.Count -ge 1) { $i.Channel = [string]$ints[0] }
    if ($ints.Count -ge 2) { $i.RxRate = $ints[1] }
    if ($ints.Count -ge 3) { $i.TxRate = $ints[2] }
    # 某些系统 netsh 不输出 Rssi, 用 Signal 粗估以便判断
    if ($i.Rssi -le -999 -and $i.Signal -ge 0) { $i.Rssi = [int]($i.Signal / 2) - 100 }
    return [pscustomobject]$i
}

function Get-SavedProfiles {
    # 只取冒号后的值 (兼容中英文 "All User Profile : XPU-Student")
    $lines = @(netsh wlan show profiles)
    $names = @()
    foreach ($line in $lines) {
        if ($line -match ':\s*(.+?)\s*$') {
            $s = $matches[1].Trim()
            if ($s -and $s -notmatch "(?i)^(none|<none>)$") {
                if ($names -notcontains $s) { $names += $s }
            }
        }
    }
    return $names
}

function Get-BestSignalForSsid {
    param([string]$Ssid, [switch]$HighBandOnly)
    if ([string]::IsNullOrEmpty($Ssid)) { return $null }
    $text = ((netsh wlan show networks mode=bssid) -join [Environment]::NewLine)
    $blocks = [regex]::Split($text, "(?im)^SSID \d+ : ")
    $best = $null
    foreach ($b in $blocks) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        if ($b -match "^(?<name>[^\r\n]+)") {
            $name = $matches['name'].Trim()
            if ($name -eq $Ssid) {
                if ($HighBandOnly) {
                    # 信道值: 块内第一个纯整数行; >=36 视为 5/6GHz
                    $ch = [regex]::Match($b, "(?im)^\s*\S+\s*:\s*(\d+)\s*$")
                    if (-not $ch.Success -or [int]$ch.Groups[1].Value -lt 36) { continue }
                }
                $sigs = [regex]::Matches($b, "(?im)^\s*\S+\s*:\s*(\d+)%")
                foreach ($s in $sigs) {
                    $v = [int]$s.Groups[1].Value
                    if ($null -eq $best -or $v -gt $best) { $best = $v }
                }
                break
            }
        }
    }
    return $best
}

function Show-Link($w) {
    Write-Info ("SSID    : " + $w.Ssid)
    Write-Info ("BSSID   : " + $w.Bssid)
    Write-Info ("Band/Ch : " + $w.Band + " / ch " + $w.Channel)
    Write-Info ("Signal  : " + $w.Signal + "%  (RSSI " + $w.Rssi + " dBm)")
    Write-Info ("RX rate : " + $w.RxRate + " Mbps   TX rate: " + $w.TxRate + " Mbps")
}

function Get-IpV4 {
    try {
        $ip = (Get-NetIPAddress -InterfaceAlias $iface -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -ne '0.0.0.0' } | Select-Object -First 1).IPAddress
        if ($ip) { return $ip } else { return '' }
    } catch { return '' }
}

function Get-DefaultGateway {
    try {
        $r = Get-NetRoute -InterfaceAlias $iface -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Select-Object -First 1
        if ($r) { return $r.NextHop }
    } catch {}
    return ''
}

function Test-NetReachable {
    # 测公网连通性: 优先 ICMP; ICMP 被学校封禁时用 DNS/TCP 兜底,
    # 避免误判"不通"导致守护模式反复续 IP、打断 Portal 会话
    try {
        if ([bool](Test-Connection -ComputerName 223.5.5.5 -Count 2 -Quiet -ErrorAction Stop)) { return $true }
    } catch {}
    # 兜底 1: 直接向 AliDNS 发 DNS 查询 (UDP 53)
    try {
        $null = @(Resolve-DnsName -Name 'baidu.com' -Server '223.5.5.5' -Type A -ErrorAction Stop)
        return $true
    } catch {}
    # 兜底 2: 常规 HTTPS 主机 TCP 443 (比拿 DNS 服务器的 443 当通用连通性探针更稳)
    try {
        $t = Test-NetConnection -ComputerName www.baidu.com -Port 443 -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        if ($t.TcpTestSucceeded) { return $true }
    } catch {}
    return $false
}

function Test-Jitter {
    param([string]$Target, [int]$Count = 5)
    # 返回 @{ LossPct, AvgMs, MaxMs }; 全部超时则 LossPct=100
    # Test-Connection 返回 Win32_PingStatus 对象: StatusCode=0 表示成功, ResponseTime (UInt32, ms)
    $res = @(Test-Connection -ComputerName $Target -Count $Count -ErrorAction SilentlyContinue)
    $ok = @($res | Where-Object { [int]$_.StatusCode -eq 0 })
    if ($ok.Count -eq 0) {
        return [pscustomobject]@{ LossPct = 100; AvgMs = 0; MaxMs = 0 }
    }
    # Measure-Object 不支持 UInt32, 手动统计
    $sum = 0.0; $mx = 0.0
    foreach ($o in $ok) {
        $v = [double]$o.ResponseTime
        $sum += $v
        if ($v -gt $mx) { $mx = $v }
    }
    return [pscustomobject]@{
        LossPct = [math]::Round((1 - [double]$ok.Count / [double]$Count) * 100, 0)
        AvgMs   = [math]::Round($sum / [double]$ok.Count, 0)
        MaxMs   = [math]::Round($mx, 0)
    }
}

function Measure-Dns {
    param([string]$Server = '', [string]$Name = 'baidu.com')
    # 两次解析取第二次(热缓存); 失败返回 -1; 单位 ms
    # 注意: Resolve-DnsName 的 -QuickTimeout 是开关参数(不能跟数字), 显式查 -Type A
    try {
        if ($Server) { $null = @(Resolve-DnsName -Name $Name -Server $Server -Type A -ErrorAction Stop) }
        else         { $null = @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop) }
    } catch {}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Server) { $null = @(Resolve-DnsName -Name $Name -Server $Server -Type A -ErrorAction Stop) }
        else         { $null = @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop) }
        $sw.Stop()
        return $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        return -1
    }
}

function Get-DnsServersOfWlan {
    $i = Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue
    if (-not $i) { return $null }
    $d = @(Get-DnsClientServerAddress -InterfaceIndex $i.IfIndex -ErrorAction SilentlyContinue)
    # 返回对象的 AddressFamily 是数值: 2=IPv4, 23=IPv6; DNS 服务器列表在 ServerAddresses
    $r4 = @($d | Where-Object { [int]$_.AddressFamily -eq 2 } | Select-Object -First 1)
    $r6 = @($d | Where-Object { [int]$_.AddressFamily -eq 23 } | Select-Object -First 1)
    $v4 = @(); $v6 = @()
    if ($r4.Count -gt 0) { $v4 = @($r4[0].ServerAddresses | Where-Object { $_ }) }
    if ($r6.Count -gt 0) { $v6 = @($r6[0].ServerAddresses | Where-Object { $_ }) }
    return [pscustomobject]@{ IfIndex = $i.IfIndex; V4 = $v4; V6 = $v6 }
}

function Test-DownloadSpeed {
    $url = "https://speed.cloudflare.com/__down?bytes=20000000"
    $b = curl.exe -s -o NUL -w "%{speed_download}" --max-time 30 $url
    if ($b -match "^\d+") { return ([double]$b * 8 / 1MB) }
    return $null
}

function Save-SpeedLog {
    param([double]$Mbs)
    if ($Mbs -le 0) { return }
    # 与其他备份统一放桌面 (避免 OneDrive 桌面重定向导致备份分家)
    $f = Join-Path $env:USERPROFILE 'Desktop\Fix-CampusWiFi-speedlog.csv'
    $w = $script:wlan
    if ($null -eq $w) { $w = Get-WlanInfo }
    if ($null -eq $w) { return }
    if (-not (Test-Path $f)) { Set-Content -Path $f -Value 'time,ssid,signal%,channel,band,mbps' }
    # 字符串字段加引号, 防止 SSID 含逗号导致 CSV 错列
    $row = '"' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '","' + $w.Ssid + '",' + $w.Signal + ',"' + $w.Channel + '","' + $w.Band + '",' + $Mbs
    Add-Content -Path $f -Value $row
    Write-Info ("测速已记录到 " + $f + " (可按时间段对比, 定位晚高峰拥塞)")
}

function Invoke-Reconnect {
    param([string]$Ssid)
    # 断开前记录 IP, 重连后若 IP 变化提示可能需重新 Portal 登录
    $ipBefore = Get-IpV4
    netsh wlan disconnect | Out-Null
    Start-Sleep -Seconds 4
    netsh wlan connect name="$Ssid" | Out-Null
    $w = $null
    for ($k = 1; $k -le 6; $k++) {
        Start-Sleep -Seconds 3
        $w = Get-WlanInfo
        if ($w -and $w.Ssid -ne "") { break }
    }
    $ipAfter = Get-IpV4
    if ($ipBefore -ne "" -and $ipAfter -ne "" -and $ipBefore -ne $ipAfter) {
        Write-Warn "IP 地址已变化 ($ipBefore -> $ipAfter)。如果无法上网, 请打开浏览器重新登录校园网 Portal。"
    }
    return $w
}

# ---------- 网络层修复 ----------

function Invoke-RenewIP {
    param([switch]$Quiet)
    if (-not $Quiet) { Write-Step "释放/重新获取 IP + 清 DNS 缓存" }
    $ip1 = Get-IpV4
    ipconfig /release "$iface" | Out-Null
    Start-Sleep -Seconds 1
    $out = ipconfig /renew "$iface"
    if (-not $Quiet) { $out | ForEach-Object { Write-Info $_ } }
    Start-Sleep -Seconds 2
    Clear-DnsClientCache
    $ip2 = Get-IpV4
    if ($ip2 -and $ip1 -and $ip1 -ne $ip2) {
        Write-Warn ("IP 已变化 (" + $ip1 + " -> " + $ip2 + ")。如果仍不能上网, 可能需要重新登录 Portal。")
    } elseif ($ip2) {
        if (-not $Quiet) { Write-Ok ("IP 保持: " + $ip2) }
    } else {
        Write-Warn "续 IP 后未获取到 IPv4。请检查 WiFi 连接状态"
    }
    return $ip2
}

function Invoke-ResetStack {
    Write-Step "重置网络协议栈 (核选项: 以上都无效时再用)"
    if (-not (Test-RequireAdmin '协议栈重置')) { return $false }
    Write-Warn "将执行 netsh int ip reset + netsh winsock reset, 必须重启电脑才生效。"
    $yn = Read-Host "确认执行? (输入 Y 确认)"
    if ($yn -notmatch '^[yY]') { Write-Info '已取消'; return $false }
    $o1 = netsh int ip reset
    $o1 | ForEach-Object { Write-Info $_ }
    Start-Sleep -Seconds 1
    $o2 = netsh winsock reset
    $o2 | ForEach-Object { Write-Info $_ }
    Write-Warn "请现在重启电脑使修复生效。"
    return $true
}

# ---------- 协议层修复 ----------

function Invoke-TcpFix {
    Write-Step "TCP 自动调优修复 (autotuning -> systemnormal)"
    $g = ((netsh int tcp show global) -join [Environment]::NewLine)
    $at = '?'
    if ($g -match '(?i)auto-?tuning level\s*:\s*(\S+)') { $at = $matches[1] }
    Write-Info ("当前 autotuning: " + $at)
    if ($at -eq 'normal') { Write-Ok '已经是 normal, 无需修改'; return $true }
    if (-not (Test-RequireAdmin 'TCP 修复')) { return $false }
    $o = netsh int tcp set global autotuning=systemnormal
    $o | ForEach-Object { Write-Info $_ }
    $g2 = ((netsh int tcp show global) -join [Environment]::NewLine)
    $at2 = '?'
    if ($g2 -match '(?i)auto-?tuning level\s*:\s*(\S+)') { $at2 = $matches[1] }
    if ($at2 -eq 'normal') { Write-Ok ("autotuning 已恢复 normal") }
    else { Write-Warn ("当前仍为 $at2。若未生效, 重启电脑后用 -Diagnose 复查") }
    return $true
}

function Invoke-DnsFix {
    Write-Step "切换公共 DNS: 223.5.5.5 + 119.29.29.29 (AliDNS/DNSPod)"
    if (-not (Test-RequireAdmin 'DNS 切换')) { return $false }
    $i = Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue
    if (-not $i) { Write-Err ("找不到接口 $iface"); return $false }
    $idx = $i.IfIndex
    $cur = Get-DnsServersOfWlan
    if ($null -eq $cur) { Write-Err '无法读取当前 DNS 配置'; return $false }
    $bk = Join-Path $env:USERPROFILE 'Desktop\Fix-CampusWiFi-dns-backup.json'
    $backup = [pscustomobject]@{
        IfIndex = $idx
        V4      = @($cur.V4)
        V6      = @($cur.V6)
    }
    $backup | ConvertTo-Json -Depth 4 | Set-Content -Path $bk -Encoding UTF8
    $origAll = ((@($cur.V4) + @($cur.V6)) -join ' ')
    if ($origAll -eq '') { Write-Info '原 DNS: DHCP 分配 (无手动配置)' }
    else { Write-Info ("原 DNS: " + $origAll) }
    Write-Info ("已备份到 " + $bk + " (-DnsRestore 可还原)")
    try {
        # Set-DnsClientServerAddress 没有 -AddressFamily 参数 (只有 Get 侧有), IPv4/IPv6 需合并一次写入
        Set-DnsClientServerAddress -InterfaceIndex $idx -Addresses @('223.5.5.5', '119.29.29.29', '2400:3200::1', '2400:320b::1') -ErrorAction Stop | Out-Null
        Clear-DnsClientCache
    } catch {
        Write-Err ("写入 DNS 失败: " + $_.Exception.Message)
        return $false
    }
    # 验证: 必须真正拿到 A 记录 (CNAME 链会先返回 CNAME, 需过滤; 避免 StrictMode 下取 CNAME 的 IPAddress 崩溃)
    # 刚切换 DNS 时客户端服务在重新初始化, 首次查询可能瞬时失败 -> 重试 3 次再下结论
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $okV = $false; $ip = ''
    for ($vi = 1; $vi -le 4; $vi++) {
        try {
            $r = @(Resolve-DnsName -Name 'www.aliyun.com' -Type A -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1)
            if ($r.Count -gt 0 -and $r[0].IPAddress) { $okV = $true; $ip = $r[0].IPAddress; break }
        } catch {}
        if ($vi -lt 4) { Start-Sleep -Seconds 3 }
    }
    $sw.Stop()
    if ($okV) {
        Write-Ok ("验证通过: www.aliyun.com -> " + $ip + " (" + $sw.ElapsedMilliseconds + " ms)")
        Write-Warn "如果校园网禁止公共 DNS 导致不能上网, 运行: Fix-CampusWiFi.bat -DnsRestore 还原"
        return $true
    }
    Write-Warn "验证失败 (公共 DNS 可能不通)。自动恢复原 DNS..."
    $null = Invoke-DnsRestore -Quiet
    return $false
}

function Invoke-DnsRestore {
    param([switch]$Quiet)
    if (-not $Quiet) { Write-Step "恢复原 DNS 设置" }
    if (-not $Quiet -and -not (Test-RequireAdmin 'DNS 恢复')) { return $false }
    $bk = Join-Path $env:USERPROFILE 'Desktop\Fix-CampusWiFi-dns-backup.json'
    if (-not (Test-Path $bk)) {
        if (-not $Quiet) { Write-Err ("找不到备份文件: " + $bk + " (可能从未运行过 -DnsFix)") }
        return $false
    }
    $b = Get-Content $bk -Raw | ConvertFrom-Json
    $v4 = @($b.V4 | Where-Object { $_ })
    $v6 = @($b.V6 | Where-Object { $_ })
    # 刚被 -DnsFix 改过的 DNS 客户端服务可能在重新初始化, 首次写入可能静默失败
    # -> 每轮回写 + 回读校验, 最多 3 轮, 只有回读确认才算成功
    $okR = $false
    for ($ri = 1; $ri -le 5; $ri++) {
        # DNS 客户端服务刚被改动过, 写入可能被拒绝或延迟生效, 每轮重设 + 回读确认
        # Set-DnsClientServerAddress 没有 -AddressFamily 参数, 无法只清某一族:
        # 先整清再按备份写入, 保证"备份某侧无静态"时, 该侧残留的静态也被清掉, 与备份逐字节一致
        if ($v4.Count -eq 0 -and $v6.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $b.IfIndex -ClearAll -ErrorAction SilentlyContinue | Out-Null
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $b.IfIndex -ClearAll -ErrorAction SilentlyContinue | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $b.IfIndex -Addresses (@($v4) + @($v6)) -ErrorAction SilentlyContinue | Out-Null
        }
        Clear-DnsClientCache
        Start-Sleep -Seconds 1
        $cur = Get-DnsServersOfWlan
        if ($null -eq $cur) { if ($ri -lt 5) { Start-Sleep -Seconds 3 }; continue }
        $confirm = $false
        if ($v4.Count -gt 0 -and $cur.V4 -contains $v4[0]) { $confirm = $true }
        elseif ($v4.Count -eq 0 -and $v6.Count -gt 0 -and $cur.V6 -contains $v6[0]) { $confirm = $true }
        elseif ($v4.Count -eq 0 -and $v6.Count -eq 0) { $confirm = $true }
        if ($confirm) { $okR = $true; break }
        if ($ri -lt 5) { Start-Sleep -Seconds 3 }
    }
    if (-not $okR) {
        Write-Err "DNS 恢复未确认生效 (已重试 5 轮)。请在 网络连接 -> WLAN 属性 -> IPv4 -> 常规 手动检查 DNS。"
        return $false
    }
    # 行为不对称(有意): 手动 -DnsRestore 成功后删除备份(删后不可再还原);
    # 自动回滚路径 (Invoke-DnsFix 内部以 -Quiet 调用) 保留备份, 便于之后再次 -DnsRestore
    if (-not $Quiet) {
        $nowD = Get-DnsServersOfWlan
        Write-Ok ("已恢复原 DNS: " + ((@($nowD.V4) + @($nowD.V6)) -join ' '))
        Remove-Item $bk -ErrorAction SilentlyContinue
        Write-Info ("已删除备份: " + $bk)
    }
    return $true
}

# ---------- 适配器层修复 (v2 保留) ----------

function Get-IntelAdapterKey {
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
    $ad = Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc -like "*Intel*Wi-Fi*"
    } | Select-Object -First 1
    if ($ad) { return $ad.PSPath }
    return $null
}

function Invoke-Tune {
    Write-Step "优化 Intel 网卡 (关闭省电 + 激进漫游)"
    if (-not (Is-Admin)) {
        Write-Err "需要管理员权限。请右键 Fix-CampusWiFi.bat -> 以管理员身份运行, 或运行: powershell -File Fix-CampusWiFi.ps1 -Tune"
        return $false
    }
    $key = Get-IntelAdapterKey
    if (-not $key) { Write-Err "未找到 Intel 无线网卡。"; return $false }
    $backup = Join-Path $env:USERPROFILE "Desktop\Fix-CampusWiFi-tune-backup.txt"
    $names = @('RoamAggressiveness','LprxEnable','SkipOverDtimEnable','*PacketCoalescing')
    if (Test-Path $backup) {
        # 绝不覆盖: 保留"首次"原始值, 保证 -Untune 始终能还原到最初状态
        Write-Info ("原设置备份已存在: " + $backup + " (不覆盖, 保证 -Untune 还原到最初原始值)")
    } else {
        $lines = @()
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        foreach ($n in $names) {
            # 先查属性存在性 (不同 Intel 驱动项不同, StrictMode 下直接取缺少的属性会崩); 记录值类型供 -Untune 按原类型恢复
            $p = $null
            if ($null -ne $props) { $p = $props.PSObject.Properties | Where-Object { $_.Name -eq $n } | Select-Object -First 1 }
            if ($null -ne $p) {
                $v = $p.Value
                $pt = $p.PropertyType.Name
                if ($null -ne $v) { $lines += "$n=$v|$pt" }
            }
        }
        $lines | Set-Content -Path $backup -Encoding UTF8
        Write-Info ("原设置已备份到 " + $backup)
    }
    # RoamAggressiveness: 3 = 最激进漫游; 省电项全部关闭
    Set-ItemProperty -Path $key -Name 'RoamAggressiveness' -Value 3 -Type DWord
    Set-ItemProperty -Path $key -Name 'LprxEnable' -Value 0 -Type DWord
    Set-ItemProperty -Path $key -Name 'SkipOverDtimEnable' -Value 0 -Type DWord
    Set-ItemProperty -Path $key -Name '*PacketCoalescing' -Value 0 -Type DWord
    Write-Ok "设置已写入 (漫游=激进, 省电=关闭)。"
    Write-Warn "需要重启无线网卡或系统后生效。"
    $yn = Read-Host "立即重启无线网卡? (约 10 秒断网, 输入 Y 确认)"
    if ($yn -match "^[yY]") {
        Write-Info "正在重启无线网卡..."
        try {
            Restart-NetAdapter -Name $iface -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 5
            Write-Ok "网卡已重启, WiFi 会自动重连。"
        } catch {
            Write-Warn ("重启网卡失败: " + $_.Exception.Message + " 请手动重启电脑。")
        }
    }
    return $true
}

function Invoke-Untune {
    Write-Step "恢复网卡原始设置"
    $backup = Join-Path $env:USERPROFILE "Desktop\Fix-CampusWiFi-tune-backup.txt"
    if (-not (Test-Path $backup)) { Write-Err "找不到备份文件: $backup (可能从未运行过 -Tune)。"; return }
    if (-not (Is-Admin)) { Write-Err "需要管理员权限。请右键以管理员身份运行。"; return }
    $key = Get-IntelAdapterKey
    if (-not $key) { Write-Err "未找到 Intel 无线网卡。"; return }
    foreach ($line in (Get-Content $backup)) {
        # 新格式: name=value|TypeName ; 旧格式: name=value (无类型标记, 默认 DWord)
        if ($line -match "^(.+?)=([^|]+)(?:\|([A-Za-z0-9\[\]]+))?$") {
            $n2 = $matches[1].Trim()
            $v2 = $matches[2].Trim()
            $tn = $matches[3]
            # 按备份记录的 .NET 类型名映射回注册表类型 (UInt32/UInt32[] -> DWord, String -> String, Byte[] -> Binary)
            $type = 'DWord'
            if ($tn -match '(?i)^String') { $type = 'String' }
            elseif ($tn -match '(?i)^Byte') { $type = 'Binary' }
            $val = $v2
            if ($type -eq 'Binary') { $val = @($v2 -split ',' | ForEach-Object { [byte]$_.Trim() }) }
            elseif ($type -eq 'DWord') { $val = [int]$v2 }
            Set-ItemProperty -Path $key -Name $n2 -Value $val -Type $type
        }
    }
    Write-Ok "已恢复。重启网卡或系统后生效。"
    return $true
}

# ---------- IPv6 开关 ----------

function Invoke-FixIpv6 {
    Write-Step "禁用 WLAN 上的 IPv6"
    if (-not (Test-RequireAdmin '禁用 IPv6')) { return $false }
    Write-Info "注意: 部分校园业务依赖 IPv6。若出问题用 -UnFixIpv6 恢复。"
    try {
        Disable-NetAdapterBinding -Name $iface -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Ok 'IPv6 协议已禁用'
    } catch {
        Write-Warn ("操作失败: " + $_.Exception.Message)
        Write-Warn '手动方法: 控制面板 -> 网络连接 -> 右键 WLAN 属性 -> 取消勾选 "Internet 协议版本 6 (TCP/IPv6)"'
        return $false
    }
    Write-Warn "重启无线网卡后完全生效 (约 10 秒断网)。"
    $yn = Read-Host "立即重启无线网卡? (输入 Y 确认)"
    if ($yn -match '^[yY]') {
        Restart-NetAdapter -Name $iface -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Write-Ok '网卡已重启, WiFi 会自动重连'
    }
    return $true
}

function Invoke-UnFixIpv6 {
    Write-Step "恢复 WLAN 的 IPv6"
    if (-not (Test-RequireAdmin '恢复 IPv6')) { return $false }
    try {
        Enable-NetAdapterBinding -Name $iface -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Ok 'IPv6 协议已启用'
    } catch {
        Write-Warn ("操作失败: " + $_.Exception.Message)
        Write-Warn '手动方法: 右键 WLAN 属性 -> 勾选 "Internet 协议版本 6 (TCP/IPv6)"'
        return $false
    }
    $yn = Read-Host "立即重启无线网卡? (输入 Y 确认)"
    if ($yn -match '^[yY]') {
        Restart-NetAdapter -Name $iface -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Write-Ok '网卡已重启, WiFi 会自动重连'
    }
    return $true
}

# ---------- 全面诊断 ----------

function Invoke-Diagnose {
    Write-Step "全面诊断 - 校园网"
    $findings = @()

    $wlan = Get-WlanInfo
    if ($null -eq $wlan) {
        Write-Err '未找到无线网卡或无法读取 WiFi 状态。请先启用 WiFi 再运行。'
        return
    }
    Show-Link $wlan

    Write-Host ""
    Write-Host '--- [1/7] 网卡省电/漫游 ---'
    $key = Get-IntelAdapterKey
    if ($key) {
        # 逐项查属性存在性 (不同驱动项不同, StrictMode 下直接取缺少的属性会崩)
        $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
        $lpr = $null; $d2 = $null
        if ($null -ne $props) {
            $pl = $props.PSObject.Properties | Where-Object { $_.Name -eq 'LprxEnable' } | Select-Object -First 1
            $pd = $props.PSObject.Properties | Where-Object { $_.Name -eq 'SkipOverDtimEnable' } | Select-Object -First 1
            if ($pl) { $lpr = [int]$pl.Value }
            if ($pd) { $d2 = [int]$pd.Value }
        }
        if ($null -eq $lpr -and $null -eq $d2) {
            # 驱动项未暴露 LprxEnable/SkipOverDtimEnable: 省电状态未知, 不能判成"已关闭"
            Write-Info '驱动项缺少 LprxEnable/SkipOverDtimEnable, 省电状态未知 (不下结论)'
        } elseif (($null -ne $lpr -and $lpr -eq 1) -or ($null -ne $d2 -and $d2 -eq 1)) {
            $lprS = if ($null -eq $lpr) { '?' } else { [string]$lpr }
            $d2S  = if ($null -eq $d2)  { '?' } else { [string]$d2 }
            $findings += "网卡省电开启 (LPR=$lprS, DTIM=$d2S) - 周期性卡顿元凶。建议: -Tune (admin)"
            Write-Warn '网卡省电开启 -> 建议 -Tune'
        } else {
            $unknown = @()
            if ($null -eq $lpr) { $unknown += 'LPR' }
            if ($null -eq $d2)  { $unknown += 'DTIM' }
            if ($unknown.Count -gt 0) {
                Write-Info ('已知省电项已关闭, 但 ' + ($unknown -join '/') + ' 未知 (驱动项缺失, 不下结论)')
            } else {
                Write-Ok '网卡省电已关闭'
            }
        }
    } else {
        Write-Info '未找到 Intel 网卡, 跳过省电检查'
    }

    Write-Host ""
    Write-Host '--- [2/7] 频段 (2.4GHz 拥塞) ---'
    $chNum = 0
    if ($wlan.Channel -match '^\d+$') { $chNum = [int]$wlan.Channel }
    if ($chNum -ge 1 -and $chNum -le 14) {
        $b5 = Get-BestSignalForSsid $wlan.Ssid -HighBandOnly
        if ($null -ne $b5 -and $b5 -gt ($wlan.Signal + 10)) {
            $findings += ("当前 2.4GHz ch" + $chNum + " (易拥塞), 存在更强 5GHz AP (" + $b5 + "%)。建议: -Once 自动漫游 或 -Tune")
            Write-Warn ("2.4GHz 卡住, 有更强 5GHz AP (" + $b5 + "%) -> 建议 -Once")
        } else {
            Write-Ok ("2.4GHz, 当前 AP 信号 " + $wlan.Signal + "%, 无更优 5GHz 可选")
        }
    } else {
        Write-Ok ("当前高频段 (ch " + $wlan.Channel + ", " + $wlan.Band + ")")
    }

    Write-Host ""
    Write-Host '--- [3/7] TCP 自动调优 ---'
    $g = ((netsh int tcp show global) -join [Environment]::NewLine)
    $at = '?'
    if ($g -match '(?i)auto-?tuning level\s*:\s*(\S+)') { $at = $matches[1] }
    if ($at -eq 'normal') {
        Write-Ok 'TCP autotuning 正常'
    } else {
        $findings += ("TCP autotuning = " + $at + " (非 normal) - 典型'测速快但实际慢'。建议: -TcpFix (admin)")
        Write-Warn ("autotuning = " + $at + " -> 建议 -TcpFix")
    }

    Write-Host ""
    Write-Host '--- [4/7] DNS ---'
    $dnsInfo = Get-DnsServersOfWlan
    if ($null -eq $dnsInfo) {
        Write-Info '无法读取 WLAN DNS 配置'
    } else {
        $all = @($dnsInfo.V4) + @($dnsInfo.V6)
        if ($all.Count -eq 0) {
            Write-Info '未读到 DNS 服务器列表, 测默认解析耗时...'
            $ms = Measure-Dns
            if ($ms -lt 0) {
                $findings += '默认 DNS 解析失败。建议: -DnsFix (admin)'
                Write-Warn '默认 DNS 失败 -> 建议 -DnsFix'
            } elseif ($ms -gt 500) {
                $findings += ("默认 DNS 慢 (" + $ms + " ms)。建议: -DnsFix (admin)")
                Write-Warn ("默认 DNS " + $ms + " ms 偏慢 -> 建议 -DnsFix")
            } else {
                Write-Ok ("默认 DNS " + $ms + " ms 正常")
            }
        } else {
            Write-Info ("当前 DNS: " + ($all -join ' '))
            $worst = -1
            foreach ($s in $all) {
                $ms = Measure-Dns -Server $s
                Write-Info ("  " + $s + " -> " + $(if ($ms -lt 0) { '不通' } else { "$ms ms" }))
                if ($ms -ge 0 -and $ms -gt $worst) { $worst = $ms }
            }
            if ($worst -lt 0) {
                $findings += '配置的 DNS 全部不通。建议: -DnsFix (admin)'
                Write-Warn 'DNS 全部不通 -> 建议 -DnsFix'
            } elseif ($worst -gt 300) {
                $findings += ("DNS 过慢 (" + $worst + " ms)。建议: -DnsFix (admin)")
                Write-Warn ("DNS " + $worst + " ms 过慢 -> 建议 -DnsFix")
            } else {
                Write-Ok ("DNS 响应 " + $worst + " ms 正常")
            }
        }
    }

    Write-Host ""
    Write-Host '--- [5/7] 时延与丢包 (网关/公网) ---'
    $gw = Get-DefaultGateway
    if ($gw) {
        $jg = Test-Jitter $gw
        Write-Info ("网关 " + $gw + ": 丢包 " + $jg.LossPct + "%  平均 " + $jg.AvgMs + " ms  最大 " + $jg.MaxMs + " ms")
        if ($jg.LossPct -gt 0 -or $jg.AvgMs -gt 30) {
            $findings += ("局域网链路抖动: 丢包 " + $jg.LossPct + "% / 平均 " + $jg.AvgMs + " ms。建议: -RenewIP, -Tune (若未做), 或靠近 AP")
            Write-Warn '局域网抖动 (离 AP 远/拥塞) -> 建议 -RenewIP / -Tune / 靠近 AP'
        }
    } else {
        Write-Warn '未找到默认网关 (WLAN 可能未连接)'
    }
    $jp = Test-Jitter '223.5.5.5'
    Write-Info ("公网 223.5.5.5: 丢包 " + $jp.LossPct + "%  平均 " + $jp.AvgMs + " ms  最大 " + $jp.MaxMs + " ms")
    if ($jp.LossPct -gt 0) {
        $findings += ("公网丢包 " + $jp.LossPct + "%: 可能是 Portal 未登录/学校出口 QoS。建议: 浏览器重新登录 Portal, -RenewIP, -DnsFix")
        Write-Warn '公网丢包 -> 建议 Portal 重新登录 / -RenewIP / -DnsFix'
    }

    Write-Host ""
    Write-Host '--- [6/7] IPv6 ---'
    $v6 = @(Get-NetIPAddress -InterfaceAlias $iface -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -in @('Dhcp','RouterAdvertisement') })
    if ($v6.Count -gt 0) {
        $ok6 = $false
        try { $ok6 = [bool](Test-Connection -ComputerName '2400:3200::1' -Count 2 -Quiet -ErrorAction Stop) } catch {}
        if ($ok6) {
            Write-Ok 'IPv6 正常'
        } else {
            Write-Warn '存在 IPv6 但公网 IPv6 不通 - 若网页偶发卡顿/解析超时, 可尝试 -FixIpv6 (禁用 IPv6, admin; 用后 -UnFixIpv6 恢复)'
        }
    } else {
        Write-Info '无全局 IPv6 地址 (纯 IPv4 校园网正常现象)'
    }

    Write-Host ""
    Write-Host '--- [7/7] IP 租约 ---'
    $ip = Get-IpV4
    Write-Info ("当前 IPv4: " + $(if ($ip) { $ip } else { '(无)' }) + "  (IP 变化后可能需要重新登录校园网 Portal)")

    Write-Host ""
    Write-Host '================= 诊断总结 ================='
    if ($findings.Count -eq 0) {
        Write-Ok '本机各检查项正常。若仍慢: 1) 不同时段 -SpeedTest 对比, 排除学校出口晚高峰拥塞; 2) 联系学校网络中心 (AP/出口侧问题); 3) 最后手段 -ResetStack + 重启'
    } else {
        $n = 0
        foreach ($f in $findings) {
            $n++
            Write-Warn ("问题 $n : $f")
        }
        Write-Host ""
        Write-Info '按建议运行对应参数 (标注 admin 的需要以管理员运行 Fix-CampusWiFi.bat)。'
    }
    return $true
}

# ---------- 单独功能入口 (失败返回非零退出码, .bat 侧可感知) ----------
function Finish-WithError {
    param($Result)
    Write-Host ""
    if ($Result) { Write-Ok "Done." } else { Write-Err "未完成 (详情见上方)。" }
    exit $(if ($Result) { 0 } else { 1 })
}
if ($Tune)   { Finish-WithError (Invoke-Tune) }
if ($Untune) { Finish-WithError (Invoke-Untune) }
if ($TcpFix)     { Finish-WithError (Invoke-TcpFix) }
if ($DnsFix)     { Finish-WithError (Invoke-DnsFix) }
if ($DnsRestore) { Finish-WithError (Invoke-DnsRestore) }
if ($FixIpv6)    { Finish-WithError (Invoke-FixIpv6) }
if ($UnFixIpv6)  { Finish-WithError (Invoke-UnFixIpv6) }
if ($RenewIP)    { Finish-WithError (Invoke-RenewIP) }
if ($ResetStack) { Finish-WithError (Invoke-ResetStack) }
if ($Diagnose)   { Finish-WithError (Invoke-Diagnose) }

# ---------- 主流程 ----------
Write-Step "当前 WiFi 链接"
$wlan = Get-WlanInfo
if ($null -eq $wlan) { Write-Err "未找到无线网卡。请先启用 WiFi, 然后重试。"; exit 1 }
Show-Link $wlan

function Invoke-OnePass {
    param([string]$Label)
    $script:wlan = Get-WlanInfo
    if ($null -eq $script:wlan) { Write-Warn "无法读取 WiFi 状态。"; return }

    # 1) 掉线 -> 自动重连
    if ($script:wlan.Ssid -eq "") {
        Write-Warn "WiFi 未连接, 尝试自动重连..."
        if ($NoFix) { Write-Info "(-NoFix) 跳过重连。"; return }
        $names = @(Get-SavedProfiles)
        $candidate = $names | Where-Object { $_ -match "(?i)xpu|student|campus|edu" } | Select-Object -First 1
        $isFallback = $false
        if (-not $candidate) { $candidate = $names | Select-Object -First 1; $isFallback = $true }
        if ($candidate) {
            Write-Info ("使用已保存配置: " + $candidate)
            if ($isFallback) { Write-Info "(无校园网风格配置, 使用第一个已保存配置 - 可能是手机热点等)" }
            $script:wlan = Invoke-Reconnect -Ssid $candidate
            if ($null -eq $script:wlan) {
                Write-Warn "无法读取链接状态 (WiFi 可能已关闭或网卡缺失), 无法确认重连结果"
            } else {
                Show-Link $script:wlan
                if ($script:wlan.Ssid -ne "") { Write-Ok "已重新连接。" } else { Write-Warn "自动重连失败, 请手动连接。" }
            }
        } else {
            Write-Err "没有已保存的 WiFi 配置。请先手动连接一次校园网。"
        }
        return
    }

    # 2) 信号弱 -> 强制漫游重连 (不断开正常链接, 仅弱时)
    $signal = $script:wlan.Signal
    if ($signal -lt 60) {
        Write-Warn ("信号偏弱: " + $signal + "% (RSSI " + $script:wlan.Rssi + " dBm)")
        if ($NoFix) { Write-Info "(-NoFix) 跳过修复。"; return }
        $best = Get-BestSignalForSsid $script:wlan.Ssid
        if ($null -eq $best) {
            Write-Warn "扫描缓存中没有该 SSID (AP 列表可能为空), 本次跳过强制漫游"
            return
        }
        if ($best -le ($signal + 5)) {
            Write-Warn ("可见最强 AP 也只有 " + $best + "%, 没有明显更强的 AP, 跳过重连。请靠近 AP 或换个位置。")
            return
        }
        Write-Info ("检测到更强 AP (" + $best + "%), 强制漫游...")
        $ssid = $script:wlan.Ssid
        $ok = $false
        for ($n = 1; $n -le 3; $n++) {
            Write-Step ("漫游尝试 " + $n + "/3")
            $script:wlan = Invoke-Reconnect -Ssid $ssid
            if ($null -eq $script:wlan) { Write-Warn "无法读取链接状态 (WiFi 可能已关闭), 继续尝试..."; continue }
            Show-Link $script:wlan
            if ($script:wlan.Signal -ge 60) { Write-Ok "已漫游到更强的 AP。"; $ok = $true; break }
            Write-Warn "仍偏弱, 重试..."
        }
        if (-not $ok) { Write-Warn "3 次尝试后信号仍弱, 请移动位置后再试。" }
    }
    else {
        Write-Ok ("信号良好 (" + $signal + "%)")
    }

    # 2.5) 频段优化: 2.4GHz 且有明显更强的 5GHz AP -> 强制漫游过去
    $chNum = 0
    if ($script:wlan.Channel -match '^\d+$') { $chNum = [int]$script:wlan.Channel }
    if ($chNum -ge 1 -and $chNum -le 14) {
        $b5 = Get-BestSignalForSsid $script:wlan.Ssid -HighBandOnly
        if ($null -ne $b5 -and $b5 -gt ($script:wlan.Signal + 10)) {
            Write-Info ("当前 2.4GHz ch" + $chNum + ", 5GHz AP 达 " + $b5 + "%, 强制漫游...")
            if (-not $NoFix) {
                $ssid5 = $script:wlan.Ssid
                $script:wlan = Invoke-Reconnect -Ssid $ssid5
                if ($null -eq $script:wlan) {
                    Write-Warn "无法读取链接状态 (WiFi 可能已关闭)"
                } else {
                    Show-Link $script:wlan
                    $chNow = 0
                    if ($script:wlan.Channel -match '^\d+$') { $chNow = [int]$script:wlan.Channel }
                    if ($chNow -ge 36) { Write-Ok ("已切到 5GHz (ch " + $chNow + ")") }
                    else { Write-Warn "仍在 2.4GHz。5GHz AP 可能不在覆盖范围, 或系统未选择它" }
                }
            }
        }
    }

    # 3) 公网连通性检查 (Portal 场景), 不通时先自动续 IP
    if (-not (Test-NetReachable)) {
        if (-not $NoFix) {
            Write-Warn "无法访问公网。尝试释放/续 IP + 清 DNS 缓存..."
            $null = Invoke-RenewIP -Quiet
            if (Test-NetReachable) { Write-Ok "公网已恢复。" }
            else {
                Write-Warn "仍无法访问: 可能是 Portal 重新登录 / 学校出口问题。"
                Write-Warn "可试: 浏览器登录 Portal, 或 -DnsFix, -ResetStack (admin)"
            }
        } else {
            Write-Warn "无法访问公网。如果这是校园网, 可能需要在浏览器中完成 Portal 登录。"
        }
    }
}

if ($Once) {
    Invoke-OnePass
    if ($SpeedTest) {
        Write-Step "下载测速 (20 MB from Cloudflare)"
        $mbps = Test-DownloadSpeed
        if ($null -ne $mbps) {
            $mbps = [math]::Round($mbps, 1)
            Write-Info ("真实吞吐: " + $mbps + " Mbps")
            if ($mbps -lt 10)      { Write-Warn "非常慢, 可能是校园网出口拥塞或限速时段。" }
            elseif ($mbps -lt 30)  { Write-Warn "中等偏慢, 校园网共享带宽繁忙。" }
            else                   { Write-Ok "吞吐不错。" }
            Save-SpeedLog $mbps
        } else { Write-Err "测速失败 (curl 不可用或网络不通)。" }
    }
    Write-Host ""; Write-Ok "Done."
    exit 0
}

# ---------- 默认: 守护循环 ----------
Write-Step "进入守护模式"
Write-Info "每 15 秒检查一次: 信号弱/掉线自动修复, 公网不通自动续 IP。按 Q 键退出。"
if (-not $NoFix) { Write-Info "(修复已启用; 加 -NoFix 可只观察不动作)" }
$script:lastIp = Get-IpV4
$script:unreachTicks = 0
$script:lastRenewTick = -1000
$tick = 0
while ($true) {
    $tick++
    $ts = Get-Date -Format "HH:mm:ss"
    $script:wlan = Get-WlanInfo
    if ($null -eq $script:wlan) {
        Write-Warn ("[" + $ts + "] 无法读取 WiFi 状态")
    }
    elseif ($script:wlan.Ssid -eq "") {
        Write-Warn ("[" + $ts + "] WiFi 掉线, 自动重连...")
        if ($NoFix) { Write-Info "(-NoFix) 跳过。请手动连接。" }
        else {
            $names = @(Get-SavedProfiles)
            $candidate = $names | Where-Object { $_ -match "(?i)xpu|student|campus|edu" } | Select-Object -First 1
            $isFallback = $false
            if (-not $candidate) { $candidate = $names | Select-Object -First 1; $isFallback = $true }
            if ($candidate) {
                Write-Info ("使用已保存配置: " + $candidate)
                if ($isFallback) { Write-Info "(无校园网风格配置, 使用第一个已保存配置 - 可能是手机热点等)" }
                $script:wlan = Invoke-Reconnect -Ssid $candidate
                $script:lastIp = Get-IpV4
            }
        }
    }
    else {
        # --- IP 变化检测 (Portal/租约异常) ---
        $curIp = Get-IpV4
        if ($curIp -and $script:lastIp -and $curIp -ne $script:lastIp) {
            Write-Warn ("[" + $ts + "] IP 已变化 (" + $script:lastIp + " -> " + $curIp + ")。可能需要重新登录校园网 Portal。")
        }
        if ($curIp) { $script:lastIp = $curIp }

        # --- 公网连通性 + 自动续 IP ---
        $reach = Test-NetReachable
        if (-not $reach) {
            $script:unreachTicks++
            if ($NoFix) {
                if ($script:unreachTicks -eq 1) { Write-Warn ("[" + $ts + "] 公网不通。可能需 Portal 登录 (-NoFix 跳过自动修复)") }
            }
            else {
                $sinceRenew = $tick - $script:lastRenewTick
                if ($script:unreachTicks -le 1 -or $sinceRenew -ge 3) {
                    if ($script:unreachTicks -eq 1) { Write-Warn ("[" + $ts + "] 公网不通, 尝试释放/续 IP + 清 DNS 缓存...") }
                    $null = Invoke-RenewIP -Quiet
                    $script:lastRenewTick = $tick
                    $script:lastIp = Get-IpV4
                    if (Test-NetReachable) {
                        Write-Ok "公网已恢复。"
                        $script:unreachTicks = 0
                    } else {
                        Write-Warn ("仍无法访问: 可能是 Portal 重新登录 / 学校出口问题。可试 -DnsFix, -RenewIP, -ResetStack (admin)")
                    }
                }
            }
        }
        else {
            if ($script:unreachTicks -gt 0) { Write-Ok ("公网已恢复 (曾中断 " + $script:unreachTicks + " 个周期)") }
            $script:unreachTicks = 0
        }

        # --- 信号弱 -> 漫游 (既有逻辑) ---
        $signal = $script:wlan.Signal
        if ($signal -lt 60 -and -not $NoFix) {
            Write-Warn ("[" + $ts + "] 信号弱 " + $signal + "%, 自动漫游...")
            $best = Get-BestSignalForSsid $script:wlan.Ssid
            if ($null -eq $best) {
                Write-Warn "扫描缓存中没有该 SSID, 本次跳过漫游。"
            }
            elseif ($best -le ($signal + 5)) {
                Write-Warn ("最强可见 AP 也只有 " + $best + "%, 无法改善, 跳过。")
            }
            else {
                $ssidW = $script:wlan.Ssid
                $script:wlan = Invoke-Reconnect -Ssid $ssidW
                if ($null -eq $script:wlan) { Write-Warn "无法读取链接状态 (WiFi 可能已关闭), 下轮再查" }
            }
        }
        else {
            $sig = $script:wlan.Signal
            Write-Host ("    [" + $ts + "] " + $script:wlan.Ssid + " 信号 " + $sig + "% (RSSI " + $script:wlan.Rssi + " dBm) ch" + $script:wlan.Channel + "  Rx " + $script:wlan.RxRate + " Mbps  [Q] 退出") -ForegroundColor DarkGray
        }
    }
    try {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Q') { Write-Host ""; Write-Step "用户退出守护"; break }
        }
    } catch {
        # 无交互控制台时忽略按键检测 (双击运行正常)
    }
    Start-Sleep -Seconds 15
}

if ($SpeedTest) {
    Write-Step "下载测速 (20 MB from Cloudflare)"
    $mbps = Test-DownloadSpeed
    if ($null -ne $mbps) {
        $mbps = [math]::Round($mbps, 1)
        Write-Info ("真实吞吐: " + $mbps + " Mbps")
        if ($mbps -lt 10)     { Write-Warn "非常慢, 可能是校园网出口拥塞或限速时段。" }
        elseif ($mbps -lt 30) { Write-Warn "中等偏慢, 校园网共享带宽繁忙。" }
        else                  { Write-Ok "吞吐不错。" }
        Save-SpeedLog $mbps
    } else { Write-Err "测速失败。" }
}
Write-Host ""
Write-Ok "Done."
