# 板测日志头模板

> 复制到每条日志开头；没有命令与哈希的数字不可引用。

```
# command: <完整命令行，含参数与种子>
# dut      : <板卡型号 / 器件>
# bitstream: <md5>
# boot.bin : <sha256>
# image    : <sha256>（内核/rootfs 镜像）
# date     : <YYYY-MM-DD>
# operator : <谁跑的>
# expected : <关键判定行，如 PASSED (all invariants): 8/8>
# result   : <PASS / FAIL / 部分>
```

## 记录规范
- 一次运行一个文件；不要追加到旧日志里
- 失败也要保留，并在 `# result` 后写一句现象
- 若中途改过板卡状态（重新烧写、重启），另起一条并写清起点
