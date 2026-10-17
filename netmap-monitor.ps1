param($Shared, [string]$Role, [string]$Zone, [string]$Key, [string]$EventsFile)
<#
netmap-monitor.ps1 - фоновые пробы для netmap.ps1 (запускается в отдельном потоке, сам по себе не запускать).
Роли:
  dns     раз в ~1,5 с спрашивает у системного резолвера СЛУЧАЙНОЕ имя в зоне $Zone (nmXXXXXX.<зона>).
          Случайное имя не лежит в кэше DNS-клиента, поэтому видна реальная задержка и реальные таймауты.
          Ответ NXDOMAIN считается успехом (резолвер ответил), таймаут или SERVFAIL - сбоем.
          Для зоны NetBird запрос идёт через NRPT-правило, то есть через DNS самого NetBird.
  ping    раз в 2 с пингует шлюз физического адаптера, раз в 6 с читает уровень сигнала Wi-Fi.
  events  раз в 6 с снимает состояние (адаптеры, маршрут в интернет, AnyConnect, NetBird) и пишет изменения в журнал.
Только чтение; ничего в системе не меняет.
#>
$ErrorActionPreference = 'SilentlyContinue'
$rnd = [Random]::new()

function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Push([string]$K, $Sample) {
    $l = $Shared.series[$K]
    if ($null -eq $l) { return }
    [void]$l.Add($Sample)
    if ($l.Count -gt 800) { $l.RemoveRange(0, $l.Count - 600) }
}

function Add-Ev([string]$Level, [string]$Text) {
    $e = [pscustomobject]@{ t = (NowMs); level = $Level; text = $Text }
    [void]$Shared.events.Add($e)
    if ($Shared.events.Count -gt 800) { $Shared.events.RemoveRange(0, $Shared.events.Count - 600) }
    try { Add-Content -LiteralPath $EventsFile -Value (ConvertTo-Json -InputObject $e -Compress) -Encoding UTF8 } catch { }
}

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
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill($true) } catch { }; return [pscustomobject]@{ Out = ''; Code = -1 } }
        [void]$so.Wait(1500)
        return [pscustomobject]@{ Out = [string]$so.Result; Code = $p.ExitCode }
    } catch { return [pscustomobject]@{ Out = ''; Code = -2 } }
}

function Sleep-Until([datetime]$Start, [int]$PeriodMs) {
    $left = $PeriodMs - [int]((Get-Date) - $Start).TotalMilliseconds
    if ($left -lt 150) { $left = 150 }
    # спим короткими кусками, чтобы быстро выйти при остановке
    while ($left -gt 0 -and -not $Shared.stop) { $step = [Math]::Min(300, $left); Start-Sleep -Milliseconds $step; $left -= $step }
}

# ------------------------------------------------------------------ dns
if ($Role -eq 'dns') {
    # прогрев: первый вызов Resolve-DnsName грузит модуль (около секунды), это не сеть и не должно попадать на график
    try { $null = Resolve-DnsName -Name 'example.com' -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop } catch { }
    while (-not $Shared.stop) {
        $t0 = Get-Date
        $name = 'nm' + $rnd.Next(100000, 999999) + '.' + $Zone
        $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $why = ''
        try { $null = Resolve-DnsName -Name $name -Type A -DnsOnly -NoHostsFile -ErrorAction Stop; $ok = $true }
        catch {
            $id = [string]$_.FullyQualifiedErrorId
            if ($id -match 'RCODE_NAME_ERROR|NAME_ERROR|NO_RECORDS|NXDOMAIN') { $ok = $true } else { $why = ($id -split ',')[0] }
        }
        Push $Key ([pscustomobject]@{ t = (NowMs); ok = $ok; ms = [int]$sw.ElapsedMilliseconds; why = $why })
        Sleep-Until $t0 1500
    }
    return
}

# ------------------------------------------------------------------ ping + wifi
if ($Role -eq 'ping') {
    $ping = [Net.NetworkInformation.Ping]::new()
    $gw = ''; $tick = 0
    while (-not $Shared.stop) {
        $t0 = Get-Date
        if ($tick % 5 -eq 0) {
            $pi = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { $_.ifIndex })
            $gw = [string](Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Where-Object { $pi -contains $_.InterfaceIndex -and $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1).NextHop
            $Shared.gateway = $gw
        }
        if ($gw) {
            try { $r = $ping.Send($gw, 1000); Push 'ping' ([pscustomobject]@{ t = (NowMs); ok = ($r.Status -eq 'Success'); ms = [int]$r.RoundtripTime; why = [string]$r.Status }) }
            catch { Push 'ping' ([pscustomobject]@{ t = (NowMs); ok = $false; ms = 1000; why = $_.Exception.Message }) }
        }
        if ($tick % 3 -eq 0) {
            $o = (& netsh.exe wlan show interfaces 2>$null) -join "`n"
            $m = [regex]::Match($o, ':\s*(\d{1,3})\s*%')       # единственная строка с «%» в выводе - уровень сигнала (на любом языке ОС)
            if ($m.Success) { Push 'wifi' ([pscustomobject]@{ t = (NowMs); ok = $true; ms = 0; v = [int]$m.Groups[1].Value; why = '' }) }
        }
        $tick++
        Sleep-Until $t0 2000
    }
    return
}

# ------------------------------------------------------------------ events
if ($Role -eq 'events') {
    $acGlobs = @($Shared.anyconnectGlobs)
    $acService = if ($Shared.anyconnectService) { [string]$Shared.anyconnectService } else { 'vpnagent' }
    $cli = if ($acGlobs.Count) { Get-ChildItem $acGlobs | Select-Object -First 1 }
    $nbExe = (Get-Command netbird).Source

    function Get-Snap {
        $s = @{ ad = @{}; egress = ''; ac = ''; nb = $null }
        foreach ($a in @(Get-NetAdapter)) { if ([string]$a.Status -ne 'Not Present') { $s.ad[[string]$a.Name] = [string]$a.Status } }
        $s.egress = [string](@(Find-NetRoute -RemoteIPAddress 1.1.1.1) | Select-Object -First 1).InterfaceAlias
        $svc = Get-Service -Name $acService
        if ($cli -and $svc -and [string]$svc.Status -eq 'Running') {
            $o = Invoke-Native $cli.FullName @('-s') 'state' 5000
            $ms = [regex]::Matches($o.Out, 'state:\s*(\S+)')
            if ($ms.Count) { $s.ac = $ms[$ms.Count - 1].Groups[1].Value }
        } elseif ($cli) { $s.ac = 'служба остановлена' }
        if ($nbExe) {
            $o = Invoke-Native $nbExe @('status', '--json') $null 8000
            $j = $null; try { $j = $o.Out | ConvertFrom-Json } catch { }
            if ($j) {
                $peers = @{}
                foreach ($p in @($j.peers.details)) { $peers[([string]$p.fqdn -split '\.')[0]] = ([string]$p.status + '/' + [string]$p.connectionType) }
                $s.nb = @{
                    daemon = [string]$j.daemonStatus; mgmt = [bool]$j.management.connected; signal = [bool]$j.signal.connected
                    relays = (@($j.relays.details | Where-Object { $_.available }).Count); relaysTotal = @($j.relays.details).Count; peers = $peers
                }
            }
        }
        $s
    }

    $prev = $null
    Add-Ev 'info' 'Монитор запущен'
    while (-not $Shared.stop) {
        $t0 = Get-Date
        $cur = Get-Snap
        if ($prev) {
            foreach ($k in $cur.ad.Keys) {
                if (-not $prev.ad.ContainsKey($k)) { Add-Ev 'info' "Адаптер «$k» появился ($($cur.ad[$k]))" }
                elseif ($prev.ad[$k] -ne $cur.ad[$k]) { Add-Ev $(if ($cur.ad[$k] -eq 'Up') { 'ok' } else { 'warn' }) "Адаптер «$k»: $($prev.ad[$k]) → $($cur.ad[$k])" }
            }
            foreach ($k in $prev.ad.Keys) { if (-not $cur.ad.ContainsKey($k)) { Add-Ev 'warn' "Адаптер «$k» исчез" } }
            if ($prev.egress -ne $cur.egress -and $cur.egress) { Add-Ev 'warn' "Маршрут в интернет: «$($prev.egress)» → «$($cur.egress)»" }
            if ($prev.ac -ne $cur.ac -and ($prev.ac -or $cur.ac)) { Add-Ev $(if ($cur.ac -eq 'Connected') { 'ok' } else { 'warn' }) "AnyConnect: $(if ($prev.ac) { $prev.ac } else { '—' }) → $(if ($cur.ac) { $cur.ac } else { '—' })" }
            if ($prev.nb -and $cur.nb) {
                if ($prev.nb.daemon -ne $cur.nb.daemon) { Add-Ev $(if ($cur.nb.daemon -eq 'Connected') { 'ok' } else { 'bad' }) "NetBird: $($prev.nb.daemon) → $($cur.nb.daemon)" }
                if ($prev.nb.mgmt -ne $cur.nb.mgmt) { Add-Ev $(if ($cur.nb.mgmt) { 'ok' } else { 'bad' }) "NetBird Management: $(if ($cur.nb.mgmt) { 'подключён' } else { 'отключён' })" }
                if ($prev.nb.signal -ne $cur.nb.signal) { Add-Ev $(if ($cur.nb.signal) { 'ok' } else { 'bad' }) "NetBird Signal: $(if ($cur.nb.signal) { 'подключён' } else { 'отключён' })" }
                if ($prev.nb.relays -ne $cur.nb.relays) { Add-Ev 'warn' "NetBird relay/STUN доступно: $($prev.nb.relays) → $($cur.nb.relays) из $($cur.nb.relaysTotal)" }
                foreach ($k in $cur.nb.peers.Keys) {
                    $o = $prev.nb.peers[$k]; $n = $cur.nb.peers[$k]
                    if ($o -and $o -ne $n) { Add-Ev $(if ($n -like 'Connected*') { 'ok' } else { 'info' }) "NetBird пир ${k}: $o → $n" }
                }
            } elseif ($prev.nb -and -not $cur.nb) { Add-Ev 'warn' 'NetBird: статус не получен' }
        }
        $prev = $cur
        Sleep-Until $t0 6000
    }
    return
}
