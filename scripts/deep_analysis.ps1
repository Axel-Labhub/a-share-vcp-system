$ErrorActionPreference = 'Stop'

function Get-Kline($sym, $days) {
    $url = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$sym,day,,,$days,qfq"
    $tmp = Join-Path $env:TEMP ("deep_" + $sym + ".json")
    curl.exe -s -o $tmp $url
    $raw = Get-Content -Raw -Encoding UTF8 $tmp
    $json = $raw | ConvertFrom-Json
    $node = $json.data.$sym
    if ($node.PSObject.Properties.Name -contains 'qfqday') { return $node.qfqday }
    return $node.day
}

$k = Get-Kline 'sz300763' 250
$n = $k.Count
$date = New-Object string[] $n
$close = New-Object double[] $n
$high = New-Object double[] $n
$low = New-Object double[] $n
$vol = New-Object double[] $n
for ($i = 0; $i -lt $n; $i++) {
    $date[$i] = [string]$k[$i][0]
    $close[$i] = [double]$k[$i][2]
    $high[$i] = [double]$k[$i][3]
    $low[$i] = [double]$k[$i][4]
    $vol[$i] = [double]$k[$i][5]
}
Write-Output "BARS=$n from $($date[0]) to $($date[$n-1])"

# 250d extremes
$hi250 = $high[0]; $hiD = $date[0]; $lo250 = $low[0]; $loD = $date[0]
for ($i = 1; $i -lt $n; $i++) {
    if ($high[$i] -gt $hi250) { $hi250 = $high[$i]; $hiD = $date[$i] }
    if ($low[$i] -lt $lo250) { $lo250 = $low[$i]; $loD = $date[$i] }
}
$offHigh = [math]::Round(($close[$n-1]-$hi250)/$hi250*100, 1)
Write-Output ("250d HIGH={0} on {1} | LOW={2} on {3} | lastClose={4} | off-high={5}%" -f $hi250, $hiD, $lo250, $loD, $close[$n-1], $offHigh)

# fractal swings window 3, last 140 bars
$sw = New-Object System.Collections.ArrayList
$start = [Math]::Max(3, $n - 140)
for ($i = $start; $i -le $n - 4; $i++) {
    $isHi = $true; $isLo = $true
    for ($j = 1; $j -le 3; $j++) {
        if ($high[$i] -le $high[$i-$j] -or $high[$i] -le $high[$i+$j]) { $isHi = $false }
        if ($low[$i] -ge $low[$i-$j] -or $low[$i] -ge $low[$i+$j]) { $isLo = $false }
    }
    if ($isHi) { [void]$sw.Add([pscustomobject]@{ T='H'; D=$date[$i]; P=$high[$i] }) }
    if ($isLo) { [void]$sw.Add([pscustomobject]@{ T='L'; D=$date[$i]; P=$low[$i] }) }
}
Write-Output '--- SWING SEQUENCE ---'
foreach ($s in $sw) { Write-Output ("{0} {1} {2}" -f $s.T, $s.D, $s.P) }

# pullback depths: each H followed by next L
Write-Output '--- PULLBACK DEPTHS (H->L) ---'
for ($i = 0; $i -lt $sw.Count - 1; $i++) {
    if ($sw[$i].T -eq 'H') {
        for ($j = $i + 1; $j -lt $sw.Count; $j++) {
            if ($sw[$j].T -eq 'L') {
                $d = ($sw[$i].P - $sw[$j].P) / $sw[$i].P
                Write-Output ("{0} H={1} -> {2} L={3} depth={4:P1}" -f $sw[$i].D, $sw[$i].P, $sw[$j].D, $sw[$j].P, $d)
                break
            }
        }
    }
}

# volume phases
$v60 = 0.0; for ($i = $n-60; $i -le $n-1; $i++) { $v60 += $vol[$i] }; $v60 /= 60
$v60p = 0.0; for ($i = $n-120; $i -le $n-61; $i++) { $v60p += $vol[$i] }; $v60p /= 60
$v20 = 0.0; for ($i = $n-20; $i -le $n-1; $i++) { $v20 += $vol[$i] }; $v20 /= 20
$v5 = 0.0; for ($i = $n-5; $i -le $n-1; $i++) { $v5 += $vol[$i] }; $v5 /= 5
$v5b = 0.0; for ($i = $n-6; $i -le $n-2; $i++) { $v5b += $vol[$i] }; $v5b /= 5
Write-Output ("VOL: avg120-60dAgo={0:N0} avg60d={1:N0} avg20d={2:N0} avg5d={3:N0} today={4:N0} todayVs5dPrior={5:F2}x" -f $v60p, $v60, $v20, $v5, $vol[$n-1], ($vol[$n-1]/$v5b))

# breakout structure
$pivot = $close[$n-21]
for ($i = $n-20; $i -le $n-2; $i++) { if ($close[$i] -gt $pivot) { $pivot = $close[$i] } }
$ma20 = 0.0; for ($i = $n-20; $i -le $n-1; $i++) { $ma20 += $close[$i] }; $ma20 /= 20
$ma50 = 0.0; for ($i = $n-50; $i -le $n-1; $i++) { $ma50 += $close[$i] }; $ma50 /= 50
$ma100 = 0.0; for ($i = $n-100; $i -le $n-1; $i++) { $ma100 += $close[$i] }; $ma100 /= 100
$ma200 = 0.0; for ($i = $n-200; $i -le $n-1; $i++) { $ma200 += $close[$i] }; $ma200 /= 200
$abovePct = [math]::Round(($close[$n-1]-$pivot)/$pivot*100, 2)
Write-Output ("PIVOT(prior20d maxClose)={0} | todayClose={1} above by {2}% | MA20={3:N2} MA50={4:N2} MA100={5:N2} MA200={6:N2}" -f $pivot, $close[$n-1], $abovePct, $ma20, $ma50, $ma100, $ma200)
$vsMa200 = [math]::Round(($close[$n-1]-$ma200)/$ma200*100, 1)
$ma20gt50 = ($ma20 -gt $ma50); $ma50gt100 = ($ma50 -gt $ma100); $ma100gt200 = ($ma100 -gt $ma200)
Write-Output ("vs MA200: {0}% | MA20>MA50: {1} | MA50>MA100: {2} | MA100>MA200: {3}" -f $vsMa200, $ma20gt50, $ma50gt100, $ma100gt200)

# returns
$r5 = ($close[$n-1]-$close[$n-6])/$close[$n-6]
$r20 = ($close[$n-1]-$close[$n-21])/$close[$n-21]
$r60 = ($close[$n-1]-$close[$n-61])/$close[$n-61]
Write-Output ("RET 5d={0:P2} 20d={1:P2} 60d={2:P2}" -f $r5, $r20, $r60)

# last 15 bars
Write-Output '--- LAST 15 BARS ---'
for ($i = $n-15; $i -le $n-1; $i++) {
    $chg = ($close[$i]-$close[$i-1])/$close[$i-1]
    Write-Output ("{0} close={1,7} chg={2,6:P2} vol={3,9:N0}" -f $date[$i], $close[$i], $chg, $vol[$i])
}

# peer RS comparison 20d/60d
Write-Output '--- PEER RS (20d / 60d ret) ---'
$peers = @('sz300763','sz300274','sz002459','sh600438','sh688390','sh000001')
foreach ($p in $peers) {
    $pk = Get-Kline $p 130
    if ($null -eq $pk) { Write-Output "$p NO_DATA"; continue }
    $pn = $pk.Count
    $pc = @(); foreach ($r in $pk) { $pc += [double]$r[2] }
    $pr20 = ($pc[$pn-1]-$pc[$pn-21])/$pc[$pn-21]
    $pr60 = ($pc[$pn-1]-$pc[$pn-61])/$pc[$pn-61]
    Write-Output ("{0} 20d={1,7:P2} 60d={2,7:P2}" -f $p, $pr20, $pr60)
}
Write-Output 'DONE.'
