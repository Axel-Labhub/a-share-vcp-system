#!/usr/bin/env python3
"""VCP 确定性计算脚本 — a-share-vcp-system v1.5

解析 finance-data 技能返回的 K 线结果 JSON（result_json_path 下载件），
按体系规则计算 MA20、枢轴、量比、收缩、止损位、参考仓位与状态分类。

用法:
    python vcp_calc.py <kline.json> [--code 603986] [--cost 120.0]
                       [--risk 0.02] [--board main|20cm] [--json]

输入 JSON 结构: 顶层键为查询语句（'__meta__' 除外），值为
[{"sql": ..., "sql_answer": [{trade_date, close, high, low, volume, ...}, ...]}]
行序为 trade_date 降序，脚本内部反转升序后计算。

规则出处: references/rules.md 参数总表。仅输出规则计算结果，不作买卖结论。
"""
import argparse
import json
import sys


def load_rows(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    rows = []
    for key, val in data.items():
        if key == "__meta__" or not isinstance(val, list):
            continue
        for entry in val:
            if isinstance(entry, dict) and "sql_answer" in entry:
                rows.extend(entry["sql_answer"])
    # 去重并按日期升序
    seen = {}
    for r in rows:
        seen[str(r["trade_date"])] = r
    return [seen[d] for d in sorted(seen)]


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def calc(rows, cost=None, risk=0.02, board="main", max_pos=0.25):
    n = len(rows)
    if n < 25:
        raise ValueError(f"K线不足25根（实际{n}根），无法计算")
    closes = [float(r["close"]) for r in rows]
    lows = [float(r["low"]) for r in rows]
    vols = [float(r["volume"]) for r in rows]
    last = closes[-1]
    date = str(rows[-1]["trade_date"])

    ma20 = mean(closes[-20:])
    # 枢轴 = 前20日最高收盘（不含当日）
    pivot = max(closes[-21:-1]) if n >= 21 else max(closes[:-1])
    dist_pivot = last / pivot - 1

    vol5 = mean(vols[-5:])
    vol_prev15 = mean(vols[-20:-5]) if n >= 20 else None
    vol_shrink = (vol_prev15 is not None and vol5 <= vol_prev15)
    vol_ratio = (vol5 / vol_prev15) if vol_prev15 else None

    # 收缩：近60日分3段，最新段振幅 < 第一段振幅
    contracted = None
    amps = []
    if n >= 60:
        segs = [closes[-60:-40], closes[-40:-20], closes[-20:]]
        amps = [(max(s) - min(s)) / min(s) for s in segs]
        contracted = amps[2] < amps[0]

    low10 = min(lows[-10:])
    hard_mult = 0.92 if board == "main" else 0.88
    hard_stop = cost * hard_mult if cost else None
    stop = low10 if hard_stop is None else max(low10, hard_stop)
    stop_dist = (last - stop) / last  # >0 表示当前价高于止损位

    position = None
    pos_warn = None
    if stop_dist > 0:
        position = min(risk / stop_dist, max_pos)
    else:
        pos_warn = "止损位不低于现价（可能是突破失败或深套仓位），仓位公式不适用"

    above_ma20 = last >= ma20
    near_pivot = last >= pivot * 0.95
    if last > pivot:
        status = "已突破"
    elif not above_ma20:
        status = "破20日线(出清区)"
    elif contracted and vol_shrink and near_pivot:
        status = "VCP就绪"
    elif near_pivot:
        status = "逼近(未收缩)"
    else:
        status = "观察(远离枢轴)"

    # v1.5 优化C：破20日线（出清区）不输出参考仓位，避免误导
    if status == "破20日线(出清区)":
        position = None
        pos_warn = "已破20日线（出清区），不输出参考仓位"

    # v1.5 优化C：已突破时计算突破后累计涨幅，>15% 标注追高风险
    breakout_gain_pct = None
    chase_risk = None
    if status == "已突破":
        breakout_gain_pct = dist_pivot  # 当前收盘 / 枢轴 - 1
        if breakout_gain_pct > 0.15:
            chase_risk = f"突破后已涨{round(breakout_gain_pct*100, 1)}%，追高风险大，等回踩"

    return {
        "date": date,
        "close": round(last, 2),
        "ma20": round(ma20, 2),
        "above_ma20": above_ma20,
        "pivot": round(pivot, 2),
        "dist_to_pivot_pct": round(dist_pivot * 100, 2),
        "vol_ratio_5d_vs_prev15d": round(vol_ratio, 3) if vol_ratio else None,
        "vol_shrink": vol_shrink,
        "segment_amplitudes_pct": [round(a * 100, 2) for a in amps] if amps else None,
        "contracted": contracted,
        "low10": round(low10, 2),
        "hard_stop": round(hard_stop, 2) if hard_stop else None,
        "stop": round(stop, 2),
        "stop_dist_pct": round(stop_dist * 100, 2),
        "ref_position_pct": round(position * 100, 1) if position is not None else None,
        "position_warn": pos_warn,
        "breakout_gain_pct": round(breakout_gain_pct * 100, 2) if breakout_gain_pct is not None else None,
        "chase_risk": chase_risk,
        "status": status,
        "bars": n,
    }


def main():
    ap = argparse.ArgumentParser(description="VCP 确定性计算")
    ap.add_argument("json_path", help="finance-data K线结果JSON文件路径")
    ap.add_argument("--code", default="", help="股票代码（仅用于输出展示）")
    ap.add_argument("--cost", type=float, default=None, help="持仓成本（启用硬止损，存量仓位纳管用）")
    ap.add_argument("--risk", type=float, default=0.02, help="单笔风险比例，默认0.02")
    ap.add_argument("--board", choices=["main", "20cm"], default="main", help="硬止损档位: main=主板8%%, 20cm=12%%")
    ap.add_argument("--json", action="store_true", help="输出JSON而非Markdown行")
    args = ap.parse_args()

    rows = load_rows(args.json_path)
    res = calc(rows, cost=args.cost, risk=args.risk, board=args.board)
    res["code"] = args.code

    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        line = (f"| {args.code or '-'} | {res['date']} | {res['close']} | MA20={res['ma20']} | "
                f"枢轴={res['pivot']} | 距枢轴={res['dist_to_pivot_pct']}% | "
                f"量比={res['vol_ratio_5d_vs_prev15d']} | 止损={res['stop']} "
                f"(距离{res['stop_dist_pct']}%) | 参考仓位="
                f"{res['ref_position_pct'] if res['ref_position_pct'] is not None else 'N/A'}% | "
                f"{res['status']} |")
        print(line)
        if res.get("chase_risk"):
            print(f"  ⚠️ {res['chase_risk']}")
        if res.get("position_warn"):
            print(f"  ⚠️ {res['position_warn']}")


if __name__ == "__main__":
    main()
