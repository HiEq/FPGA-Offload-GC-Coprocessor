# JamVM 适配器

本目录把 FOGCCC 接入 JamVM，使真实 Java 负载的标记阶段可以由 PL 完成。
适配器只替换标记：对象布局、分配器、清扫与 CPU 回退保持 JamVM 原样。

## 1. 组成

| 文件 | 作用 |
| --- | --- |
| `jamvm-patch/apply_patch.py` | 标记钩子、堆访问器、故障钩子 |
| `jamvm-patch/apply_addr_order.py` | 按堆地址顺序分配 id（重建前的预扫描） |
| `jamvm-patch/apply_card.py` | 脏位图、脏环与写屏障 |
| `jamvm-patch/apply_incr.py` | 导出、接管、id 回收、重建过滤、DaCapo 统计 |
| `jamvm-patch/fogccc_shadow.c` | 旁表、id 表、导出/导入、STW 计时 |
| `jamvm-patch/fogccc_shadow.h` | 适配器内部接口 |
| `build_jamvm_fogccc.sh` | 取 JamVM 源码、打补丁、交叉编译 `libjvm.so` |
| `test/` | 自研负载（`FogcccWorkload`、`G1M` 等） |

## 2. 构建

```sh
# 需要 PetaLinux SDK 的 cortexa9t2hf-neon 环境
cd jvm-shadow
./build_jamvm_fogccc.sh
# 产物：$HOME/jamvm-fogccc/lib/libjvm.so
```

`configure` 固定两个选项：

| 选项 | 原因 |
| --- | --- |
| `--disable-int-inlining` | 运行时内联器生成的 `rwx` 代码在本板会随机崩溃；原版 JamVM 同样复现 |
| `--with-java-runtime-library=openjdk8` | 与卡上的 Zulu 8 配对 |

安装：把 `libjvm.so` 放到 `jre/lib/aarch32/jamvm-fogccc/`，并用
`-XXaltjvm=jamvm-fogccc` 启动。

## 3. 运行参数

| 变量 | 作用 |
| --- | --- |
| `FOGCCC_SHADOW=1` | 打开适配器 |
| `FOGCCC_TAKEOVER=1` | 用硬件标记结果接管（否则只做对照） |
| `FOGCCC_TAKEOVER_COLD=1` | 第一次 GC 就接管；只在带 verify 时安全 |
| `FOGCCC_TAKEOVER_VERIFY=1` | 用 CPU 闭包校验硬件结果，并补全差异 |
| `FOGCCC_TAKEOVER_DECIDE=0` | 关闭代价决策，强制使用硬件 |
| `FOGCCC_STW=1` | 打印每次 GC 的 STW 停顿与 id 统计 |
| `FOGCCC_NO_FILTER=1` | 负控：重建时导出全部块 |

固定堆 `-Xms == -Xmx` 是必需条件。JamVM 在堆扩容或压缩后会破坏内存，
原版同样复现。

## 4. DaCapo

完整配方见仓库根目录 `README.md` 的「DaCapo」一节。日常回归：

```sh
sh tools/dacapo_quick.sh     # luindex + pmd + xalan + lusearch，约 75 秒
```

## 5. 结果

数据集：DaCapo 9.12-MR1 `-s small`；`G1M 1000000`（100 万结点，3 次
`System.gc()`）。命令与环境见上一节。日期 2026-11-08，tag `v5.0`，
`libjvm.so` md5 `d52939ee1d82b6cb0c2ec5b3120808bb`。

### 5.1 1M 负载（`-Xms700m -Xmx700m`）

| 指标 | 硬件接管 | 原版 JamVM | 比值 |
| --- | ---: | ---: | ---: |
| 纯 mark | 73.9 ms | 350 ms | 4.7× |
| 稳态整次 GC 停顿 | 256 ms | 428 ms | 1.67× |
| 第一次重建轮 | 1000 ms | 428 ms | 0.43× |

稳态 256 ms 由 mark 73.9、bitmap import 68.1、clearMarkBits 10.8、
id 回收 26.2 与 sweep/挂起恢复约 77 ms 组成。

### 5.2 6 个 DaCapo 基准（COLD + verify，`-Xms700m -Xmx700m`）

| 基准 | HW 端到端 | SW 端到端 | HW 纯 mark | SW 纯 mark | verify |
| --- | ---: | ---: | ---: | ---: | ---: |
| avrora | 91,682 ms | 92,143 ms | 3.2 ms | 70.3 ms | 0 |
| luindex | 2,542 | 2,483 | 3.8 | 70.5 | 0 |
| lusearch | 16,958 | 16,798 | 2.9 | 66.8 | 0 |
| pmd | 1,618 | 1,582 | 3.3 | 68.5 | 0 |
| sunflow | 51,148 | 51,167 | 6.0 | 75.4 | 0 |
| xalan | 15,441 | 15,339 | 8.3 | 79.7 | 0 |

纯 mark 9.6–23×。6 个基准全部通过，`verify_extra=0`。

## 6. 边界

| 边界 | 说明 |
| --- | --- |
| id 空间 | 20 位，上限 1,048,576。导出在 mark 之前，两次 GC 之间分配的块数必须小于该值 |
| 图区 | 64 MiB（头 16 B/对象 + 引用区） |
| 小图 | 数万对象时导入、重建与清扫的固定开销大于 CPU mark；默认决策门回退 CPU |
| 冷接管 | `FOGCCC_TAKEOVER_COLD=1` 只在带 verify 时安全；启动期根集不完整 |
| 类对象 | 每个导出的 Class 都登记为硬件根；JamVM 不卸载类 |

## 7. 自研负载

| 负载 | 用途 |
| --- | --- |
| `test/G1M.java` | 1M 结点、3 次 `System.gc()`；测 STW |
| `test/FogcccWorkload.java` | 可配置结点数与平均出边；验证闭包 |
| `test/FogcccTree.java` / `FogcccMutate.java` / `FogcccThreads.java` | 树、变更、线程场景 |
| `test/HelloWorld.java` | 冒烟 |
