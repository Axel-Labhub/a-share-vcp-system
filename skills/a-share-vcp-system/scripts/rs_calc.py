#!/usr/bin/env python3
"""板块代理 RS 批量计算脚本 — a-share-vcp-system v1.5

对一线代表股 K 线批量计算：20 日涨幅中位数（代理涨幅）、一致性、
5 日动量、代理 RS，并按硬门槛给出确定性判定，避免人工解读偏差。

用法:
    python rs_calc.py --config rs_config.json [--json]

配置 JSON 结构:
{
  "benchmark": {"file": "上证指数K线.json"},
  "sectors": {
    "板块名": {"股票代码": "个股K线.json", ...},
    ...
  }
}

K 线 JSON 与 vcp_calc.py 相同（finance-data result_json_path 下载件，
sql_answer 按 trade_date 降序，脚本内部反转升序）。

判定规则（v1.5 硬门槛，全部确定性计算，禁止人工覆盖）:
  - 一致性 < 50%（代表股 20 日涨幅为正的比例）→ 降级(一致性不足)
  - 代理 RS ≤ 0                                  → 降级(负RS)
  - 5 日涨幅中位数 < −3%                          → 降级(5日动量背离)
  - 全部通过                                      → 主线候选
设计动机：08-21 实测均值法被单股绑架（医药 +7.42% 全靠药明康德
+30.3%，恒瑞实为 −10.7%）。中位数抗单股异常；一致性验证板块宽度
（真主线是群体上涨）；5 日动量把二线复核从主观解读变成可复现闸门。
"""
import argparse
import json


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
    seen = {}
    for r in rows:
        seen[str(r["trade_date"])] = r
    return [seen[d] for d in sorted(seen)]


def closes_of(path):
    return [float(r["close"]) for r in load_rows(path)]


def chg(closes, n):
    if len(closes) < n + 1:
        return None
    return closes[-1] / closes[-1 - n] - 1


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return None
    mid = n // 2
    return xs[mid] if n % 2 else (xs[mid - 1] + xs[mid]) / 2


def pct(x, nd=2):
    return None if x is None else round(x * 100, nd)


def main():
    ap = argparse.ArgumentParser(description="板块代理 RS 批量计算（v1.5）")
    ap.add_argument("--config", required=True, help="rs_config.json 路径")
    ap.add_argument("--json", action="store_true", help="输出 JSON 而非 Markdown 表")
    args = ap.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    bench_closes = closes_of(cfg["benchmark"]["file"])
    bench_20d = chg(bench_closes, 20)
    bench_date = str(load_rows(cfg["benchmark"]["file"])[-1]["trade_date"])

    results = []
    for sector, stocks in cfg["sectors"].items():
        per_stock = {}
        for code, path in stocks.items():
            closes = closes_of(path)
            per_stock[code] = {"chg20": chg(closes, 20), "chg5": chg(closes, 5)}
        c20 = [v["chg20"] for v in per_stock.values() if v["chg20"] is not None]
        c5 = [v["chg5"] for v in per_stock.values() if v["chg5"] is not None]
        med20 = median(c20)
        med5 = median(c5)
        consistency = (sum(1 for c in c20 if c > 0) / len(c20)) if c20 else 0.0
        proxy_rs = None if (med20 is None or bench_20d is None) else med20 - bench_20d

        fails = []
        if consistency < 0.5:
            fails.append("一致性不足")
        if proxy_rs is not None and proxy_rs <= 0:
            fails.append("负RS")
        if med5 is not None and med5 < -0.03:
            fails.append("5日动量背离")
        verdict = "主线候选" if not fails else "降级(" + "+".join(fails) + ")"

        results.append({
            "sector": sector,
            "n_stocks": len(c20),
            "per_stock_chg20_pct": {k: pct(v["chg20"]) for k, v in per_stock.items()},
            "proxy_chg20_pct": pct(med20),
            "consistency": round(consistency, 2),
            "med_chg5_pct": pct(med5),
            "proxy_rs_pct": pct(proxy_rs),
            "verdict": verdict,
        })

    results.sort(key=lambda r: (r["verdict"] == "主线候选",
                                r["proxy_rs_pct"] if r["proxy_rs_pct"] is not None else -999),
                 reverse=True)

    if args.json:
        print(json.dumps({"benchmark_date": bench_date,
                          "bench_chg20_pct": pct(bench_20d),
                          "sectors": results}, ensure_ascii=False, indent=2))
        return

    print(f"基准: 上证指数 20日涨幅 {pct(bench_20d)}%（截至 {bench_date}）")
    print()
    print("| 板块 | 样本 | 代理20日涨幅(中位数) | 一致性 | 5日动量(中位数) | 代理RS | 判定 |")
    print("|------|------|------|------|------|------|------|")
    for r in results:
        print(f"| {r['sector']} | {r['n_stocks']} | {r['proxy_chg20_pct']}% | "
              f"{int(r['consistency']*100)}% | {r['med_chg5_pct']}% | "
              f"{r['proxy_rs_pct']}% | {r['verdict']} |")
    print()
    print("代表股明细（20日涨幅）:")
    for r in results:
        detail = ", ".join(f"{k}:{v}%" for k, v in r["per_stock_chg20_pct"].items())
        print(f"- {r['sector']}: {detail}")


if __name__ == "__main__":
    main()
