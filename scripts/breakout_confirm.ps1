$ErrorActionPreference = 'Stop'

function Get-Kline($sym, $days) {
    $url = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$sym,day,,,$days,qfq"
    $tmp = Join-Path $env:TEMP ("cmp_" + $sym + ".json")
    curl.exe -s -o $tmp $url
    $raw = Get-Content -Raw -Encoding UTF8 $tmp
    $json = $raw | ConvertFrom-Json
    $node = $json.data.$sym
    if ($node.PSObject.Properties.Name -contains 'qfqday') { return $node.qfqday }
    return $node.day
}

# ---- breakout day anatomy for 300763 ----
$k = Get-Kline 'sz300763' 60
$n = $k.Count
$i = $n - 1
$po = [double]$k[$i][1]; $pc = [double]$k[$i][2]; $ph = [double]$k[$i][3]; $pl = [double]$k[$i][4]; $pv = [double]$k[$i][5]
$prevC = [double]$k[$i-1][2]
$closePos = [math]::Round(($pc - $pl) / ($ph - $pl) * 100, 1)
$gapOpen = [math]::Round(($po - $prevC) / $prevC * 100, 2)
$dayRet = [math]::Round(($pc - $prevC) / $prevC * 100, 2)
Write-Output ("BREAKOUT BAR 300763: open={0} high={1} low={2} close={3} vol={4:N0}" -f $po, $ph, $pl, $pc, $pv)
Write-Output ("  gapOpen={0}% dayRet={1}% closePosInRange={2}% (100=close at high)" -f $gapOpen, $dayRet, $closePos)
Write-Output ("  upperShadow={0}% body={1}%" -f [math]::Round(($ph-$pc)/$prevC*100,2), [math]::Round(($pc-$po)/$prevC*100,2))

# ---- sector comparison ----
$peers = @('sz300763','sz300274','sz002459','sh600438','sh688390','sh605117','sh601012')
Write-Output ''
Write-Output '=== SECTOR PEER DASHBOARD (as of 2026-08-11 close) ==='
Write-Output 'code | close | 1d | 5d | since0807 | vsPivot20 | volRatio | vsMA20 | state'

foreach ($sym in $peers) {
    $pk = Get-Kline $sym 60
    if ($null -eq $pk) { Write-Output "$sym NO_DATA"; continue }
    $m = $pk.Count
    $c = New-Object double[] $m
    $v = New-Object double[] $m
    $d = New-Object string[] $m
    for ($j = 0; $j -lt $m; $j++) { $d[$j] = [string]$pk[$j][0]; $c[$j] = [double]$pk[$j][2]; $v[$j] = [double]$pk[$j][5] }

    $r1 = [math]::Round(($c[$m-1]-$c[$m-2])/$c[$m-2]*100, 2)
    $r5 = [math]::Round(($c[$m-1]-$c[$m-6])/$c[$m-6]*100, 2)

    # since 08-07: find index of 2026-08-07
    $i0807 = -1
    for ($j = 0; $j -lt $m; $j++) { if ($d[$j] -eq '2026-08-07') { $i0807 = $j; break } }
    $rSince = 'NA'
    if ($i0807 -ge 0) { $rSince = [math]::Round(($c[$m-1]-$c[$i0807])/$c[$i0807]*100, 2) }

    # pivot = max close of prior 20 bars
    $pivot = $c[$m-21]
    for ($j = $m-20; $j -le $m-2; $j++) { if ($c[$j] -gt $pivot) { $pivot = $c[$j] } }
    $vsPivot = [math]::Round(($c[$m-1]-$pivot)/$pivot*100, 2)

    # vol ratio: today vs prior 5d avg
    $v5p = 0.0; for ($j = $m-6; $j -le $m-2; $j++) { $v5p += $v[$j] }; $v5p = $v5p / 5
    $vr = [math]::Round($v[$m-1] / $v5p, 2)

    # MA20
    $ma = 0.0; for ($j = $m-20; $j -le $m-1; $j++) { $ma += $c[$j] }; $ma = $ma / 20
    $vsMa = [math]::Round(($c[$m-1]-$ma)/$ma*100, 1)

    $state = 'FAR'
    if ($c[$m-1] -gt $pivot) { $state = 'ABOVE_PIVOT' }
    elseif ($c[$m-1] -ge $pivot * 0.95) { $state = 'NEAR_PIVOT' }

    Write-Output ("{0} | {1} | {2}% | {3}% | {4}% | {5}% | {6}x | {7}% | {8}" -f $sym, $c[$m-1], $r1, $r5, $rSince, $vsPivot, $vr, $vsMa, $state)
}

# ---- breadth: how many peers above their own MA20 / above pivot ----
Write-Output ''
Write-Output '=== 300763 LAST 3 BARS vs SUNGROW 300274 LAST 3 BARS ==='
foreach ($sym in @('sz300763','sz300274')) {
    $pk = Get-Kline $sym 10
    $m = $pk.Count
    Write-Output ("--- $sym ---")
    for ($j = $m-3; $j -le $m-1; $j++) {
        $cj = [double]$pk[$j][2]; $pj = [double]$pk[$j-1][2]; $vj = [double]$pk[$j][5]
        $chg = [math]::Round(($cj-$pj)/$pj*100, 2)
        Write-Output ("{0} close={1} chg={2}% vol={3:N0}" -f [string]$pk[$j][0], $cj, $chg, $vj)
    }
}
Write-Output 'DONE.'
