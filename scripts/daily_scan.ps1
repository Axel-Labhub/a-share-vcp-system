$ErrorActionPreference = 'Stop'
$days = 120

$sectors = [ordered]@{
    'semi'     = @('sh688981','sz002371')
    'nev'      = @('sz300750','sz002594')
    'ai'       = @('sz300308','sh601138')
    'broker'   = @('sh600030','sz300059')
    'defense'  = @('sh600760','sh600893')
    'pharma'   = @('sh600276','sz300760')
    'consumer' = @('sh600519','sz000858')
    'robot'    = @('sz300124','sh601689')
    'solar'    = @('sz300274','sh600438')
}

$pools = [ordered]@{
    'semi'     = @('sh688981','sz002371','sh603986','sh688041','sh603501')
    'nev'      = @('sz300750','sz002594','sz300014','sh601127','sz002460')
    'ai'       = @('sz300308','sh601138','sz300502','sz002281','sz000977','sz300394')
    'broker'   = @('sh600030','sz300059','sh601688','sh600999')
    'defense'  = @('sh600760','sh600893','sz000768','sh600150')
    'pharma'   = @('sh600276','sh603259','sz300760','sz000538')
    'consumer' = @('sh600519','sz000858','sh603288','sz000568')
    'robot'    = @('sz300124','sz002747','sh601689','sz300748')
    'solar'    = @('sz300274','sh600438','sz002459','sz300763')
}

function Get-Kline($sym) {
    $url = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$sym,day,,,$days,qfq"
    $tmp = Join-Path $env:TEMP ("scan_" + $sym.Replace('/','_') + ".json")
    curl.exe -s -o $tmp $url
    $raw = Get-Content -Raw -Encoding UTF8 $tmp
    if (-not $raw) { return $null }
    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    $node = $json.data.$sym
    if ($null -eq $node) { return $null }
    if ($node.PSObject.Properties.Name -contains 'qfqday') { return $node.qfqday }
    if ($node.PSObject.Properties.Name -contains 'day') { return $node.day }
    return $null
}

# ---- benchmark ----
$bench = Get-Kline 'sh000001'
if ($null -eq $bench) { Write-Output 'BENCH_FAIL'; exit 1 }
$bn = $bench.Count
$benchRet = ([double]$bench[$bn-1][2] - [double]$bench[$bn-21][2]) / [double]$bench[$bn-21][2]
Write-Output ("BENCH 20d ret: {0:P2}" -f $benchRet)

# ---- sector RS ----
$cache = @{}
$sectorRS = [ordered]@{}
foreach ($s in $sectors.Keys) {
    $rets = @()
    foreach ($sym in $sectors[$s]) {
        $k = Get-Kline $sym
        if ($null -eq $k -or $k.Count -lt 25) { continue }
        $cache[$sym] = $k
        $n = $k.Count
        $rets += ([double]$k[$n-1][2] - [double]$k[$n-21][2]) / [double]$k[$n-21][2]
    }
    if ($rets.Count -gt 0) {
        $sectorRS[$s] = ($rets | Measure-Object -Average).Average - $benchRet
    }
}

Write-Output ''
Write-Output '==== SECTOR RS RANKING (20d vs SSE) ===='
$ranked = $sectorRS.GetEnumerator() | Sort-Object Value -Descending
$top3 = @()
$idx = 0
foreach ($e in $ranked) {
    $idx++
    $mark = ''
    if ($idx -le 3 -and $e.Value -gt 0) { $top3 += $e.Key; $mark = '  <-- LEADING' }
    elseif ($idx -le 3) { $mark = '  (negative RS, excluded)' }
    Write-Output ("{0,-10} {1,8:P2}{2}" -f $e.Key, $e.Value, $mark)
}
if ($top3.Count -eq 0) {
    Write-Output 'NO LEADING SECTOR: all top-3 RS negative -> no new positions today (v1.2 rule).'
}

# ---- VCP scan in leading sectors ----
Write-Output ''
Write-Output '==== VCP SCAN (leading sectors) ===='
$candidates = New-Object System.Collections.ArrayList

foreach ($s in $top3) {
    Write-Output ("--- sector: $s ---")
    foreach ($sym in $pools[$s]) {
        if (-not $cache.ContainsKey($sym)) {
            $k = Get-Kline $sym
            if ($null -eq $k) { continue }
            $cache[$sym] = $k
        }
        $k = $cache[$sym]
        $n = $k.Count
        if ($n -lt 65) { continue }

        $close = New-Object double[] $n
        $vlo   = New-Object double[] $n
        for ($i = 0; $i -lt $n; $i++) { $close[$i] = [double]$k[$i][2]; $vlo[$i] = [double]$k[$i][4] }

        $last = $close[$n-1]
        # MA20
        $ma20 = 0.0
        for ($i = $n-20; $i -le $n-1; $i++) { $ma20 += $close[$i] }
        $ma20 = $ma20 / 20.0
        if ($last -lt $ma20) { continue }   # already broken 20d line, skip

        # pivot = max close of prior 20 bars
        $pivot = $close[$n-21]
        for ($i = $n-20; $i -le $n-2; $i++) { if ($close[$i] -gt $pivot) { $pivot = $close[$i] } }
        $nearPivot = $last -ge $pivot * 0.95
        if (-not $nearPivot) { continue }
        $brokenOut = $last -gt $pivot

        # contraction: per-segment range of last 60 bars, 3 segments of 20
        $segRange = @()
        for ($sg = 0; $sg -lt 3; $sg++) {
            $a = $n - 60 + $sg * 20; $b = $a + 19
            $hi = $close[$a]; $lo = $close[$a]
            for ($i = $a; $i -le $b; $i++) {
                if ($close[$i] -gt $hi) { $hi = $close[$i] }
                if ($close[$i] -lt $lo) { $lo = $close[$i] }
            }
            $segRange += ($hi - $lo) / $hi
        }
        $contracting = ($segRange[2] -lt $segRange[0])   # latest range smaller than first
        # volume drying: 5d avg vol vs prior 15d avg vol (use volume proxy via low range? use volume field)
        $v5 = 0.0; for ($i = $n-5; $i -le $n-1; $i++) { $v5 += [double]$k[$i][5] }; $v5 = $v5 / 5.0
        $v15 = 0.0; for ($i = $n-20; $i -le $n-6; $i++) { $v15 += [double]$k[$i][5] }; $v15 = $v15 / 15.0
        $volRatio = if ($v15 -gt 0) { $v5 / $v15 } else { 1.0 }
        $drying = $volRatio -le 1.0

        # stop & position
        $hardStop = if ($sym.StartsWith('sh688') -or $sym.StartsWith('sz300')) { 0.12 } else { 0.08 }
        $low10 = $vlo[$n-10]
        for ($i = $n-9; $i -le $n-1; $i++) { if ($vlo[$i] -lt $low10) { $low10 = $vlo[$i] } }
        $techStop = $low10
        $hardLevel = $last * (1 - $hardStop)
        $stop = [Math]::Max($techStop, $hardLevel)
        $stopDist = ($last - $stop) / $last
        $pos = 0.02 / $stopDist
        if ($pos -gt 0.25) { $pos = 0.25 }   # backtest fix: cap position at 25%

        $state = if ($brokenOut) { 'BREAKOUT' } else { 'NEAR_PIVOT' }
        if ($contracting -and $drying -and -not $brokenOut) { $state = 'VCP_READY' }
        if ($brokenOut) { $state = 'BREAKOUT' }

        [void]$candidates.Add([pscustomobject]@{
            Sector = $s; Code = $sym; Close = [math]::Round($last,2); Pivot = [math]::Round($pivot,2);
            DistPivotPct = [math]::Round(($last-$pivot)/$pivot*100,2);
            Contraction = ('{0:P1}->{1:P1}' -f $segRange[0], $segRange[2]);
            VolRatio = [math]::Round($volRatio,2); Stop = [math]::Round($stop,2);
            StopDistPct = [math]::Round($stopDist*100,2); PosCapPct = [math]::Round($pos*100,1);
            State = $state
        })
    }
}

if ($candidates.Count -eq 0) {
    Write-Output 'NO CANDIDATES today (no VCP setup in leading sectors).'
} else {
    $candidates | Sort-Object @{Expression='Sector'}, @{Expression='DistPivotPct';Descending=$true} | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
}
Write-Output 'SCAN DONE.'
