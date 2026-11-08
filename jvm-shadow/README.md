# jamvm-shadow — FOGCCC 的 JamVM 适配器

把 FOGCCC 的旁表与标记引擎接到 JamVM 上：对象体留在 Java 堆，引用关系导出到
FPGA 图区，标记由 PL 完成，结果按 id 位图导入 JVM 的标记位。

## 构建

需要 PetaLinux SDK（`environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi`）：

```sh
./build_jamvm_fogccc.sh
# => $HOME/jamvm-fogccc/lib/libjvm.so
```

脚本会复制一份干净的 JamVM、依次应用 `jamvm-patch/` 下的四个补丁脚本，并用
`--disable-int-inlining` 配置。安装时把 `libjvm.so` 放到
`jre/lib/aarch32/jamvm-fogccc/`，用 `-XXaltjvm=jamvm-fogccc` 启动。

## 运行

| 变量 | 作用 |
| --- | --- |
| `FOGCCC_SHADOW=1` | 打开适配器 |
| `FOGCCC_TAKEOVER=1` | 硬件标记结果接管 GC |
| `FOGCCC_TAKEOVER_COLD=1` | 第一次 GC 就接管（需 verify） |
| `FOGCCC_TAKEOVER_VERIFY=1` | CPU 闭包校验并补全 |
| `FOGCCC_TAKEOVER_DECIDE=0` | 强制硬件（关闭代价决策） |
| `FOGCCC_STW=1` | 打印 STW 停顿与 id 统计 |

固定堆 `-Xms == -Xmx` 是必需条件。

## 自研负载

`test/` 下的 `G1M.java`（100 万结点、3 次 `System.gc()`，用于 STW）与
`FogcccWorkload.java`（可配置结点数、出边与链化比例，用于闭包校验）。

完整设计、参数与实测结果见 [`../docs/jvm-adapter.md`](../docs/jvm-adapter.md)。
