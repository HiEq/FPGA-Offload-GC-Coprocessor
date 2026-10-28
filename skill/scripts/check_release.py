#!/usr/bin/env python3
"""check_release.py — 校验发布资产与 SHA256SUMS 是否一致。

用法:
    python3 check_release.py <dir> [checksums_file]

<dir>            资产所在目录
checksums_file   默认 <dir>/SHA256SUMS.release

退出码: 0 全部一致；1 有不一致或缺失；2 参数/文件问题。
适用: 任何以 sha256sum 清单发布的仓库；不依赖第三方库。
失效条件: 清单格式不是 "<hash>  <name>" 两列时需自行调整解析。
"""
import hashlib, os, sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def parse(line):
    parts = line.split()
    if len(parts) < 2:
        return None
    return parts[0].lower(), parts[-1].lstrip('*')


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    d = argv[1]
    sums = argv[2] if len(argv) > 2 else os.path.join(d, 'SHA256SUMS.release')
    if not os.path.isfile(sums):
        print('missing checksums file:', sums)
        return 2

    bad = 0
    rows = []
    for line in open(sums, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        item = parse(line)
        if not item:
            continue
        want, name = item
        path = os.path.join(d, name)
        if not os.path.isfile(path):
            rows.append((name, 'MISSING', '-'))
            bad += 1
            continue
        got = sha256(path)
        ok = (got == want)
        rows.append((name, 'OK' if ok else 'MISMATCH', got[:12]))
        bad += 0 if ok else 1

    width = max([len(r[0]) for r in rows] + [4])
    for name, status, digest in rows:
        print('%-*s  %-9s %s' % (width, name, status, digest))
    print('\n%d file(s), %d problem(s)' % (len(rows), bad))
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
