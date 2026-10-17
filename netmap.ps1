<#
netmap.ps1 - локальная интерактивная карта сети: адаптеры, маршруты, DNS, кто куда и через что ходит.

Запуск: netmap.cmd (или pwsh -File netmap.ps1). Откроется http://127.0.0.1:47900/
Только чтение: ничего не меняет в системе. Слушает ТОЛЬКО 127.0.0.1, наружу ничего не отправляет.
Кнопки на странице запускают разовые проверки: DNS всех серверов, внешний IP (curl на cloudflare), путь до домена/IP.

Источники данных: Get-NetAdapter/-NetRoute/-DnsClient*, netstat -ano, `netbird status --json`,
`tailscale status --json`, vpncli (AnyConnect), %LOCALAPPDATA%\Happ\routing.json, verge.yaml Clash Verge.
Защита локального API: проверка Host, обязательный заголовок X-NetMap (простой запрос с чужого сайта не пройдёт).
#>
param(
    [int]$Port = 47900,
    [switch]$NoBrowser
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    # запущен из Windows PowerShell 5.1 (двойной щелчок, «Выполнить с помощью PowerShell») - перезапускаемся в PowerShell 7
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pw) { foreach ($c in "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe", "$env:ProgramFiles\PowerShell\7\pwsh.exe") { if (Test-Path -LiteralPath $c) { $pw = $c; break } } }
    if ($pw) {
        $more = @(); if ($NoBrowser) { $more += '-NoBrowser' }
        & $pw -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Port $Port @more
        exit $LASTEXITCODE
    }
    Write-Host 'Нужен PowerShell 7 (pwsh), а он не найден. Установите его из Microsoft Store.' -ForegroundColor Red
    Read-Host 'Нажмите Enter, чтобы закрыть'
    exit 1
}
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
$Root = $PSScriptRoot
$HtmlFile = Join-Path $Root 'index.html'
$ConfigFile = Join-Path $Root 'netmap.config.json'

# Настройки (какие программы и адаптеры узнаёт карта) лежат в netmap.config.json; здесь они читаются и проверяются.
function Import-NetMapConfig {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Не найден файл настроек $ConfigFile. Верните его рядом со скриптом." }
    try { $c = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Файл настроек $ConfigFile не разобран как JSON: $($_.Exception.Message)" }
    function Test-Rx([string]$Rx, [string]$Where) {
        if ($Rx) { try { [void][regex]::new($Rx) } catch { throw "netmap.config.json: неверное регулярное выражение в «$Where»: $Rx" } }
    }
    $kinds = @($c.adapterKinds)
    if (-not $kinds.Count) { throw 'netmap.config.json: пуст список adapterKinds.' }
    $seen = @{}
    foreach ($k in $kinds) {
        if (-not $k.kind -or -not $k.label) { throw 'netmap.config.json: у каждого вида адаптера нужны поля kind и label.' }
        if ($k.kind -match '^(physical|proxy|other|dst|proc)$') { throw "netmap.config.json: имя вида «$($k.kind)» занято самой картой." }
        if ($seen[[string]$k.kind]) { throw "netmap.config.json: вид «$($k.kind)» указан дважды." }
        $seen[[string]$k.kind] = $true
        if (-not $k.nameRx -and -not $k.descRx) { throw "netmap.config.json: у вида «$($k.kind)» нужен nameRx или descRx." }
        Test-Rx ([string]$k.nameRx) "$($k.kind).nameRx"; Test-Rx ([string]$k.descRx) "$($k.kind).descRx"
    }
    foreach ($n in 'proxyRx', 'happRx', 'clashRx') { Test-Rx ([string]$c.processes.$n) "processes.$n" }
    Test-Rx ([string]$c.hotspotGatewayRx) 'hotspotGatewayRx'; Test-Rx ([string]$c.skipDnsServersRx) 'skipDnsServersRx'
    $ex = { param($s) [Environment]::ExpandEnvironmentVariables([string]$s) }
    $script:Cfg = $c
    $script:AdapterKinds = $kinds
    $script:VpnKinds = @($kinds | Where-Object { $_.vpn } | ForEach-Object { [string]$_.kind })
    $script:TunKinds = @($kinds | Where-Object { $_.tun } | ForEach-Object { [string]$_.kind })
    $script:ProxyProcRx = [string]$c.processes.proxyRx
    $script:HappProcRx = [string]$c.processes.happRx
    $script:ClashProcRx = [string]$c.processes.clashRx
    $script:HappRoutingFile = & $ex $c.paths.happRouting
    $script:ClashSettingsFile = & $ex $c.paths.clashVergeSettings
    $script:AnyConnectGlobs = @($c.paths.anyconnectCli | ForEach-Object { & $ex $_ })
    $script:AnyConnectService = if ($c.paths.anyconnectService) { [string]$c.paths.anyconnectService } else { 'vpnagent' }
    $script:TailscaleCandidates = @($c.paths.tailscaleCli | ForEach-Object { & $ex $_ })
    $script:LocalProxyPorts = @($c.localProxyPorts | ForEach-Object { [int]$_ })
    $script:HotspotGwRx = [string]$c.hotspotGatewayRx
    $script:SkipDnsRx = if ($c.skipDnsServersRx) { [string]$c.skipDnsServersRx } else { '^$^' }
    $script:InternetIp = if ($c.probes.internetIp) { [string]$c.probes.internetIp } else { '1.1.1.1' }
    $script:ControlZone = if ($c.probes.controlZone) { [string]$c.probes.controlZone } else { 'example.com' }
    $script:ExitUrl = if ($c.probes.exitUrl) { [string]$c.probes.exitUrl } else { 'https://www.cloudflare.com/cdn-cgi/trace' }
}

# ---------------------------------------------------------------- утилиты

$script:Cache = @{}
function Cached([string]$Key, [double]$Ttl, [scriptblock]$Fill) {
    $e = $script:Cache[$Key]
    if ($e -and ((Get-Date) - $e.T).TotalSeconds -lt $Ttl) { return $e.V }
    $v = & $Fill
    $script:Cache[$Key] = @{ T = Get-Date; V = $v }
    return $v
}

# Запуск внешней программы с таймаутом: зависший vpncli/netbird не должен вешать весь сервер
function Invoke-Native([string]$Exe, [string[]]$ArgList = @(), [string]$StdIn = $null, [int]$TimeoutMs = 5000) {
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in $ArgList) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if ($StdIn) { $p.StandardInput.WriteLine($StdIn) }
        $p.StandardInput.Close()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill($true) } catch { }
            return [pscustomobject]@{ Out = ''; Err = 'timeout'; Code = -1 }
        }
        [void]$so.Wait(1500)
        return [pscustomobject]@{ Out = [string]$so.Result; Err = [string]$se.Result; Code = $p.ExitCode }
    } catch {
        return [pscustomobject]@{ Out = ''; Err = $_.Exception.Message; Code = -2 }
    }
}

function ConvertTo-UInt([string]$Ip) { $b = [Net.IPAddress]::Parse($Ip).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
function Test-InCidr([string]$Ip, [string]$Cidr) {
    try {
        $parts = $Cidr -split '/'
        $bits = if ($parts.Count -gt 1) { [int]$parts[1] } else { 32 }
        if ($bits -eq 0) { return $true }
        $mask = [uint32]([uint64]4294967295 -shl (32 - $bits) -band 4294967295)
        return ((ConvertTo-UInt $Ip) -band $mask) -eq ((ConvertTo-UInt $parts[0]) -band $mask)
    } catch { return $false }
}

function Get-Route([string]$Ip) {
    Cached "rt:$Ip" 20 {
        $r = @(Find-NetRoute -RemoteIPAddress $Ip -ErrorAction SilentlyContinue)
        $rt = $r | Where-Object { $_.DestinationPrefix } | Select-Object -First 1
        [pscustomobject]@{ ip = $Ip; iface = [string]($r | Select-Object -First 1).InterfaceAlias; nextHop = [string]$rt.NextHop; prefix = [string]$rt.DestinationPrefix }
    }
}

function Resolve-Quick([string]$HostName) {
    # неудачный резолв не кэшируем, чтобы не залипать на пустом ответе
    $e = $script:Cache["dns:$HostName"]
    if ($e -and ((Get-Date) - $e.T).TotalSeconds -lt 120 -and @($e.V).Count) { return @($e.V) }
    $r = @()
    try {
        $t = [Net.Dns]::GetHostAddressesAsync($HostName)
        if ($t.Wait(4000)) { $r = @($t.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }) }
    } catch { }
    if ($r.Count) { $script:Cache["dns:$HostName"] = @{ T = Get-Date; V = $r } }
    return $r
}

# ---------------------------------------------------------------- адаптеры, маршруты, DNS

function Get-AdapterKind($a) {
    $d = [string]$a.InterfaceDescription; $n = [string]$a.Name
    foreach ($k in $script:AdapterKinds) {
        if (($k.nameRx -and $n -match [string]$k.nameRx) -or ($k.descRx -and $d -match [string]$k.descRx)) { return [string]$k.kind }
    }
    if ($a.HardwareInterface) { return 'physical' }
    return 'other'
}

function Get-Adapters {
    $nics = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' })
    $v4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $v6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue)
    $ifm = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $defs = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $stat = @{}; foreach ($st in @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) { $stat[[string]$st.Name] = $st }
    foreach ($a in $nics) {
        $kind = Get-AdapterKind $a
        $up = [string]$a.Status -eq 'Up'
        if (-not $up -and $VpnKinds -notcontains $kind) { continue }
        $idx = [int]$a.ifIndex
        $medium = if ($kind -eq 'physical') { if ([string]$a.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11') { 'wifi' } else { 'ethernet' } } else { '' }
        [ordered]@{
            name        = [string]$a.Name
            description = [string]$a.InterfaceDescription
            status      = [string]$a.Status
            ifIndex     = $idx
            kind        = $kind
            medium      = $medium
            ipv4        = @($v4 | Where-Object { $_.InterfaceIndex -eq $idx } | ForEach-Object { [string]$_.IPAddress })
            ipv6        = @($v6 | Where-Object { $_.InterfaceIndex -eq $idx -and $_.IPAddress -notmatch '^fe80' } | ForEach-Object { ([string]$_.IPAddress) -replace '%.*$', '' })
            metric      = [int](($ifm | Where-Object { $_.InterfaceIndex -eq $idx } | Select-Object -First 1).InterfaceMetric)
            dns         = @($dns | Where-Object { $_.InterfaceIndex -eq $idx } | ForEach-Object { $_.ServerAddresses } | ForEach-Object { [string]$_ })
            gateway     = [string](($defs | Where-Object { $_.InterfaceIndex -eq $idx -and $_.NextHop -ne '0.0.0.0' } | Select-Object -First 1).NextHop)
            speed       = [string]$a.LinkSpeed
            rxBytes     = [int64]($stat[[string]$a.Name].ReceivedBytes)
            txBytes     = [int64]($stat[[string]$a.Name].SentBytes)
        }
    }
}

function Get-Routes($Adapters) {
    $alias = @{}; $metric = @{}
    foreach ($a in $Adapters) { $alias[[int]$a.ifIndex] = $a.name; $metric[[int]$a.ifIndex] = [int]$a.metric }
    $all = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
        $ix = [int]$_.InterfaceIndex
        [pscustomobject]@{
            prefix = [string]$_.DestinationPrefix; nextHop = [string]$_.NextHop; routeMetric = [int]$_.RouteMetric
            ifIndex = $ix; iface = $(if ($alias.ContainsKey($ix)) { $alias[$ix] } else { "if$ix" })
            effective = [int]$_.RouteMetric + [int]$metric[$ix]
        }
    })
    $defaultPrefixes = '0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1'
    $defaults = @($all | Where-Object { $defaultPrefixes -contains $_.prefix } | Sort-Object effective)
    $notable = @($all | Where-Object { $_.prefix -notmatch '/32$' -and $_.prefix -notmatch '^(224\.|255\.|127\.|169\.254\.)' -and $defaultPrefixes -notcontains $_.prefix } |
        Sort-Object ifIndex, prefix | Select-Object -First 120)
    [ordered]@{ defaults = $defaults; notable = $notable; internet = (Get-Route $script:InternetIp) }
}

function Get-Nrpt {
    @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ namespaces = @($_.Namespace | ForEach-Object { [string]$_ } | Where-Object { $_ }); servers = @($_.NameServers | ForEach-Object { [string]$_ }); name = [string]$_.DisplayName }
    })
}

# ---------------------------------------------------------------- сокеты и процессы

function Get-Sockets {
    $r = Invoke-Native "$env:SystemRoot\System32\netstat.exe" @('-ano') $null 10000
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+(\S+):(\d+|\*)\s+(\w+)\s+(\d+)\s*$') {
            [pscustomobject]@{
                lip = ($Matches[1].Trim('[', ']') -replace '%.*$', ''); lport = [int]$Matches[2]
                rip = ($Matches[3].Trim('[', ']') -replace '%.*$', ''); rport = $(if ($Matches[4] -eq '*') { 0 } else { [int]$Matches[4] })
                state = $Matches[5]; pid = [int]$Matches[6]
            }
        }
    }
}

function Get-ProcMap {
    $m = @{}
    foreach ($p in [Diagnostics.Process]::GetProcesses()) { $m[[int]$p.Id] = $p.ProcessName; $p.Dispose() }
    $m
}

function Get-ProxyPorts($Sockets, $ProcMap) {
    @($Sockets | Where-Object { $_.state -eq 'LISTENING' -and $_.lip -match '^(127\.0\.0\.1|0\.0\.0\.0)$' -and ([string]$ProcMap[$_.pid]) -match $script:ProxyProcRx } |
        ForEach-Object { [ordered]@{ port = $_.lport; process = [string]$ProcMap[$_.pid] } } | Sort-Object { $_.port } -Unique)
}

function Get-DnsNames {
    Cached 'dnscache' 15 {
        $m = @{}
        try { foreach ($e in @(Get-DnsClientCache -ErrorAction SilentlyContinue)) { if ($e.Type -eq 1 -and $e.Data -and -not $m.ContainsKey([string]$e.Data)) { $m[[string]$e.Data] = [string]$e.Entry } } } catch { }
        $m
    }
}

function Get-Connections($Sockets, $ProcMap, $Adapters, $ProxyPorts) {
    $ipIface = @{}
    foreach ($a in $Adapters) { foreach ($i in (@($a.ipv4) + @($a.ipv6))) { if ($i) { $ipIface[[string]$i] = $a.name } } }
    $portSet = @($ProxyPorts | ForEach-Object { $_.port })
    $names = Get-DnsNames
    # второй конец TUN-пары (напр. 172.18.0.2 у Happ): сокеты sing-box к нему - внутренняя «сантехника», а не внешние соединения
    $tunPeers = @($Adapters | Where-Object { $_.kind -in $script:TunKinds -and $_.gateway } | ForEach-Object { $_.gateway })
    $physNames = @($Adapters | Where-Object { $_.kind -eq 'physical' } | ForEach-Object { $_.name })
    $byProc = @{}
    $local = 0
    foreach ($c in @($Sockets | Where-Object { $_.state -eq 'ESTABLISHED' })) {
        if ($tunPeers -contains $c.rip) { $local++; continue }
        $pn = [string]$ProcMap[$c.pid]; if (-not $pn) { $pn = "pid$($c.pid)" }
        $isLoopLocal = $c.lip -match '^127\.' -or $c.lip -eq '::1'
        if ($isLoopLocal) {
            $isLoopRemote = $c.rip -match '^127\.' -or $c.rip -eq '::1'
            if ($isLoopRemote -and $portSet -contains $c.rport) { $iface = "proxy:$($c.rport)" } else { $local++; continue }
        } else {
            $iface = $ipIface[$c.lip]; if (-not $iface) { $iface = 'unknown' }
        }
        if (-not $byProc.ContainsKey($pn)) { $byProc[$pn] = @{ name = $pn; total = 0; ifaces = @{}; remotes = @{} } }
        $e = $byProc[$pn]; $e.total++
        $e.ifaces[$iface] = 1 + [int]$e.ifaces[$iface]
        $rk = "$($c.rip):$($c.rport)|$iface"
        if (-not $e.remotes.ContainsKey($rk)) { $e.remotes[$rk] = @{ ip = $c.rip; port = $c.rport; iface = $iface; count = 0 } }
        $e.remotes[$rk].count++
    }
    $procs = @($byProc.Values | Sort-Object { $_.total } -Descending | ForEach-Object {
        $sorted = @($_.remotes.Values | Sort-Object { $_.count } -Descending)
        # топ по числу соединений + все, что вышло прямо через физический адаптер (для поиска реального выхода прокси)
        $pick = @($sorted | Select-Object -First 8) + @($sorted | Where-Object { $physNames -contains $_.iface } | Select-Object -First 6)
        $remotes = @($pick | Sort-Object { "$($_.ip):$($_.port)|$($_.iface)" } -Unique | Sort-Object { $_.count } -Descending | ForEach-Object {
            [ordered]@{ ip = $_.ip; port = $_.port; iface = $_.iface; count = $_.count; host = [string]$names[$_.ip] }
        })
        [ordered]@{ name = $_.name; total = $_.total; ifaces = $_.ifaces; remotes = $remotes }
    })
    [ordered]@{ processes = $procs; loopback = $local }
}

# ---------------------------------------------------------------- сервисы

function Get-HappInfo($ProcMap, $Adapters, $ProxyPorts) {
    $procs = @($ProcMap.Values | Where-Object { $script:HappProcRx -and $_ -match $script:HappProcRx } | Sort-Object -Unique)
    $info = [ordered]@{ running = ($procs.Count -gt 0); processes = $procs; tunUp = [bool]($Adapters | Where-Object { $_.kind -eq 'happ' -and $_.status -eq 'Up' }); routing = $null }
    $f = $script:HappRoutingFile
    if ($f -and (Test-Path -LiteralPath $f)) {
        try {
            $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $cand = @($o.routings) | Where-Object { $_.name -eq $o.activeRoutingName } | Select-Object -First 1
            if (-not $cand) { $cand = @($o.routings)[0] }
            if ($cand) {
                $info.routing = [ordered]@{
                    name = [string]$cand.name; globalProxy = [bool]$cand.globalProxy; routingOrder = [string]$cand.routingOrder
                    domainStrategy = [string]$cand.domainStrategy
                    directIp = @($cand.directIp | ForEach-Object { [string]$_ }); directSites = @($cand.directSites | ForEach-Object { [string]$_ })
                    proxyIp = @($cand.proxyIp | ForEach-Object { [string]$_ }); proxySites = @($cand.proxySites | ForEach-Object { [string]$_ })
                    blockIp = @($cand.blockIp | ForEach-Object { [string]$_ })
                    remoteDns = ('{0} {1}' -f $cand.remoteDnsType, $cand.remoteDnsIp).Trim(); domesticDns = ('{0} {1}' -f $cand.domesticDnsType, $cand.domesticDnsIp).Trim()
                }
            }
        } catch { }
    }
    $info
}

function Get-ClashInfo($ProcMap) {
    $running = [bool]($script:ClashProcRx -and ($ProcMap.Values | Where-Object { $_ -match $script:ClashProcRx }))
    $tun = $null; $sys = $null
    $f = $script:ClashSettingsFile
    if ($f -and (Test-Path -LiteralPath $f)) {
        $y = Get-Content -LiteralPath $f
        $tun = (($y | Where-Object { $_ -match '^enable_tun_mode:' }) -replace '^enable_tun_mode:\s*', '')
        $sys = (($y | Where-Object { $_ -match '^enable_system_proxy:' }) -replace '^enable_system_proxy:\s*', '')
    }
    [ordered]@{ running = $running; tunEnabled = ($tun -eq 'true'); systemProxyEnabled = ($sys -eq 'true'); configFound = ($null -ne $tun) }
}

function Get-SystemProxy {
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    [ordered]@{ enabled = ($ie.ProxyEnable -eq 1); server = [string]$ie.ProxyServer }
}

function Get-AnyConnectInfo {
    Cached 'anyconnect' 10 {
        $svc = Get-Service -Name $script:AnyConnectService -ErrorAction SilentlyContinue
        $cli = if ($script:AnyConnectGlobs.Count) { Get-ChildItem $script:AnyConnectGlobs -ErrorAction SilentlyContinue | Select-Object -First 1 }
        $info = [ordered]@{ installed = [bool]$cli; service = $(if ($svc) { [string]$svc.Status } else { 'нет' }); state = ''; recent = @(); server = ''; clientIp = ''; tunnelMode = '' }
        if ($cli -and $svc -and [string]$svc.Status -eq 'Running') {
            $st = Invoke-Native $cli.FullName @('-s') 'state' 5000
            $lines = @(($st.Out -split "`r?`n") | Where-Object { $_ -match 'state:\s*(\S+)' } | ForEach-Object { [regex]::Match($_, 'state:\s*(\S+)').Groups[1].Value })
            if ($lines.Count) { $info.state = $lines[-1]; $info.recent = @($lines | Select-Object -Last 8) }
            $ss = Invoke-Native $cli.FullName @('-s') 'stats' 5000
            foreach ($l in ($ss.Out -split "`r?`n")) {
                if ($l -match 'Server Address:\s*(\S+)') { $info.server = $Matches[1] }
                elseif ($l -match 'Client Address \(IPv4\):\s*(\S+)') { $info.clientIp = $Matches[1] }
                elseif ($l -match 'Tunnel Mode \(IPv4\):\s*(.+)$') { $info.tunnelMode = $Matches[1].Trim() }
            }
        } elseif ($cli) { $info.state = 'служба не запущена' }
        $info
    }
}

function ConvertTo-Ms($v) {
    $ms = ConvertTo-MsRaw $v
    if ($null -ne $ms -and $ms -gt 0) { return $ms }
    return $null      # "0s" у NetBird значит «задержка не измерена» (relay), а не 0 мс
}
function ConvertTo-MsRaw($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [string]) {
        if ($v -match '^([\d.]+)\s*ms$') { return [math]::Round([double]$Matches[1], 1) }
        if ($v -match '^([\d.]+)\s*(µs|us)$') { return [math]::Round([double]$Matches[1] / 1000, 2) }
        if ($v -match '^([\d.]+)\s*s$') { return [math]::Round([double]$Matches[1] * 1000, 1) }
        return $null
    }
    try { return [math]::Round([double]$v / 1e6, 1) } catch { return $null }   # наносекунды
}

function Get-NetBirdInfo {
    Cached 'netbird' 3 {
        $exe = (Get-Command netbird -ErrorAction SilentlyContinue).Source
        if (-not $exe) { return [ordered]@{ installed = $false } }
        $r = Invoke-Native $exe @('status', '--json') $null 8000
        $o = $null
        try { $o = $r.Out | ConvertFrom-Json } catch { }
        if (-not $o) {
            $first = (($r.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            return [ordered]@{ installed = $true; daemonStatus = [string]$first; peers = @(); relays = @(); management = $null; signal = $null }
        }
        [ordered]@{
            installed = $true; daemonStatus = [string]$o.daemonStatus; ip = [string]$o.netbirdIp; fqdn = [string]$o.fqdn; version = [string]$o.daemonVersion
            management = [ordered]@{ url = [string]$o.management.url; connected = [bool]$o.management.connected; error = [string]$o.management.error }
            signal = [ordered]@{ url = [string]$o.signal.url; connected = [bool]$o.signal.connected; error = [string]$o.signal.error }
            relays = @($o.relays.details | ForEach-Object { [ordered]@{ uri = [string]$_.uri; available = [bool]$_.available; error = [string]$_.error } })
            peerTotal = [int]$o.peers.total; peerConnected = [int]$o.peers.connected
            peers = @($o.peers.details | ForEach-Object {
                [ordered]@{
                    name = ([string]$_.fqdn -split '\.')[0]; fqdn = [string]$_.fqdn; ip = [string]$_.netbirdIp; status = [string]$_.status
                    type = [string]$_.connectionType; endpoint = [string]$_.iceCandidateEndpoint; candidate = [string]$_.iceCandidateType
                    relay = [string]$_.relayAddress; latencyMs = (ConvertTo-Ms $_.latency)
                    handshake = [string]$_.lastWireguardHandshake; rx = $_.transferReceived; tx = $_.transferSent
                }
            })
        }
    }
}

function Get-TailscaleInfo {
    Cached 'tailscale' 5 {
        $exe = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
        if (-not $exe) { foreach ($cand in $script:TailscaleCandidates) { $f = Get-Item -LiteralPath $cand -ErrorAction SilentlyContinue; if ($f) { $exe = $f.FullName; break } } }
        if (-not $exe) { return [ordered]@{ installed = $false } }
        $r = Invoke-Native $exe @('status', '--json') $null 8000
        $o = $null
        try { $o = $r.Out | ConvertFrom-Json } catch { }
        if (-not $o) { return [ordered]@{ installed = $true; backend = 'нет ответа'; peers = @() } }
        [ordered]@{
            installed = $true; backend = [string]$o.BackendState; ips = @($o.TailscaleIPs | Where-Object { $_ } | ForEach-Object { [string]$_ })
            self = [string]$o.Self.HostName; tailnet = [string]$o.CurrentTailnet.Name; health = @($o.Health | Where-Object { $_ } | ForEach-Object { [string]$_ })
            exitNode = [bool]($o.ExitNodeStatus)
            peers = @($(if ($o.Peer) { $o.Peer.PSObject.Properties }) | ForEach-Object {
                $p = $_.Value
                [ordered]@{ name = [string]$p.HostName; ip = [string](@($p.TailscaleIPs) | Select-Object -First 1); online = [bool]$p.Online; relay = [string]$p.Relay; addr = [string]$p.CurAddr; exitNode = [bool]$p.ExitNode; os = [string]$p.OS }
            })
        }
    }
}

# ---------------------------------------------------------------- замечания (правила)

$script:LastDns = $null

function Get-Problems($S) {
    $list = [Collections.Generic.List[object]]::new()
    function Add-P([string]$Level, [string]$Title, [string]$Detail) { $list.Add([ordered]@{ level = $Level; title = $Title; detail = $Detail }) }
    $up = @($S.adapters | Where-Object { $_.status -eq 'Up' })
    $phys = @($up | Where-Object { $_.kind -eq 'physical' } | Sort-Object { $_.metric })
    $tuns = @($up | Where-Object { $_.kind -in $script:TunKinds })
    $isTunIface = { param($n) [bool]($up | Where-Object { $_.name -eq $n -and $_.kind -in $script:TunKinds }) }

    if ($phys.Count) {
        $gw = [string]($phys | Where-Object { $_.gateway } | Select-Object -First 1).gateway
        if ($script:HotspotGwRx -and $gw -match $script:HotspotGwRx) { Add-P 'info' 'Выход в интернет через раздачу с телефона' "Шлюз $gw похож на точку доступа телефона (мобильный оператор). DNS и качество канала зависят от неё." }
    }
    $inet = $S.routes.internet
    if ($inet -and $inet.iface) { Add-P 'info' "Интернет по умолчанию идёт через: $($inet.iface)" "Маршрут до $($script:InternetIp): интерфейс «$($inet.iface)», следующий узел $($inet.nextHop), правило $($inet.prefix)." }

    if ($tuns.Count -gt 1) { Add-P 'warn' "Одновременно активны два TUN-VPN: $(($tuns | ForEach-Object { $_.name }) -join ', ')" 'Два перехватчика трафика мешают друг другу: маршруты, DNS и fake-IP могут конфликтовать. Оставьте один.' }

    $ac = $S.services.anyconnect
    $acIf = @($up | Where-Object { $_.kind -eq 'anyconnect' }) | Select-Object -First 1
    if ($ac.installed -and $acIf) {
        if ($ac.state -and $ac.state -ne 'Connected') {
            Add-P 'bad' "AnyConnect: состояние $($ac.state)" "Адаптер «$($acIf.name)» поднят, но VPN не в состоянии Connected. Его DNS ($($acIf.dns -join ', ')) имеют метрику $($acIf.metric) и опрашиваются раньше остальных — возможны таймауты резолва имён по всей системе."
        }
        $rec = @($ac.recent | Where-Object { $_ -match 'Reconnect' })
        if ($rec.Count -ge 2) { Add-P 'warn' "AnyConnect часто переподключается ($($rec.Count) раз(а) в последних состояниях)" "История состояний: $($ac.recent -join ' → ')." }
        if ($ac.server) {
            $rt = Get-Route $ac.server
            if ($rt.iface -and (& $isTunIface $rt.iface)) { Add-P 'warn' "Туннель AnyConnect идёт через $($rt.iface)" "Шлюз AnyConnect $($ac.server) достигается через «$($rt.iface)» — то есть сам VPN едет внутри другого VPN/прокси. Это нестабильно; добавьте $($ac.server) в прямые правила Happ/Clash." }
        }
    }

    $nb = $S.services.netbird
    if ($nb.installed) {
        $nbMs = if ($nb.management) { $nb.management.connected } else { $false }
        if ($nb.daemonStatus -match 'LoginFailed|NeedsLogin|SessionExpired') { Add-P 'bad' "NetBird требует входа ($($nb.daemonStatus))" 'Выполните «netbird up» и пройдите вход (или используйте setup-key).' }
        elseif ($nb.management -and -not $nbMs) { Add-P 'bad' 'NetBird: нет связи с Management' "$($nb.management.error)" }
        elseif ($nb.signal -and -not $nb.signal.connected) { Add-P 'bad' 'NetBird: нет связи с Signal' "$($nb.signal.error)" }
        $badRelays = @($nb.relays | Where-Object { -not $_.available })
        if ($badRelays.Count) { Add-P 'warn' "NetBird: недоступно relay/STUN — $($badRelays.Count) из $(@($nb.relays).Count)" (($badRelays | ForEach-Object { "$($_.uri) $($_.error)" }) -join '; ') }
        if (($badRelays | Where-Object { $_.uri -match '^stun:' }) -and $tuns.Count) { Add-P 'info' 'STUN (UDP) недоступен при включённом TUN-VPN' 'UDP через Happ/Clash-прокси обычно не проходит, поэтому прямые P2P-соединения NetBird невозможны — пиры идут через relay (медленнее).' }
        $conn = @($nb.peers | Where-Object { $_.status -eq 'Connecting' })
        if ($conn.Count) { Add-P 'info' "NetBird: пиры в состоянии Connecting — $($conn.Count)" (($conn | ForEach-Object { $_.name }) -join ', ') }
        if ($nb.management -and $nb.management.url -match '//([^/:]+)') {
            $hostName = $Matches[1]
            $ip = Resolve-Quick $hostName | Select-Object -First 1
            if ($ip) { $rt = Get-Route $ip; if ($rt.iface -and (& $isTunIface $rt.iface)) { Add-P 'info' "Связь NetBird с сервером идёт через $($rt.iface)" "Сервер $hostName ($ip) достигается через «$($rt.iface)». Без этого VPN клиент ходил бы к серверу напрямую." } }
        }
    }

    # домен самого сервера NetBird не должен попадать под NRPT-правило NetBird: иначе при обрыве клиент не разрешит адрес сервера
    if ($nb.installed -and $nb.management -and ([string]$nb.management.url) -match '//([^/:]+)') {
        $mgmtHost = $Matches[1]
        foreach ($rule in $S.dns.nrpt) {
            foreach ($ns in $rule.namespaces) {
                $sfx = ([string]$ns).TrimStart('.')
                if ($sfx -and ($mgmtHost -eq $sfx -or $mgmtHost.EndsWith(".$sfx"))) {
                    Add-P 'warn' "Домен сервера NetBird ($mgmtHost) попадает под NRPT-правило $ns → DNS $($rule.servers -join ', ')" 'Windows отправляет запросы этого домена на DNS самого NetBird. Пока туннель не работает или его DNS молчит, клиент не может заново разрешить адрес своего сервера и не переподключается. Лечится записью сервера в hosts либо отдельным DNS-доменом для пиров на стороне сервера.'
                }
            }
        }
    }

    if ($S.dns.check) {
        $minMetric = ($S.dns.check | Where-Object { $_.ok } | Measure-Object -Property metric -Minimum).Minimum
        foreach ($g in ($S.dns.check | Group-Object server)) {
            $okAny = [bool]($g.Group | Where-Object { $_.ok })
            if (-not $okAny) {
                $first = $g.Group[0]
                $lvl = if ($null -ne $minMetric -and [int]$first.metric -lt [int]$minMetric) { 'bad' } else { 'warn' }
                $caveat = if ($tuns.Count) { ' Внимание: при включённом TUN-VPN (Happ/Clash) он перехватывает DNS-трафик на порт 53, поэтому «молчание» серверов вне туннеля может быть ложным. Для чистой проверки выключите TUN.' } else { '' }
                Add-P $lvl "DNS-сервер $($g.Name) не отвечает (адаптер «$($first.adapter)», метрика $($first.metric))" ('Windows спрашивает DNS в порядке метрик интерфейсов; мёртвый сервер с низкой метрикой замедляет и ломает резолв.' + $caveat)
            }
        }
    }

    $happ = $S.services.happ
    if ($happ.running -and -not $happ.tunUp -and -not $S.services.systemProxy.enabled) { Add-P 'info' 'Happ запущен, но TUN не поднят' 'Процессы Happ работают, адаптера happ-tun нет и системный прокси выключен — трафик идёт мимо Happ (кроме приложений с явным прокси).' }
    if ($S.services.clash.tunEnabled -and -not ($up | Where-Object { $_.kind -eq 'clash' })) { Add-P 'info' 'Clash Verge: TUN включён в настройках, но адаптера нет' 'Ядро ещё не подняло TUN или сервис остановлен.' }
    if ($S.services.systemProxy.enabled) { Add-P 'info' "Включён системный прокси Windows: $($S.services.systemProxy.server)" 'Приложения, читающие системный прокси (браузеры, WinINET), идут через него независимо от маршрутов.' }
    $ts = $S.services.tailscale
    if ($ts.installed -and $ts.backend -and $ts.backend -ne 'Running') { Add-P 'warn' "Tailscale: $($ts.backend)" 'Клиент не в состоянии Running.' }
    foreach ($h in @($ts.health)) { if ($h) { Add-P 'info' 'Tailscale сообщает' $h } }
    ,$list.ToArray()
}

# ---------------------------------------------------------------- состояние

function Get-State {
    Cached 'state' 2 {
        $adapters = @(Get-Adapters)
        $routes = Get-Routes $adapters
        $sockets = @(Get-Sockets)
        $pm = Get-ProcMap
        $proxyPorts = @(Get-ProxyPorts $sockets $pm)
        $services = [ordered]@{
            happ = Get-HappInfo $pm $adapters $proxyPorts; clash = Get-ClashInfo $pm; systemProxy = Get-SystemProxy
            anyconnect = Get-AnyConnectInfo; tailscale = Get-TailscaleInfo; netbird = Get-NetBirdInfo
        }
        $dnsServers = @($adapters | Where-Object { $_.status -eq 'Up' -and $_.dns.Count } | Sort-Object { $_.metric } | ForEach-Object {
            $a = $_
            foreach ($d in $a.dns) { $rt = Get-Route $d; [ordered]@{ ip = $d; adapter = $a.name; metric = $a.metric; via = $rt.iface; nextHop = $rt.nextHop } }
        })
        $endpoints = [Collections.Generic.List[object]]::new()
        $nb = $services.netbird
        if ($nb.installed -and $nb.management -and $nb.management.url -match '//([^/:]+)') {
            $ip = Resolve-Quick $Matches[1] | Select-Object -First 1
            if ($ip) { $rt = Get-Route $ip; $endpoints.Add([ordered]@{ id = 'netbird-control'; label = "NetBird сервер $ip"; ip = $ip; via = $rt.iface; nextHop = $rt.nextHop }) }
        }
        if ($services.anyconnect.server) { $rt = Get-Route $services.anyconnect.server; $endpoints.Add([ordered]@{ id = 'anyconnect-gateway'; label = "Шлюз AnyConnect $($services.anyconnect.server)"; ip = $services.anyconnect.server; via = $rt.iface; nextHop = $rt.nextHop }) }
        $state = [ordered]@{
            ts = (Get-Date).ToString('o'); host = $env:COMPUTERNAME; adapters = $adapters; routes = $routes
            kinds = @($script:AdapterKinds | ForEach-Object { [ordered]@{ kind = [string]$_.kind; label = [string]$_.label; color = [string]$_.color; tun = [bool]$_.tun; vpn = [bool]$_.vpn } })
            localProxyPorts = $script:LocalProxyPorts
            dns = [ordered]@{ servers = $dnsServers; nrpt = @(Get-Nrpt); check = $(if ($script:LastDns -and ((Get-Date) - $script:LastDns.T).TotalSeconds -lt 300) { $script:LastDns.R } else { $null }) }
            proxies = $proxyPorts; connections = (Get-Connections $sockets $pm $adapters $proxyPorts); services = $services; endpoints = @($endpoints)
        }
        $state.problems = Get-Problems $state
        $state
    }
}

# ---------------------------------------------------------------- разовые проверки

function Invoke-DnsCheck {
    $st = Get-State
    $servers = @($st.dns.servers | Where-Object { $_.ip -notmatch $script:SkipDnsRx })      # DNS NetBird/Tailscale (100.x) отвечают только за свои имена
    $names = @($script:ControlZone)
    $nb = $st.services.netbird
    if ($nb.installed -and $nb.management -and $nb.management.url -match '//([^/:]+)') { $names += $Matches[1] }
    $res = @($servers | ForEach-Object -Parallel {
        $s = $_
        foreach ($n in $using:names) {
            $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $err = ''; $ans = @()
            try {
                $r = @(Resolve-DnsName -Name $n -Type A -Server $s.ip -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })
                $ok = $r.Count -gt 0; $ans = @($r | ForEach-Object { [string]$_.IPAddress })
            } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ server = $s.ip; adapter = $s.adapter; metric = $s.metric; via = $s.via; name = $n; ok = $ok; ms = $sw.ElapsedMilliseconds; answer = $ans; error = $err }
        }
    } -ThrottleLimit 8)
    $script:LastDns = @{ T = Get-Date; R = $res }
    $script:Cache.Remove('state')
    $res
}

function Invoke-ExitCheck {
    $st = Get-State
    $targets = @([ordered]@{ label = 'напрямую (как решит маршрутизация Windows)'; proxy = '' })
    foreach ($p in $st.proxies) { $targets += [ordered]@{ label = "через локальный прокси :$($p.port) ($($p.process))"; proxy = "http://127.0.0.1:$($p.port)" } }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    foreach ($t in $targets) {
        $a = @('-s', '-m', '8')
        if ($t.proxy) { $a += @('-x', $t.proxy) } else { $a += @('--noproxy', '*') }
        $a += $script:ExitUrl
        $r = Invoke-Native $curl $a $null 12000
        $ip = if ($r.Out -match '(?m)^ip=(\S+)') { $Matches[1] } else { '' }
        $loc = if ($r.Out -match '(?m)^loc=(\w+)') { $Matches[1] } else { '' }
        $colo = if ($r.Out -match '(?m)^colo=(\w+)') { $Matches[1] } else { '' }
        [ordered]@{ label = $t.label; ip = $ip; country = $loc; colo = $colo; ok = [bool]$ip }
    }
}

function Invoke-Trace([string]$Target) {
    $t = $Target.Trim()
    if ($t -notmatch '^[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?$') { return [ordered]@{ error = 'Допустимы имя домена или IPv4-адрес (буквы, цифры, точки, дефисы).' } }
    $ipObj = $null
    $isIp = [Net.IPAddress]::TryParse($t, [ref]$ipObj) -and $ipObj.AddressFamily -eq 'InterNetwork'
    $st = Get-State
    $res = [ordered]@{ target = $t; isIp = $isIp; system = $null; perServer = @(); nrpt = $null; order = @(); hops = @(); probe = $null }

    $ips = @()
    if ($isIp) { $ips = @($t) } else {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = @(Resolve-DnsName -Name $t -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
            $ips = @($r | ForEach-Object { [string]$_.IPAddress } | Select-Object -Unique)
            $res.system = [ordered]@{ ips = $ips; ms = $sw.ElapsedMilliseconds; error = '' }
        } catch { $res.system = [ordered]@{ ips = @(); ms = $sw.ElapsedMilliseconds; error = $_.Exception.Message } }

        $servers = @($st.dns.servers | Where-Object { $_.ip -notmatch $script:SkipDnsRx })
        $res.perServer = @($servers | ForEach-Object -Parallel {
            $s = $_; $sw2 = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $ans = @(); $err = ''
            try { $r = @(Resolve-DnsName -Name $using:t -Type A -Server $s.ip -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress }); $ok = $r.Count -gt 0; $ans = @($r | ForEach-Object { [string]$_.IPAddress }) } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ server = $s.ip; adapter = $s.adapter; metric = $s.metric; via = $s.via; ok = $ok; ms = $sw2.ElapsedMilliseconds; answer = $ans; error = $err }
        } -ThrottleLimit 8)
        # какое правило NRPT перехватывает имя
        foreach ($rule in $st.dns.nrpt) {
            foreach ($ns in $rule.namespaces) {
                $suffix = $ns.TrimStart('.')
                if ($suffix -and ($t -eq $suffix -or $t.EndsWith(".$suffix"))) { $res.nrpt = [ordered]@{ namespace = $ns; servers = $rule.servers }; break }
            }
            if ($res.nrpt) { break }
        }
        $res.order = @($st.dns.servers | ForEach-Object { "{0} (адаптер «{1}», метрика {2}, достижим через «{3}»)" -f $_.ip, $_.adapter, $_.metric, $_.via })
    }

    foreach ($ip in ($ips | Select-Object -First 3)) { $res.hops += Get-RouteDecision $st $ip }

    $first = $ips | Select-Object -First 1
    if ($first) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $sw3 = [Diagnostics.Stopwatch]::StartNew()
        $tcp = [Net.Sockets.TcpClient]::new(); $tcpOk = $false; $tcpErr = ''
        try { $c = $tcp.ConnectAsync($first, 443); if ($c.Wait(4000) -and $tcp.Connected) { $tcpOk = $true } else { $tcpErr = 'нет ответа за 4 с' } } catch { $tcpErr = $_.Exception.GetBaseException().Message } finally { $tcp.Dispose() }
        $tcpMs = $sw3.ElapsedMilliseconds
        $cr = Invoke-Native $curl @('-s', '-m', '8', '--noproxy', '*', '-k', '-o', 'NUL', '-w', '%{http_code}|%{time_connect}|%{time_appconnect}|%{time_total}|%{remote_ip}', "https://$t/") $null 12000
        $p = ([string]$cr.Out).Trim() -split '\|'
        $res.probe = [ordered]@{
            tcp443 = [ordered]@{ ip = $first; ok = $tcpOk; ms = $tcpMs; error = $tcpErr }
            https = [ordered]@{ code = $p[0]; connectSec = $p[1]; tlsSec = $p[2]; totalSec = $p[3]; remoteIp = $p[4]; ok = ($p[0] -match '^[1-5]\d\d$'); curlExit = $cr.Code }
        }
    }
    $res
}

# ---------------------------------------------------------------- план переопределения связи
# Только показывает, ЧТО нужно изменить и КАК это откатить. Ничего не применяет и ничего не пишет в систему.

function ConvertTo-PsStr([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function Get-RouteDecision($St, [string]$Ip) {
    $happ = $St.services.happ
    $rt = Get-Route $Ip
    $viaKind = [string](($St.adapters | Where-Object { $_.name -eq $rt.iface } | Select-Object -First 1).kind)
    $decision = ''
    if ($viaKind -eq 'happ') {
        $r = $happ.routing
        if ($r) {
            $direct = [bool]($r.directIp | Where-Object { Test-InCidr $Ip $_ })
            $proxy = [bool]($r.proxyIp | Where-Object { Test-InCidr $Ip $_ })
            $block = [bool]($r.blockIp | Where-Object { Test-InCidr $Ip $_ })
            $decision = if ($block) { "Happ («$($r.name)»): блокировка (blockIp)" }
                        elseif ($direct) { "Happ («$($r.name)»): напрямую (попадает в directIp)" }
                        elseif ($proxy) { "Happ («$($r.name)»): через прокси (proxyIp)" }
                        elseif ($r.globalProxy) { "Happ («$($r.name)»): через прокси (globalProxy включён, в directIp нет). Правила по доменам (directSites/geosite) здесь не вычисляются." }
                        else { "Happ («$($r.name)»): по правилам профиля ($($r.routingOrder)); геоправила здесь не вычисляются." }
        } else { $decision = 'Трафик попадает в Happ TUN; профиль маршрутизации прочитать не удалось.' }
    } elseif ($viaKind -eq 'clash') { $decision = 'Трафик попадает в Clash (Meta TUN); решение по правилам Clash здесь не вычисляется.' }
    elseif ($viaKind) { $decision = 'Идёт мимо Happ и Clash.' }
    [ordered]@{ ip = $Ip; iface = $rt.iface; kind = $viaKind; nextHop = $rt.nextHop; prefix = $rt.prefix; decision = $decision }
}

function New-Plan([string]$Target, [string]$Via, [string]$Proc) {
    $st = Get-State
    $res = [ordered]@{ readOnly = $true; target = $Target; proc = $Proc; via = $Via; viaKind = ''; error = ''; summary = ''; items = @(); warnings = @(); notes = @(); options = @(); verify = @() }
    $va = $st.adapters | Where-Object { $_.name -eq $Via } | Select-Object -First 1
    if (-not $va) { $res.error = "Интерфейс «$Via» не найден среди адаптеров."; return $res }
    $res.viaKind = [string]$va.kind
    if ([string]$va.status -ne 'Up') { $res.error = "Интерфейс «$Via» сейчас не поднят (состояние $($va.status)): направить трафик через него нельзя."; return $res }

    # --- что именно направляем: адреса
    $raw = [Collections.Generic.List[object]]::new()      # { ip; bits; host; port }
    $domain = ''
    if ($Proc) {
        if ($Proc -notmatch '^[\w.\- ]{1,64}$') { $res.error = 'Недопустимое имя процесса.'; return $res }
        $p = @($st.connections.processes | Where-Object { $_.name -eq $Proc }) | Select-Object -First 1
        if (-not $p) { $res.error = "У процесса «$Proc» сейчас нет активных соединений: направлять нечего."; return $res }
        $seen = @{}
        foreach ($r in @($p.remotes)) {
            if ($r.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or $r.ip -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' -or $seen[$r.ip]) { continue }
            $seen[$r.ip] = $true; $raw.Add([pscustomobject]@{ ip = $r.ip; bits = 32; host = [string]$r.host; port = [int]$r.port })
            if ($raw.Count -ge 6) { break }
        }
        if (-not $raw.Count) { $res.error = "У процесса «$Proc» нет внешних IPv4-адресов среди текущих соединений (только локальные или IPv6)."; return $res }
        $res.notes += 'Windows выбирает маршрут по адресу назначения, а не по процессу. Поэтому ниже план для адресов, к которым процесс подключён сейчас: он коснётся всех программ, которые ходят на эти же адреса. Для настоящего «по программе» см. варианты в конце.'
    } else {
        $t = $Target.Trim()
        if ($t -notmatch '^[A-Za-z0-9]([A-Za-z0-9._/-]{0,251}[A-Za-z0-9])?$') { $res.error = 'Допустимы домен, IPv4-адрес или подсеть вида 203.0.113.0/24.'; return $res }
        if ($t -match '^(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?$') {
            $ipText = $Matches[1]; $bitsText = $Matches[2]
            $ipObj = $null
            if (-not [Net.IPAddress]::TryParse($ipText, [ref]$ipObj)) { $res.error = "Неверный IPv4-адрес: $t"; return $res }
            $bits = if ($bitsText) { [int]$bitsText } else { 32 }
            if ($bits -gt 32) { $res.error = "Неверная длина префикса: /$bits"; return $res }
            if ($bits -lt 8) { $res.error = "Подсеть /$bits слишком широкая: это почти весь интернет. Канал по умолчанию меняют метриками интерфейсов (Set-NetIPInterface -InterfaceMetric) или включением и выключением VPN, а не маршрутом на такую подсеть."; return $res }
            $raw.Add([pscustomobject]@{ ip = $ipText; bits = $bits; host = ''; port = 0 })
        } elseif ($t -match '/') { $res.error = 'Подсеть записывается только числами, например 203.0.113.0/24.'; return $res }
        else {
            $domain = $t
            $ips = @(Resolve-Quick $t | Select-Object -First 6)
            if (-not $ips.Count) { $res.error = "Имя «$t» не разрешилось: нечего направлять. Проверьте имя и вкладку «Проверки»."; return $res }
            foreach ($ip in $ips) { $raw.Add([pscustomobject]@{ ip = $ip; bits = 32; host = $t; port = 0 }) }
            $res.notes += 'Адреса домена могут меняться и быть общими с другими сайтами (CDN). Маршрут по адресу держится, пока адрес тот же; надёжнее правило по домену в самом VPN-клиенте (варианты ниже).'
        }
    }

    # --- как идёт сейчас
    $items = @(); $todo = @()
    foreach ($r in $raw) {
        $d = Get-RouteDecision $st $r.ip
        $prefix = "$($r.ip)/$($r.bits)"
        $already = ($d.iface -eq $Via)
        $ep = @($st.endpoints | Where-Object { $_.ip -eq $r.ip }) | Select-Object -First 1
        $it = [ordered]@{ ip = $r.ip; prefix = $prefix; host = $r.host; port = $r.port; currentIface = $d.iface; currentKind = $d.kind; nextHop = $d.nextHop; routePrefix = $d.prefix; decision = $d.decision; already = $already; role = $(if ($ep) { [string]$ep.label } else { '' }) }
        $items += $it
        if (-not $already) { $todo += $it }
        if ($ep) { $res.warnings += [ordered]@{ level = 'info'; text = "$($r.ip) — это «$($ep.label)». Сейчас он достижим через «$($d.iface)»." } }
        if ($r.ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { $res.warnings += [ordered]@{ level = 'warn'; text = "$prefix — локальный или корпоративный адрес: маршрут на него может отрезать доступ к внутренней сети." } }
    }
    $res.items = $items
    $cur = @($items | ForEach-Object { $_.currentIface } | Select-Object -Unique) -join ', '
    $what = if ($Proc) { "трафик процесса «$Proc» ($($items.Count) адр.)" } elseif ($domain) { "«$domain» ($($items.Count) адр.)" } else { "«$($items[0].prefix)»" }
    if (-not $todo.Count) {
        $res.summary = "Уже так и есть: $what идёт через «$Via». Менять нечего."
        $res.verify = @("Find-NetRoute -RemoteIPAddress $(ConvertTo-PsStr $items[0].ip) | Select-Object -First 1 -ExpandProperty InterfaceAlias")
        return $res
    }
    $res.summary = "Хотите, чтобы $what шёл через «$Via» ($($va.kind)) вместо «$cur»."

    # --- предупреждения
    $vk = [string]$va.kind
    $isTunVia = $vk -in $script:TunKinds
    $curKinds = @($todo | ForEach-Object { $_.currentKind } | Select-Object -Unique)
    $res.warnings += [ordered]@{ level = 'info'; text = 'Новый путь получат новые соединения; уже открытые остаются на старом пути, пока их не переоткроют.' }
    $res.warnings += [ordered]@{ level = 'warn'; text = 'Если сейчас этот адрес держит ваш SSH-сеанс, туннель или NetBird, соединение оборвётся на время переключения. Применяйте сначала пробный вариант с откатом через 60 с.' }
    if ($vk -eq 'physical' -and -not $va.gateway) { $res.warnings += [ordered]@{ level = 'warn'; text = "У «$Via» нет шлюза по умолчанию; в командах следующий узел 0.0.0.0 (адрес достижим напрямую). Проверьте, что это верно." } }
    if ($isTunVia) { $res.warnings += [ordered]@{ level = 'info'; text = "«$Via» — TUN-VPN: адрес окажется внутри VPN-цепочки, его видимый внешний IP и страна изменятся." } }
    if ($curKinds -contains 'anyconnect' -or $vk -eq 'anyconnect') { $res.warnings += [ordered]@{ level = 'warn'; text = 'AnyConnect сам управляет своими маршрутами (Split Include и Exclude приходят с корпоративного шлюза). Локальный маршрут может быть удалён или перебит при его переподключении; постоянное решение — политика на шлюзе, не на этом ПК.' } }
    if (($curKinds | Where-Object { $_ -in $script:TunKinds }) -and $vk -eq 'physical') { $res.warnings += [ordered]@{ level = 'info'; text = 'Маршрут /32 на физический адаптер побеждает маршруты TUN (длиннейший префикс). Если TUN-клиент включил строгую защиту маршрутов (strict route), правило может не сработать: проверьте шагом «Проверка».' } }
    if ($vk -ne 'physical' -and -not $isTunVia -and $vk -ne 'anyconnect') { $res.warnings += [ordered]@{ level = 'info'; text = "Для «$Via» следующий узел в командах взят из адаптера; у виртуальных адаптеров он зависит от клиента, поэтому проверьте результат шагом «Проверка»." } }

    # --- варианты применения
    $nh = if ($va.gateway) { [string]$va.gateway } else { '0.0.0.0' }
    $idx = [int]$va.ifIndex
    $pfx = @($todo | ForEach-Object { $_.prefix })
    $sc = Get-RouteScripts $idx $nh $pfx
    $opt = @()
    $opt += [ordered]@{
        id = 'route-trial'; title = 'Маршрут Windows — пробный, сам удалится через 60 секунд'; admin = $true
        how = 'PowerShell от администратора. Добавляет маршрут, ждёт 60 с (за это время проверьте путь), затем удаляет. Безопасный первый шаг.'
        persists = 'нет: исчезает через 60 с'; commands = @($sc.trial); rollback = @($sc.rollback)
    }
    $opt += [ordered]@{
        id = 'route-keep'; title = 'Маршрут Windows — оставить до перезагрузки'; admin = $true
        how = 'PowerShell от администратора. Маршрут в активной таблице (ActiveStore).'
        persists = 'до перезагрузки или сброса интерфейса; VPN-клиент может удалить или перебить его при переподключении'; commands = @($sc.keep); rollback = @($sc.rollback)
    }
    $happ = $st.services.happ; $clash = $st.services.clash
    $happPresent = $happ.running -or [bool]($st.adapters | Where-Object { $_.kind -eq 'happ' })
    if ($happPresent -and ($vk -eq 'physical' -or $vk -eq 'happ')) {
        $field = if ($vk -eq 'physical') { 'directIp' } else { 'proxyIp' }
        $r = $happ.routing
        $already = @(); if ($r) { $lst = if ($field -eq 'directIp') { $r.directIp } else { $r.proxyIp }; $already = @($todo | Where-Object { $it2 = $_; [bool]($lst | Where-Object { Test-InCidr $it2.ip $_ }) }) }
        $cmds = @("${field}: добавить " + ($pfx -join ', '))
        if ($domain) { $cmds += "$(if ($vk -eq 'physical') { 'directSites' } else { 'proxySites' }): добавить $domain (формат записей — как у уже имеющихся в списке)" }
        $how = 'Профиль маршрутизации Happ' + $(if ($r) { " «$($r.name)»" }) + ". Правится в самом Happ (в файле routing.json это поле $field); карта файл не трогает."
        if ($already.Count) { $how += " ВНИМАНИЕ: $($already.Count) из адресов уже попадают в $field, но трафик всё равно идёт через TUN: значит, дело не в этом списке (порядок правил: $($r.routingOrder), профиль мог быть не применён)." }
        $opt += [ordered]@{
            id = 'happ'; title = "Профиль Happ — $field"; admin = $false
            how = $how; persists = 'пока профиль не сменят; подхватывает ли Happ правку на лету, не проверено — возможно, нужно переподключить профиль'
            commands = $cmds; rollback = @("удалить добавленные записи из $field")
        }
    }
    if ($clash.running -and ($vk -eq 'physical' -or $vk -eq 'clash')) {
        $group = if ($vk -eq 'physical') { 'DIRECT' } else { '<имя вашей группы>' }
        $rules = @($pfx | ForEach-Object { "IP-CIDR,$_,$group,no-resolve" })
        if ($domain) { $rules += "DOMAIN-SUFFIX,$domain,$group" }
        if ($Proc) { $rules += "PROCESS-NAME,$Proc.exe,$group" }
        $tunUp = [bool]($st.adapters | Where-Object { $_.kind -eq 'clash' -and $_.status -eq 'Up' })
        $opt += [ordered]@{
            id = 'clash'; title = 'Правила Clash'; admin = $false
            how = 'Строки в начало списка rules профиля. Если профиль ведётся в репозитории, правьте его там и перевыберите профиль.' + $(if (-not $tunUp) { ' Сейчас TUN Clash не поднят: правила подействуют, только когда он включён.' })
            persists = 'пока правила в профиле'; commands = $rules; rollback = @('удалить добавленные строки из rules')
        }
    }
    if ($curKinds -contains 'anyconnect' -or $vk -eq 'anyconnect') {
        $opt += [ordered]@{
            id = 'anyconnect'; title = 'AnyConnect: политика на шлюзе'; admin = $false
            how = 'Какие подсети идут в туннель, а какие мимо, задаёт политика на корпоративном шлюзе (Split Include / Split Exclude). На самом ПК это не настраивается; нужен запрос администратору VPN.'
            persists = 'постоянно (на стороне шлюза)'; commands = @('запрос администратору: ' + ($pfx -join ', ') + $(if ($vk -eq 'physical') { ' — исключить из туннеля (Split Exclude)' } else { ' — включить в туннель (Split Include)' })); rollback = @('отозвать запрос')
        }
    }
    if ($Proc) {
        $pp = @($st.proxies | ForEach-Object { "http://127.0.0.1:$($_.port)" })
        if ($vk -eq 'physical') {
            $opt += [ordered]@{ id = 'app-direct'; title = 'Настройка самого приложения: без прокси'; admin = $false
                how = "Если у «$Proc» в настройках задан прокси или переменные HTTPS_PROXY/HTTP_PROXY, уберите их: тогда программа идёт по таблице маршрутов. Только для программ, которые читают эти настройки."
                persists = 'пока настройка не изменена'; commands = @('Remove-Item Env:HTTPS_PROXY, Env:HTTP_PROXY -ErrorAction SilentlyContinue   # для сеанса, из которого запускаете программу'); rollback = @('вернуть прежние значения') }
        } elseif ($pp.Count) {
            $opt += [ordered]@{ id = 'app-proxy'; title = 'Настройка самого приложения: свой прокси'; admin = $false
                how = "Запускать «$Proc» с прокси одного из локальных портов: только для программ, которые его читают, и только для новых процессов."
                persists = 'пока настройка не изменена'; commands = @("`$env:HTTPS_PROXY = $(ConvertTo-PsStr $pp[0]); `$env:HTTP_PROXY = $(ConvertTo-PsStr $pp[0])   # затем запустить программу из этого же сеанса"); rollback = @('Remove-Item Env:HTTPS_PROXY, Env:HTTP_PROXY') }
        }
        $opt += [ordered]@{ id = 'app-third'; title = 'Сторонний проксификатор (Proxifier и аналоги)'; admin = $true
            how = 'Единственный способ задать маршрут по программе независимо от адреса: правило «приложение → прокси/напрямую». Это отдельное ПО; на этой машине не проверялось.'
            persists = 'пока правило в программе'; commands = @("правило: приложение $Proc.exe → $(if ($vk -eq 'physical') { 'Direct' } else { 'нужный прокси' })"); rollback = @('удалить правило') }
    }
    $res.options = $opt

    $res.verify = @(
        "Find-NetRoute -RemoteIPAddress $(ConvertTo-PsStr $todo[0].ip) | Select-Object -First 1 -ExpandProperty InterfaceAlias   # ожидается: $Via",
        'В карте: вкладка «Проверки» → поле «Путь» → тот же адрес, затем кнопка «Внешний IP».'
    )
    $res
}

function Get-KindLabel([string]$K) { [string](($script:AdapterKinds | Where-Object { $_.kind -eq $K } | Select-Object -First 1).label) }

# ---------------------------------------------------------------- мои связи и маршруты «по умолчанию»
# Реестр «моих связей» (netmap.links.json) хранит только намерения: что и через какой интерфейс я хочу направить.
# Карта сверяет их с реальной таблицей маршрутов и показывает статус. Сама в систему ничего не пишет.

$LinksFile = Join-Path $Root 'netmap.links.json'
$script:Links = @()
$script:Baseline = @{}
$script:BaselineAt = $null
$script:RouteFirstSeen = @{}

function Get-RouteSnapshot {
    foreach ($r in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $p = [string]$r.DestinationPrefix
        if ($p -match '^(127\.|224\.|255\.255\.255\.255|169\.254\.)') { continue }
        [pscustomobject]@{
            prefix = $p; ifIndex = [int]$r.InterfaceIndex; iface = [string]$r.InterfaceAlias; nextHop = [string]$r.NextHop
            metric = [int]$r.RouteMetric; protocol = [string]$r.Protocol; store = [string]$r.Store
            key = "$p|$([int]$r.InterfaceIndex)|$([string]$r.NextHop)"
        }
    }
}

function Get-RouteScripts([int]$Ifx, [string]$Nh, [string[]]$Prefixes) {
    $list = ($Prefixes | ForEach-Object { ConvertTo-PsStr $_ }) -join ', '
    $head = "`$ifx = $Ifx; `$nh = $(ConvertTo-PsStr $Nh)`n`$list = $list"
    $add = 'foreach ($p in $list) { New-NetRoute -DestinationPrefix $p -InterfaceIndex $ifx -NextHop $nh -RouteMetric 1 -PolicyStore ActiveStore | Out-Null }'
    $del = 'foreach ($p in $list) { Remove-NetRoute -DestinationPrefix $p -InterfaceIndex $ifx -Confirm:$false -ErrorAction SilentlyContinue }'
    [ordered]@{ trial = "$head`n$add`nStart-Sleep -Seconds 60`n$del"; keep = "$head`n$add"; rollback = "$head`n$del" }
}

function Import-Links {
    $script:Links = @()
    if (-not (Test-Path -LiteralPath $LinksFile)) { return }
    try {
        $j = Get-Content -LiteralPath $LinksFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $script:Links = @(@($j.links) | Where-Object { $_ -and $_.id } | ForEach-Object {
            [pscustomobject]@{
                id = [string]$_.id; created = [string]$_.created; label = [string]$_.label; proc = [string]$_.proc; target = [string]$_.target
                prefixes = @($_.prefixes | ForEach-Object { [string]$_ }); via = [string]$_.via; viaIfIndex = [int]$_.viaIfIndex; viaKind = [string]$_.viaKind
                nextHop = [string]$_.nextHop; claimed = [bool]$_.claimed; seenActive = [bool]$_.seenActive
            }
        })
    } catch { Write-Log "netmap.links.json не прочитан: $($_.Exception.Message)" }
}

function Save-Links {
    $tmp = "$LinksFile.tmp"
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; links = @($script:Links) }) -Depth 6
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $tmp -Destination $LinksFile -Force
    $script:Cache.Remove('links')
}

function Get-BestRoute($Snap, $Adapters, [string]$Ip) {
    $best = $null
    foreach ($r in $Snap) {
        if (-not (Test-InCidr $Ip $r.prefix)) { continue }
        $len = [int](($r.prefix -split '/')[1])
        $im = [int](($Adapters | Where-Object { [int]$_.ifIndex -eq $r.ifIndex } | Select-Object -First 1).metric)
        $eff = $r.metric + $im
        if (-not $best -or $len -gt $best.len -or ($len -eq $best.len -and $eff -lt $best.eff)) { $best = [pscustomobject]@{ r = $r; len = $len; eff = $eff } }
    }
    if ($best) { $best.r }
}

function Get-LinkView($E, $Snap, $Adapters) {
    # номера интерфейсов меняются при пересоздании адаптера и перезагрузке, поэтому связь привязана к имени, а актуальный номер берётся из системы
    $viaA = $Adapters | Where-Object { $_.name -eq $E.via } | Select-Object -First 1
    $ifx = if ($viaA) { [int]$viaA.ifIndex } else { [int]$E.viaIfIndex }
    $nhNow = if ($viaA -and $viaA.gateway) { [string]$viaA.gateway } else { [string]$E.nextHop }
    $viaUp = [bool]($viaA -and [string]$viaA.status -eq 'Up')
    $allPath = $true; $allExact = $true; $paths = @()
    foreach ($pf in $E.prefixes) {
        $ip = ($pf -split '/')[0]
        $b = Get-BestRoute $Snap $Adapters $ip
        $now = if ($b) { $b.iface } else { '' }
        $paths += [ordered]@{ prefix = $pf; now = $now }
        if (-not $b -or $b.ifIndex -ne $ifx) { $allPath = $false }
        if (-not ($Snap | Where-Object { $_.prefix -eq $pf -and $_.ifIndex -eq $ifx })) { $allExact = $false }
    }
    $status = if ($allPath -and $viaUp) { 'active' } elseif ($E.seenActive) { 'drift' } elseif ($E.claimed) { 'claimed' } else { 'planned' }
    if ($status -eq 'active' -and -not $E.seenActive) { $E.seenActive = $true; $script:LinksDirty = $true }
    $sc = Get-RouteScripts $ifx $nhNow $E.prefixes
    [ordered]@{
        id = $E.id; created = $E.created; label = $E.label; proc = $E.proc; target = $E.target; prefixes = $E.prefixes
        via = $E.via; viaKind = $E.viaKind; viaIfIndex = $ifx; viaUp = $viaUp
        claimed = $E.claimed; seenActive = $E.seenActive; status = $status; exact = $allExact; paths = $paths
        scripts = $sc
    }
}

function Get-LinksData {
    Cached 'links' 3 {
        $st = Get-State
        $snap = @(Get-RouteSnapshot)
        $script:LinksDirty = $false
        $mine = @($script:Links | ForEach-Object { Get-LinkView $_ $snap $st.adapters })
        if ($script:LinksDirty) { try { Save-Links } catch { Write-Log "сохранение связей: $($_.Exception.Message)" }; $script:Cache.Remove('links') }
        $mineKey = @{}
        foreach ($m in $mine) { foreach ($pf in $m.prefixes) { $mineKey["$pf|$($m.viaIfIndex)"] = $m.id } }
        $now = Get-Date
        $routes = @(); $cur = @{}
        foreach ($r in $snap) {
            $cur[$r.key] = $true
            $origin = if ($mineKey.ContainsKey("$($r.prefix)|$($r.ifIndex)")) { 'mine' } elseif ($script:Baseline.ContainsKey($r.key)) { 'baseline' } else { 'later' }
            if ($origin -eq 'later' -and -not $script:RouteFirstSeen.ContainsKey($r.key)) { $script:RouteFirstSeen[$r.key] = $now }
            $len = [int](($r.prefix -split '/')[1])
            $kind = if ($len -le 1) { 'default' } elseif ($len -eq 32) { 'host' } else { 'subnet' }
            $routes += [ordered]@{
                prefix = $r.prefix; ifIndex = $r.ifIndex; iface = $r.iface; nextHop = $r.nextHop; metric = $r.metric; protocol = $r.protocol; store = $r.store
                kind = $kind; origin = $origin; linkId = [string]$mineKey["$($r.prefix)|$($r.ifIndex)"]; service = ($r.protocol -eq 'Local' -and $r.nextHop -eq '0.0.0.0')
                firstSeen = $(if ($origin -eq 'later') { $script:RouteFirstSeen[$r.key].ToString('o') } else { '' })
            }
        }
        foreach ($b in $script:Baseline.Values) {
            if ($cur.ContainsKey($b.key)) { continue }
            $len = [int](($b.prefix -split '/')[1])
            $routes += [ordered]@{
                prefix = $b.prefix; ifIndex = $b.ifIndex; iface = $b.iface; nextHop = $b.nextHop; metric = $b.metric; protocol = $b.protocol; store = $b.store
                kind = $(if ($len -le 1) { 'default' } elseif ($len -eq 32) { 'host' } else { 'subnet' }); origin = 'removed'; linkId = ''; service = ($b.protocol -eq 'Local' -and $b.nextHop -eq '0.0.0.0'); firstSeen = ''
            }
        }
        $perIface = [ordered]@{}
        foreach ($r in ($routes | Where-Object { -not $_.service -and $_.origin -ne 'removed' })) {
            if (-not $perIface.Contains($r.iface)) { $perIface[$r.iface] = [ordered]@{ baseline = 0; later = 0; mine = 0 } }
            $perIface[$r.iface][$r.origin]++
        }
        $rbAll = @($mine | Where-Object { $_.status -in 'active', 'drift', 'claimed' -or $_.exact } | ForEach-Object { "# $($_.label)`n$($_.scripts.rollback)" }) -join "`n`n"
        [ordered]@{ startedAt = $(if ($script:BaselineAt) { $script:BaselineAt.ToString('o') } else { '' }); mine = $mine; routes = $routes; perIface = $perIface; rollbackAll = $rbAll }
    }
}

function Add-Link([string]$Target, [string]$Via, [string]$Proc) {
    $plan = New-Plan $Target $Via $Proc
    if ($plan.error) { return [ordered]@{ error = [string]$plan.error } }
    $todo = @($plan.items | Where-Object { -not $_.already })
    if (-not $todo.Count) { return [ordered]@{ error = 'Уже так и есть: связь не нужна.' } }
    $st = Get-State
    $va = $st.adapters | Where-Object { $_.name -eq $Via } | Select-Object -First 1
    $nh = if ($va.gateway) { [string]$va.gateway } else { '0.0.0.0' }
    $pfx = @($todo | ForEach-Object { [string]$_.prefix })
    $dup = $script:Links | Where-Object { $_.via -eq $Via -and (@($_.prefixes) -join ',') -eq ($pfx -join ',') } | Select-Object -First 1
    if ($dup) { return [ordered]@{ ok = $true; existing = $true; id = $dup.id } }
    $label = if ($Proc) { "процесс $Proc" } else { $Target.Trim() }
    $e = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N').Substring(0, 8); created = (Get-Date).ToString('o'); label = $label; proc = $Proc; target = $Target.Trim()
        prefixes = $pfx; via = $Via; viaIfIndex = [int]$va.ifIndex; viaKind = [string]$va.kind; nextHop = $nh; claimed = $false; seenActive = $false
    }
    $script:Links = @($script:Links) + $e
    Save-Links
    [ordered]@{ ok = $true; id = $e.id }
}

function Edit-Link([string]$Op, [string]$Id) {
    if ($Op -eq 'forgetplanned') {
        $view = (Get-LinksData).mine
        $drop = @($view | Where-Object { $_.status -eq 'planned' } | ForEach-Object { $_.id })
        $script:Links = @($script:Links | Where-Object { $drop -notcontains $_.id }); Save-Links
        return [ordered]@{ ok = $true; removed = $drop.Count }
    }
    $e = $script:Links | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $e) { return [ordered]@{ error = 'Связь не найдена (возможно, уже удалена).' } }
    $v = (Get-LinksData).mine | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    switch ($Op) {
        'claim'   { $e.claimed = $true }
        'unclaim' { $e.claimed = $false }
        'forget'  {
            if ($v -and ($v.status -eq 'active' -or $v.exact)) { return [ordered]@{ error = 'Связь сейчас действует (или маршрут ещё есть в таблице). Сначала выполните скрипт отключения, потом удаляйте запись.' } }
            $script:Links = @($script:Links | Where-Object { $_.id -ne $Id })
        }
        default { return [ordered]@{ error = 'Неизвестное действие.' } }
    }
    Save-Links
    [ordered]@{ ok = $true }
}

function New-RoutePlan([string]$Prefix, [int]$IfIndex, [string]$NextHop) {
    $res = [ordered]@{ readOnly = $true; error = ''; summary = ''; items = @(); warnings = @(); notes = @(); options = @(); verify = @() }
    if ($Prefix -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' -or $NextHop -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $res.error = 'Неверные параметры маршрута.'; return $res }
    $data = Get-LinksData
    $r = $data.routes | Where-Object { $_.prefix -eq $Prefix -and $_.ifIndex -eq $IfIndex -and $_.nextHop -eq $NextHop } | Select-Object -First 1
    if (-not $r) { $res.error = 'Такого маршрута нет в таблице (возможно, он уже исчез).'; return $res }
    $st = Get-State
    $ia = $st.adapters | Where-Object { [int]$_.ifIndex -eq $IfIndex } | Select-Object -First 1
    $ik = if ($ia) { Get-KindLabel ([string]$ia.kind) } else { '' }
    $originText = switch ($r.origin) { 'baseline' { 'был до запуска карты (по умолчанию)' } 'later' { 'появился после запуска карты (создан программно)' } 'mine' { 'создан вашей связью' } default { 'пропал после запуска карты' } }
    $res.summary = "Маршрут $Prefix через «$($r.iface)» (следующий узел $NextHop, метрика $($r.metric)): $originText."
    if ($r.origin -eq 'removed') { $res.error = 'Этот маршрут уже исчез: отключать нечего.'; return $res }
    if ($r.service) { $res.error = 'Это служебный маршрут подключённой сети (протокол Local): он существует, пока поднят адаптер. Отключается только вместе с адаптером.'; return $res }
    if ($r.kind -eq 'default') {
        $res.warnings += [ordered]@{ level = 'warn'; text = 'Это маршрут по умолчанию: через него идёт весь интернет (или половина адресного пространства у TUN-VPN). Удаление оборвёт связь.' }
        $res.options += [ordered]@{ id = 'app'; title = 'Выключить в самой программе'; admin = $false
            how = "Такие маршруты создаёт и убирает клиент на интерфейсе «$($r.iface)»$(if ($ik) { " ($ik)" }). Правильный способ отключить связь — выключить VPN/TUN в этой программе. Карта команды удаления не предлагает."
            persists = '—'; commands = @('выключить VPN или TUN в приложении'); rollback = @('включить обратно') }
        return $res
    }
    $epHit = @($st.endpoints | Where-Object { $_.via -eq $r.iface -and (Test-InCidr $_.ip $Prefix) })
    foreach ($ep in $epHit) { $res.warnings += [ordered]@{ level = 'warn'; text = "Через этот маршрут идёт связь с «$($ep.label)»: после удаления она может оборваться." } }
    if ($r.origin -eq 'baseline' -or $r.origin -eq 'later') { $res.warnings += [ordered]@{ level = 'info'; text = "Маршрут создан не вами$(if ($ik) { ": вероятно, программой интерфейса «$($r.iface)» ($ik)" }). Она может пересоздать его при переподключении, и тогда отключение будет временным." } }
    $res.warnings += [ordered]@{ level = 'info'; text = 'Это только план, ничего не применено. Открытые соединения остаются на прежнем пути, пока их не переоткроют.' }
    $q = @{ p = ConvertTo-PsStr $Prefix; i = $IfIndex; n = ConvertTo-PsStr $NextHop; m = [int]$r.metric }
    $head = "`$p = $($q.p); `$ifx = $($q.i); `$nh = $($q.n); `$mt = $($q.m)"
    $del = 'Remove-NetRoute -DestinationPrefix $p -InterfaceIndex $ifx -NextHop $nh -Confirm:$false'
    $add = 'New-NetRoute -DestinationPrefix $p -InterfaceIndex $ifx -NextHop $nh -RouteMetric $mt -PolicyStore ActiveStore | Out-Null'
    $res.options += [ordered]@{ id = 'rm-trial'; title = 'Отключить маршрут на 60 секунд, потом вернуть'; admin = $true
        how = 'PowerShell от администратора. Удаляет маршрут, ждёт 60 с (проверьте, что нужное работает или пропало), затем возвращает с прежним следующим узлом и метрикой.'
        persists = 'нет: маршрут вернётся через 60 с'; commands = @("$head`n$del`nStart-Sleep -Seconds 60`n$add"); rollback = @("$head`n$add") }
    $res.options += [ordered]@{ id = 'rm-keep'; title = 'Отключить маршрут до пересоздания'; admin = $true
        how = 'PowerShell от администратора. Удаляет маршрут из активной таблицы.'
        persists = 'до перезагрузки, сброса интерфейса или пересоздания маршрута его программой'; commands = @("$head`n$del"); rollback = @("$head`n$add") }
    $res.verify = @("Get-NetRoute -DestinationPrefix $($q.p) -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, NextHop, RouteMetric")
    $res
}

function Read-JsonBody($Ctx) {
    $req = $Ctx.Request
    if ($req.ContentLength64 -gt 16384) { throw 'тело запроса слишком большое' }
    $sr = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8)
    try { $t = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if ($t) { $t | ConvertFrom-Json } else { [pscustomobject]@{} }
}

# ---------------------------------------------------------------- HTTP-сервер

# ---------------------------------------------------------------- фоновый монитор (резолв имён, пинг шлюза, Wi-Fi, журнал событий)

$MonitorFile = Join-Path $Root 'netmap-monitor.ps1'
$EventsFile = Join-Path $Root 'events.jsonl'
$script:Shared = [hashtable]::Synchronized(@{ stop = $false; gateway = ''; zone = ''; anyconnectGlobs = @(); anyconnectService = 'vpnagent'; series = @{}; events = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()) })
foreach ($k in 'dns', 'dnsnb', 'ping', 'wifi') { $script:Shared.series[$k] = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()) }
$script:MonitorPs = @()

function Start-Monitor {
    if (-not (Test-Path -LiteralPath $MonitorFile)) { Write-Log "нет файла монитора $MonitorFile"; return }
    try {
        if ((Test-Path -LiteralPath $EventsFile) -and (Get-Item -LiteralPath $EventsFile).Length -gt 1MB) { Move-Item -LiteralPath $EventsFile -Destination "$EventsFile.old" -Force }
        if (Test-Path -LiteralPath $EventsFile) {
            foreach ($line in (Get-Content -LiteralPath $EventsFile -Tail 300 -Encoding UTF8)) {
                try { $e = $line | ConvertFrom-Json; [void]$script:Shared.events.Add([pscustomobject]@{ t = [long]$e.t; level = [string]$e.level; text = [string]$e.text }) } catch { }
            }
        }
    } catch { Write-Log "журнал событий: $($_.Exception.Message)" }
    $zone = ''
    try { $nb = (Get-State).services.netbird; if ($nb.management -and ([string]$nb.management.url) -match '//([^/:]+)') { $zone = $Matches[1] } } catch { }
    $script:Shared.zone = $zone
    $script:Shared.anyconnectGlobs = $script:AnyConnectGlobs
    $script:Shared.anyconnectService = $script:AnyConnectService
    $roles = @(@{ role = 'dns'; zone = $script:ControlZone; key = 'dns' })
    if ($zone) { $roles += @{ role = 'dns'; zone = $zone; key = 'dnsnb' } }
    $roles += @{ role = 'ping'; zone = ''; key = '' }
    $roles += @{ role = 'events'; zone = ''; key = '' }
    $text = [IO.File]::ReadAllText($MonitorFile)
    foreach ($r in $roles) {
        try {
            $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            [void]$ps.AddScript($text).AddArgument($script:Shared).AddArgument($r.role).AddArgument($r.zone).AddArgument($r.key).AddArgument($EventsFile)
            [void]$ps.BeginInvoke()
            $script:MonitorPs += $ps
        } catch { Write-Log "монитор $($r.role): $($_.Exception.Message)" }
    }
    Write-Log "монитор запущен: $(($roles | ForEach-Object { $_.role + $(if ($_.zone) { ':' + $_.zone }) }) -join ', ')"
}

function Stop-Monitor {
    $script:Shared.stop = $true
    foreach ($ps in $script:MonitorPs) { try { [void]$ps.BeginStop($null, $null) } catch { } }
}

function Get-MonitorData([long]$Since, [long]$EvSince) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cut = [Math]::Max($Since, $now - 20 * 60 * 1000)
    $series = [ordered]@{}
    foreach ($k in 'dns', 'dnsnb', 'ping', 'wifi') { $series[$k] = @($script:Shared.series[$k].ToArray() | Where-Object { $_.t -gt $cut }) }
    [ordered]@{
        now = $now; gateway = [string]$script:Shared.gateway; zone = [string]$script:Shared.zone; series = $series
        events = @($script:Shared.events.ToArray() | Where-Object { $_.t -gt $EvSince } | Select-Object -Last 400)
    }
}

function Send-Bytes($Ctx, [int]$Code, [string]$Type, [byte[]]$Bytes, [string[]]$ExtraHeaders = @()) {
    $r = $Ctx.Response
    $r.StatusCode = $Code; $r.ContentType = $Type
    $r.Headers['Cache-Control'] = 'no-store'; $r.Headers['X-Content-Type-Options'] = 'nosniff'; $r.Headers['Referrer-Policy'] = 'no-referrer'
    foreach ($h in $ExtraHeaders) { $kv = $h -split ': ', 2; $r.Headers[$kv[0]] = $kv[1] }
    $r.ContentLength64 = $Bytes.Length
    $r.OutputStream.Write($Bytes, 0, $Bytes.Length)
}
function Send-Json($Ctx, $Obj, [int]$Code = 200) {
    $json = ConvertTo-Json -InputObject $Obj -Depth 12 -Compress
    Send-Bytes $Ctx $Code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Handle-Request($Ctx) {
    $req = $Ctx.Request
    if ($req.Headers['Host'] -notmatch "^(127\.0\.0\.1|localhost):$Port$") { Send-Json $Ctx @{ error = 'forbidden host' } 403; return }
    $path = $req.Url.AbsolutePath
    if ($path -eq '/' -or $path -eq '/index.html') {
        if (-not (Test-Path -LiteralPath $HtmlFile)) { Send-Bytes $Ctx 404 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('index.html не найден')); return }
        $csp = "Content-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        Send-Bytes $Ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($HtmlFile)) @($csp)
        return
    }
    if ($path -like '/api/*') {
        if ($req.Headers['X-NetMap'] -ne '1') { Send-Json $Ctx @{ error = 'missing X-NetMap header' } 403; return }
        $isPost = $req.HttpMethod -eq 'POST'
        $mutating = $path -in '/api/links/save', '/api/links/claim', '/api/links/unclaim', '/api/links/forget', '/api/links/forgetplanned'
        if ($mutating -ne $isPost) { Send-Json $Ctx @{ error = 'method not allowed' } 405; return }
        if ($isPost -and ([string]$req.ContentType) -notmatch '^application/json') { Send-Json $Ctx @{ error = 'content-type must be application/json' } 415; return }
        switch ($path) {
            '/api/state'    { Send-Json $Ctx (Get-State) }
            '/api/dnscheck' { Send-Json $Ctx (Invoke-DnsCheck) }
            '/api/exit'     { Send-Json $Ctx @(Invoke-ExitCheck) }
            '/api/links'    { Send-Json $Ctx (Get-LinksData) }
            '/api/links/save'         { $b = Read-JsonBody $Ctx; Send-Json $Ctx (Add-Link ([string]$b.target) ([string]$b.via) ([string]$b.proc)) }
            '/api/links/claim'        { $b = Read-JsonBody $Ctx; Send-Json $Ctx (Edit-Link 'claim' ([string]$b.id)) }
            '/api/links/unclaim'      { $b = Read-JsonBody $Ctx; Send-Json $Ctx (Edit-Link 'unclaim' ([string]$b.id)) }
            '/api/links/forget'       { $b = Read-JsonBody $Ctx; Send-Json $Ctx (Edit-Link 'forget' ([string]$b.id)) }
            '/api/links/forgetplanned' { $null = Read-JsonBody $Ctx; Send-Json $Ctx (Edit-Link 'forgetplanned' '') }
            '/api/routeplan' { $ix = 0; [void][int]::TryParse([string]$req.QueryString['ifIndex'], [ref]$ix); Send-Json $Ctx (New-RoutePlan ([string]$req.QueryString['prefix']) $ix ([string]$req.QueryString['nextHop'])) }
            '/api/plan'     { Send-Json $Ctx (New-Plan ([string]$req.QueryString['target']) ([string]$req.QueryString['via']) ([string]$req.QueryString['proc'])) }
            '/api/trace'    { Send-Json $Ctx (Invoke-Trace ([string]$req.QueryString['target'])) }
            '/api/monitor'  { $since = [long]0; $evSince = [long]0; [void][long]::TryParse([string]$req.QueryString['since'], [ref]$since); [void][long]::TryParse([string]$req.QueryString['ev'], [ref]$evSince); Send-Json $Ctx (Get-MonitorData $since $evSince) }
            default         { Send-Json $Ctx @{ error = 'not found' } 404 }
        }
        return
    }
    Send-Json $Ctx @{ error = 'not found' } 404
}

# ---------------------------------------------------------------- запуск

$LogFile = Join-Path $Root "netmap.log"
function Write-Log([string]$Msg) { try { Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Msg) -Encoding UTF8 } catch { } }
try { if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 200KB) { Remove-Item -LiteralPath $LogFile -Force } } catch { }
Write-Log "старт, pwsh $($PSVersionTable.PSVersion), порт $Port"

$listener = $null
try {
    Import-NetMapConfig
    Write-Log "настройки: $ConfigFile, видов адаптеров $($script:AdapterKinds.Count)"
    foreach ($r in @(Get-RouteSnapshot)) { $script:Baseline[$r.key] = $r }
    $script:BaselineAt = Get-Date
    Import-Links
    Write-Log "снимок маршрутов «по умолчанию»: $($script:Baseline.Count); моих связей в реестре: $(@($script:Links).Count)"
    # ищем свободный порт; если на порту уже наша карта - просто открываем её
    foreach ($p in $Port..($Port + 9)) {
        $l = [Net.HttpListener]::new()
        $l.Prefixes.Add("http://127.0.0.1:$p/")
        try { $l.Start(); $listener = $l; $Port = $p; break }
        catch {
            Write-Log "порт $p недоступен: $($_.Exception.Message)"
            try { $l.Close() } catch { }
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -TimeoutSec 3 -NoProxy -ErrorAction Stop
                if ($r.Content -match "<title>Карта сети</title>") {
                    Write-Host "Карта уже запущена: http://127.0.0.1:$p/ - открываю в браузере." -ForegroundColor Green
                    Write-Log "уже запущена на порту $p"
                    if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$p/" }
                    exit 0
                }
            } catch { }
        }
    }
    if (-not $listener) { throw "Не нашёл свободный порт в диапазоне $Port..$($Port + 9). Подробности в $LogFile" }

    $url = "http://127.0.0.1:$Port/"
    Write-Host "Первый сбор данных (до 20 с, потом страница будет обновляться быстро)..." -ForegroundColor DarkGray
    try { $null = Get-State } catch { Write-Log "ошибка первого сбора: $($_.Exception.Message)"; Write-Host "Первый сбор данных не удался: $($_.Exception.Message) (страница всё равно откроется)" -ForegroundColor Yellow }
    Start-Monitor
    Write-Host "Карта сети: $url   (Ctrl+C - остановить)" -ForegroundColor Green
    Write-Log "слушаю $url"
    if (-not $NoBrowser) { try { Start-Process $url } catch { Write-Host "Не удалось открыть браузер: $($_.Exception.Message). Откройте $url вручную." -ForegroundColor Yellow } }

    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(500)) { }
        $ctx = $task.Result
        try { Handle-Request $ctx }
        catch {
            # клиент (браузер, вкладка) уже закрыл соединение - это не ошибка сервера
            if ($_.Exception.Message -notmatch 'сетевое имя более недоступно|network name is no longer available|Broken pipe|forcibly closed|разорвал') {
                Write-Log ("ошибка {0}: {1}" -f $ctx.Request.Url.AbsolutePath, $_.Exception.Message)
                Write-Host ("{0:HH:mm:ss} ошибка {1}: {2}" -f (Get-Date), $ctx.Request.Url.AbsolutePath, $_.Exception.Message) -ForegroundColor Yellow
                try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch { }
            }
        }
        finally { try { $ctx.Response.Close() } catch { } }
    }
} catch {
    Write-Log ("ФАТАЛЬНО: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    Write-Host ("ОШИБКА: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host "Журнал: $LogFile" -ForegroundColor DarkGray
    if (-not $env:NETMAP_FROM_CMD) { Read-Host 'Нажмите Enter, чтобы закрыть' | Out-Null }
    exit 1
} finally { Stop-Monitor; if ($listener) { try { $listener.Stop(); $listener.Close() } catch { } } }
