$ErrorActionPreference = 'Stop'

# ---- config ----
$codes = @(
    @{ sym = 'sh603986'; name = 'GigaDevice';    board = 'main' },
    @{ sym = 'sz300750'; name = 'CATL';          board = 'gem'  },
    @{ sym = 'sz002594'; name = 'BYD';           board = 'main' },
    @{ sym = 'sh601127'; name = 'Seres';         board = 'main' },
    @{ sym = 'sh688981'; name = 'SMIC';          board = 'star' }
)
$days = 320
$riskPct = 0.02          # per-trade risk 2% (aggressive tier)
$volFactor = 1.5         # breakout volume >= 1.5x 5d avg volume
$noChaseGap = 0.03       # skip entry if next open > signal close * 1.03 (limit-up-can't-buy rule)

$allTrades = New-Object System.Collections.ArrayList
$summaryLines = New-Object System.Collections.ArrayList

foreach ($c in $codes) {
    $sym = $c.sym; $name = $c.name
    $hardStop = if ($c.board -eq 'main') { 0.08 } else { 0.12 }   # 8% main board, 12% 20cm boards
    $url = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$sym,day,,,$days,qfq"
    $tmp = Join-Path $env:TEMP ("kline_" + $sym + ".json")
    curl.exe -s -o $tmp $url
    $raw = Get-Content -Raw -Encoding UTF8 $tmp
    $json = $raw | ConvertFrom-Json
    $node = $json.data.$sym
    $k = $null
    if ($node.PSObject.Properties.Name -contains 'qfqday') { $k = $node.qfqday }
    elseif ($node.PSObject.Properties.Name -contains 'day') { $k = $node.day }
    if ($null -eq $k -or $k.Count -lt 60) { Write-Output "SKIP $sym (no data)"; continue }

    # rows: date, open, close, high, low, volume
    $n = $k.Count
    $open  = New-Object double[] $n
    $close = New-Object double[] $n
    $low   = New-Object double[] $n
    $vol   = New-Object double[] $n
    $date  = New-Object string[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $r = $k[$i]
        $date[$i]  = [string]$r[0]
        $open[$i]  = [double]$r[1]
        $close[$i] = [double]$r[2]
        $low[$i]   = [double]$r[4]
        $vol[$i]   = [double]$r[5]
    }

    # ---- simulate ----
    $inPos = $false; $entryPrice = 0.0; $entryDate = ''; $stopPrice = 0.0; $entryIdx = 0
    $wins = 0; $losses = 0; $grossWin = 0.0; $grossLoss = 0.0

    for ($i = 1; $i -lt $n; $i++) {
        if (-not $inPos) {
            # need at least 20 prior bars
            if ($i -lt 21) { continue }
            # pivot = highest close of prior 20 bars
            $pivot = $close[$i - 20]
            for ($j = $i - 19; $j -le $i - 1; $j++) { if ($close[$j] -gt $pivot) { $pivot = $close[$j] } }
            # 5d avg volume prior day
            $vavg = 0.0
            for ($j = $i - 5; $j -le $i - 1; $j++) { $vavg += $vol[$j] }
            $vavg = $vavg / 5.0
            $breakout = ($close[$i] -gt $pivot) -and ($vol[$i] -ge $volFactor * $vavg)
            if ($breakout) {
                # enter next bar at open; skip if opening gap too big (can't-buy / no-chase rule)
                if ($i + 1 -lt $n) {
                    $nextOpen = $open[$i + 1]
                    if ($nextOpen -le $close[$i] * (1 + $noChaseGap)) {
                        $inPos = $true
                        $entryPrice = $nextOpen
                        $entryDate = $date[$i + 1]
                        $entryIdx = $i + 1
                        # dual stop: max(hard stop, technical stop at signal-day low)
                        $techStop = $low[$i]
                        $hardLevel = $entryPrice * (1 - $hardStop)
                        $stopPrice = [Math]::Max($techStop, $hardLevel)
                    }
                }
            }
        } else {
            # MA20 of close ending at bar i
            $ma20 = 0.0
            for ($j = $i - 19; $j -le $i; $j++) { $ma20 += $close[$j] }
            $ma20 = $ma20 / 20.0
            $exitReason = $null
            if ($close[$i] -le $stopPrice) { $exitReason = 'STOP' }
            elseif ($close[$i] -lt $ma20) { $exitReason = 'MA20' }
            if ($null -ne $exitReason) {
                $exitPrice = $close[$i]
                $ret = ($exitPrice - $entryPrice) / $entryPrice
                $holdDays = $i - $entryIdx
                $stopDist = ($entryPrice - $stopPrice) / $entryPrice
                $acctRet = ($riskPct / $stopDist) * $ret   # position-sized account contribution
                if ($ret -gt 0) { $wins++; $grossWin += $ret } else { $losses++; $grossLoss += [Math]::Abs($ret) }
                [void]$allTrades.Add([pscustomobject]@{
                    Stock = $name; EntryDate = $entryDate; Entry = [math]::Round($entryPrice, 2);
                    ExitDate = $date[$i]; Exit = [math]::Round($exitPrice, 2); Reason = $exitReason;
                    RetPct = [math]::Round($ret * 100, 2); HoldDays = $holdDays;
                    AcctPct = [math]::Round($acctRet * 100, 2)
                })
                $inPos = $false
            }
        }
    }
    $tot = $wins + $losses
    $winRate = if ($tot -gt 0) { $wins / $tot } else { 0 }
    $avgW = if ($wins -gt 0) { $grossWin / $wins } else { 0 }
    $avgL = if ($losses -gt 0) { $grossLoss / $losses } else { 0 }
    $pf = if ($avgL -gt 0) { $avgW / $avgL } else { 0 }
    [void]$summaryLines.Add("$name trades=$tot wins=$wins losses=$losses winRate=$([math]::Round($winRate*100,1))% avgWin=$([math]::Round($avgW*100,2))% avgLoss=$([math]::Round($avgL*100,2))% payoffRatio=$([math]::Round($pf,2))")
}

Write-Output '==== PER-STOCK SUMMARY ===='
$summaryLines | ForEach-Object { Write-Output $_ }
Write-Output ''
Write-Output '==== TRADE LOG ===='
$allTrades | Sort-Object EntryDate | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

# ---- aggregate ----
$t = $allTrades.Count
if ($t -gt 0) {
    $w = @($allTrades | Where-Object { $_.RetPct -gt 0 })
    $l = @($allTrades | Where-Object { $_.RetPct -le 0 })
    $wr = $w.Count / $t
    $aw = if ($w.Count -gt 0) { ($w | Measure-Object RetPct -Average).Average } else { 0 }
    $al = if ($l.Count -gt 0) { [Math]::Abs(($l | Measure-Object RetPct -Average).Average) } else { 0 }
    $pr = if ($al -gt 0) { $aw / $al } else { 0 }
    $exp = $wr * $aw - (1 - $wr) * $al
    $totAcct = ($allTrades | Measure-Object AcctPct -Sum).Sum
    $maxAcct = ($allTrades | Measure-Object AcctPct -Maximum).Maximum
    $minAcct = ($allTrades | Measure-Object AcctPct -Minimum).Minimum
    $avgHold = ($allTrades | Measure-Object HoldDays -Average).Average
    $stopExits = @($allTrades | Where-Object { $_.Reason -eq 'STOP' }).Count
    $ma20Exits = @($allTrades | Where-Object { $_.Reason -eq 'MA20' }).Count
    Write-Output '==== AGGREGATE ===='
    Write-Output "totalTrades=$t winRate=$([math]::Round($wr*100,1))% avgWin=$([math]::Round($aw,2))% avgLoss=$([math]::Round($al,2))% payoffRatio=$([math]::Round($pr,2)) expectancy=$([math]::Round($exp,2))%"
    Write-Output "acctContributionSum=$([math]::Round($totAcct,2))% best=$([math]::Round($maxAcct,2))% worst=$([math]::Round($minAcct,2))% avgHoldDays=$([math]::Round($avgHold,1))"
    Write-Output "exits: STOP=$stopExits MA20=$ma20Exits"
}

# save trade log csv
$outCsv = Join-Path $PSScriptRoot '..\docs\backtest-trades.csv'
$allTrades | Sort-Object EntryDate | Export-Csv -NoTypeInformation -Encoding UTF8 $outCsv
Write-Output ("CSV saved: " + (Resolve-Path $outCsv).Path)
