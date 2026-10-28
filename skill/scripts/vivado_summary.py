#!/usr/bin/env python3
"""vivado_summary.py — 从 Vivado 报告提取资源与时序，输出 Markdown 表。

用法:
    python3 vivado_summary.py <utilization.rpt> [timing_summary.rpt]

资源行取自 "Report Utilizations" 表的 CLB LUTs / CLB Registers / Block RAM Tile / DSPs；
时序取自 "Design Timing Summary" 的 WNS/WHS。
适用: Vivado 2020.x–2026.x 的实现报告（report_utilization / report_timing_summary）。
失效条件: 报告语言非英文、或用了自定义模板时，关键词需调整。
"""
import re, sys


def util(path):
    want = {
        'CLB LUTs': 'LUT', 'Slice LUTs': 'LUT',
        'CLB Registers': 'FF', 'Slice Registers': 'FF',
        'Block RAM Tile': 'BRAM', 'DSPs': 'DSP',
    }
    out, seen = [], set()
    for line in open(path, encoding='utf-8', errors='replace'):
        s = line.strip()
        if not s.startswith('| '):
            continue
        for key, label in want.items():
            if s.startswith('| ' + key) and label not in seen:
                cells = [c.strip() for c in s.strip('|').split('|')]
                if len(cells) >= 3:
                    used = cells[1]
                    pct = cells[-1] if len(cells) >= 6 else cells[2]
                    out.append((label, used, pct))
                    seen.add(label)
    order = {'LUT': 0, 'FF': 1, 'BRAM': 2, 'DSP': 3}
    return sorted(out, key=lambda r: order.get(r[0], 9))


def timing(path):
    res = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        if 'WNS(ns)' in line and 'WHS(ns)' in line:
            continue
        m = re.match(r'\s*(-?\d+\.\d+)\s+-?\d+\.\d+\s+\d+\s+\d+\s+(-?\d+\.\d+)', line)
        if m and 'WNS' not in res:
            res['WNS'] = m.group(1)
            res['WHS'] = m.group(2)
    if 'WNS' not in res:
        for line in open(path, encoding='utf-8', errors='replace'):
            if 'All user specified timing constraints are met' in line:
                res['constraints'] = 'met'
            elif 'Timing constraints are not met' in line:
                res['constraints'] = 'NOT met'
    return res


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    rows = util(argv[1])
    print('| 资源 | 使用 | 占比 |')
    print('|---|---|---|')
    for label, used, pct in rows:
        print('| %s | %s | %s |' % (label, used, pct))
    if len(argv) > 2:
        t = timing(argv[2])
        print('\n| 时序 | 值 |')
        print('|---|---|')
        for k in ('WNS', 'WHS', 'constraints'):
            if k in t:
                print('| %s | %s |' % (k, t[k]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
