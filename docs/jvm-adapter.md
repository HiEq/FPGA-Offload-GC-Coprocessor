# JamVM 适配器

本目录把 FOGCCC 接入 JamVM，使真实 Java 负载的标记阶段可以由 PL 完成。
适配器只替换标记：对象布局、分配器、清扫与 CPU 回退保持 JamVM 原样。

## 1. 组成

| 文件 | 作用 |
| --- | --- |
| jamvm-patch/apply_patch.py | 标记钩子、堆访问器、故障钩子 |
| jamvm-patch/apply_addr_order.py | 按堆地址顺序分配 id（重建前的预扫描） |
| jamvm-patch/apply_card.py | 脏位图、脏环与写屏障 |
| jamvm-patch/apply_incr.py | 导出、接管、id 回收、重建过滤、DaCapo 统计 |
| jamvm-patch/fogccc_shadow.c | 旁表、id 表、导出/导入、STW 计时 |
| jamvm-patch/fogccc_shadow.h | 适配器内部接口 |
| build_jamvm_fogccc.sh | 取 JamVM 源码、打补丁、交叉编译 libjvm.so |
| test/ | 自研负载（G1M、FogcccWorkload 等） |

## 2. 构建

需要 PetaLinux SDK 的 cortexa9t2hf-neon 环境。

```sh
cd jvm-shadow
./build_jamvm_fogccc.sh
# 产物：$HOME/jamvm-fogccc/lib/libjvm.so
```

configure 固定两个选项：

| 选项 | 原因 |
| --- | --- |
| --disable-int-inlining | 运行时内联器生成的 rwx 代码在本板会随机崩溃；原版 JamVM 同样复现 |
| --with-java-runtime-library=openjdk8 | 与卡上的 Zulu 8 配对 |

## 3. 运行参数

| 变量 | 作用 |
| --- | --- |
| FOGCCC_SHADOW=1 | 打开适配器 |
| FOGCCC_TAKEOVER=1 | 用硬件标记结果接管（否则只做对照） |
| FOGCCC_TAKEOVER_COLD=1 | 第一次 GC 就接管；只在带 verify 时安全 |
| FOGCCC_TAKEOVER_VERIFY=1 | 用 CPU 闭包校验硬件结果，并补全差异 |
| FOGCCC_TAKEOVER_DECIDE=0 | 关闭代价决策，强制使用硬件 |
| FOGCCC_STW=1 | 打印每次 GC 的 STW 停顿与 id 统计 |
| FOGCCC_NO_FILTER=1 | 负控：重建时导出全部块 |

固定堆 -Xms == -Xmx 是必需条件。JamVM 在堆扩容或压缩后会破坏内存，
原版同样复现。

## 4. 板上运行

板上的 JVM 与 DaCapo 路径：

```sh
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
D=/run/media/USERDATA-mmcblk0p2/dacapo-9.12-MR1-bach.jar
```

### 4.1 安装 libjvm

```sh
cd /run/media/USERDATA-mmcblk0p2/jvm/zulu8/jre/lib/aarch32/jamvm-fogccc
gunzip -c /tmp/libjvm-fogccc.so.gz > libjvm.so
cp libjvm.so /run/media/USERDATA-mmcblk0p2/jvm/zulu8/jre/lib/arm/jamvm-fogccc/libjvm.so
sync
```

PC 侧推送文件用 tools/serial_push_chunked.ps1，取回板上文件用
tools/serial_pull_chunked.ps1（逐块 md5）。

### 4.2 自研负载

把 jvm-shadow/test 下的源文件推到板上并编译：

```sh
cd /tmp
/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/javac G1M.java FogcccWorkload.java
```

1M 对象、3 次 System.gc()、测 STW 与闭包（COLD + verify）：

```sh
env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
    FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
    $J -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -cp /tmp G1M 1000000
```

同一负载的原版 JVM 对照：

```sh
env FOGCCC_STW=1 $J -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m \
    -verbosegc -cp /tmp G1M 1000000
```

其余自研负载（参数为 结点数 平均出边 链化比例）：

```sh
# 可配置图，用于闭包校验
env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
    FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
    $J -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -cp /tmp FogcccWorkload 1000000 2

# 树、变更、线程、冒烟
$J -XXaltjvm=jamvm-fogccc -Xmx256m -cp /tmp FogcccTree
$J -XXaltjvm=jamvm-fogccc -Xmx256m -cp /tmp FogcccMutate
$J -XXaltjvm=jamvm-fogccc -Xmx256m -cp /tmp FogcccThreads
$J -XXaltjvm=jamvm-fogccc -Xmx256m -cp /tmp HelloWorld
```

### 4.3 DaCapo

硬件侧（COLD + verify，第一次 GC 就接管）：

```sh
env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
    FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
    $J -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m \
    -jar $D <bench> -s small --ignore-validation
```

原版 JVM 对照（同一个 libjvm，不设 FOGCCC_SHADOW/TAKEOVER）：

```sh
env FOGCCC_STW=1 $J -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -verbosegc \
    -jar $D <bench> -s small --ignore-validation
```

可运行基准：avrora、luindex、lusearch、pmd、sunflow、xalan。
日常回归（4 个基准，约 75 秒）：

```sh
sh tools/dacapo_quick.sh
```

生产路径（不 verify）：去掉 FOGCCC_TAKEOVER_VERIFY 和 FOGCCC_TAKEOVER_COLD，
第一次 GC 走影子轮，第二次起接管。用 128 MB 固定堆跑两次迭代：

```sh
env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_STW=1 \
    $J -XXaltjvm=jamvm-fogccc -Xms128m -Xmx128m \
    -jar $D luindex -s small --ignore-validation -n 2
```

### 4.4 判读

| 检查 | 命令 | 期望 |
| --- | --- | --- |
| 硬件闭包与 CPU 一致 | grep verify_extra 日志 | 0 |
| 每次 GC 的停顿 | grep 'stw:' 日志 | 逐轮微秒数 |
| 接管各阶段耗时 | grep 'takeover timing us' 日志 | export / mark / import / verify / clear |
| 端到端 | grep 'PASSED in' 日志 | 毫秒数 |

## 5. 结果

数据集：DaCapo 9.12-MR1 -s small；G1M 1000000（100 万结点，3 次
System.gc()）。命令与环境见上一节。日期 2026-11-08，tag v5.0，
libjvm.so md5 d52939ee1d82b6cb0c2ec5b3120808bb。

### 5.1 1M 负载（-Xms700m -Xmx700m）

| 指标 | 测量条件 | 硬件（ms） | 原版 JamVM（ms） | 比值 |
| --- | --- | ---: | ---: | ---: |
| 纯 mark | G1M 1000000 | 73.9 | 350 | 4.7 |
| 稳态整次 GC 停顿 | 增量轮 | 256 | 428 | 1.67 |
| 第一次重建轮 | 重建轮 | 1000 | 428 | 0.43 |

稳态 256 ms 由 mark 73.9、bitmap import 68.1、clearMarkBits 10.8、
id 回收 26.2 与 sweep/挂起恢复约 77 ms 组成。

### 5.2 6 个 DaCapo 基准（COLD + verify，-Xms700m -Xmx700m）

| 基准 | HW 端到端（ms） | SW 端到端（ms） | HW 纯 mark（ms） | SW 纯 mark（ms） | verify_extra |
| --- | ---: | ---: | ---: | ---: | ---: |
| avrora | 91,682 | 92,143 | 3.2 | 70.3 | 0 |
| luindex | 2,542 | 2,483 | 3.8 | 70.5 | 0 |
| lusearch | 16,958 | 16,798 | 2.9 | 66.8 | 0 |
| pmd | 1,618 | 1,582 | 3.3 | 68.5 | 0 |
| sunflow | 51,148 | 51,167 | 6.0 | 75.4 | 0 |
| xalan | 15,441 | 15,339 | 8.3 | 79.7 | 0 |

纯 mark 9.6–23×。6 个基准全部通过，verify_extra=0。

## 6. 边界

| 边界 | 数值 | 说明 |
| --- | --- | --- |
| id 空间 | 1,048,576 个 | 20 位。导出在 mark 之前，两次 GC 之间分配的块数必须小于该值 |
| 图区 | 64 MiB | 头 16 B/对象 + 引用区 |
| 固定堆 | -Xms = -Xmx | JamVM 堆扩容/压缩会破坏内存 |
| 冷接管 | 仅 verify | 启动期根集不完整 |
| 小图 | 数万对象 | 导入/重建/清扫的固定开销大于 CPU mark，决策门回退 CPU |
| 类对象 | 每个 Class | 导出时登记为硬件根；JamVM 不卸载类 |

## 7. 自研负载

| 负载 | 用途 |
| --- | --- |
| test/G1M.java | 1M 结点、3 次 System.gc()；测 STW |
| test/FogcccWorkload.java | 可配置结点数与平均出边；验证闭包 |
| test/FogcccTree.java | 树形图 |
| test/FogcccMutate.java | 运行中修改引用 |
| test/FogcccThreads.java | 多线程分配 |
| test/HelloWorld.java | 冒烟 |
