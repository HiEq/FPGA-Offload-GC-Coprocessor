# FOGCCC 排错笔记

> 记录本轮 bring-up 里踩过的全部坑 + 各自的**判别方法**。
> 目的：下次遇到类似现象能 5 分钟内定位，而不是重新走一遍。
> 位置：仓库根目录（2026-10-19 起已入库；文中绝对路径已脱敏）

---

## A. 软硬件分界 / XSA（Vivado → PetaLinux）

### A1. PS7 外设使能属性名写错（最隐蔽）
- ❌ `CONFIG.PCW_EN_UART0 {1}` / `CONFIG.PCW_EN_SDIO0 {1}` —— **不是有效使能属性**
- ✅ `CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1}` / `CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1}`
- 现象：Vivado 不报错、BD 能 validate、导出 XSA 正常，但：
  - `ps7_init.c` 里 `UART0_CPU_1XCLKACT = 0`
  - `// START: UART REGISTERS` / `// FINISH: UART REGISTERS` **中间是空的**
  - 没有 `0xF8000738`(MIO14) / `0xF8000154`(UART_CLK) 的 `EMIT_MASKWRITE`
  - 后果：FSBL 无串口；U-Boot 写 UART TX FIFO 永远不排空 → 卡死；UART CSR(`0xE000002C`) 停在 `0x0A`
- **判别**：`unzip -p system.xsa ps7_init.c | grep -c 0XF8000738`，等于 0 就是没使能
- 交叉验证：`unzip -p system.xsa system.hwh | grep PCW_UART0_PERIPHERAL_ENABLE`

### A2. `gc_top` 地址映射查询对象错
- ❌ `get_bd_addr_segs -of_objects [get_bd_intf_pins axi_lite_ic/M00_AXI]` → 空
- ✅ 段在 PS7 地址空间里：`/ps7_0/Data/SEG_gc_top_0_reg0`
  做法：遍历所有段，按 PATH 匹配 `*/ps7_0/Data*` + `*gc_top*`
- 现象：不报错，但地址被 auto-assign 成 `0x40000000`（不是想要的 `0x43C00000`）
- **判别**：`build.tcl` 里 "Address Segments" 打印 / 或者看 WARNING: gc_top address segment not found

### A3. ⚠️ `images/linux/system.bit` 是**一次性解压**的（本轮最坑）
- 它**只在 `petalinux-config --get-hw-description` 时**从 XSA 里解出来
- 之后**换多少次 XSA、跑多少次 `petalinux-build` 都不会更新它**
- 现象：改了 RTL、重建了 Vivado、重建了 PetaLinux，**板子行为完全不变，且没有任何报错**
- **判别**：`md5sum images/linux/system.bit` vs Vivado 的 `impl_1/system_wrapper.bit`
- 修法：
  ```bash
  unzip -o project-spec/hw-description/system.xsa system.bit -d /tmp/x
  cp /tmp/x/system.bit project-spec/hw-description/system.bit
  cp /tmp/x/system.bit images/linux/system.bit
  petalinux-package boot --fsbl images/linux/zynq_fsbl.elf \
                         --fpga images/linux/system.bit --u-boot --force
  ```

### A4. `system-user.dtsi` 必须以 `/include/ "system-conf.dtsi"` 开头
- 这行把 PetaLinux 生成的配置（`chosen/bootargs`、`memory`、`aliases`）合并进来
- 删掉它 → 新 `system.dtb` 的 `chosen/bootargs` 只剩 `earlycon`，**`console=ttyPS0,115200` 静默丢失** → Linux 没串口控制台
- 同时也别丢 `&uart0 { clock-frequency = <100000000>; status = "okay"; }`
- **判别**：`strings images/linux/system.dtb | grep "console="` 没有输出就是丢了

### A5. `mem=480M` 会饿死 initramfs
- 内核 Image 本身 101MB + initramfs 解压后 ~244MB + CMA 16MB → 480MB 不够
- 现象：`4096 pages cma reserved` 之后 `Kernel panic - not syncing: write error`
- 给 PL 预留内存要用**设备树 `reserved-memory`**，不要用 `mem=`
- **判别**：`cat /proc/cmdline` 里有没有 `mem=`；`free -m` 的 total

### A6. U-Boot `CONFIG_SYS_BOOTM_LEN` 默认太小
- Xilinx 默认 `0x3c00000`(60MiB)；initramfs 链进内核后 image.ub 的 kernel 子镜像 ~**101MiB**
- 现象：`Image too large: increase CONFIG_SYS_BOOTM_LEN`（bootm 阶段）
- 修：`bsp.cfg` 里 `CONFIG_SYS_BOOTM_LEN=0x10000000`
- **判别**：`grep -i bootm_len build/tmp/work/.../u-boot-xlnx/*/temp/log.do_configure`
  会打印 `Value of CONFIG_SYS_BOOTM_LEN is redefined ...`

### A7. TF 卡必须有 `boot.scr`
- 只有 `BOOT.BIN` + `image.ub` → U-Boot distro boot 扫完找不到脚本 → 停在 `Zynq>`
- `boot.scr` 的 mmc0 分支负责 `fatload mmc 0 0x10000000 image.ub; bootm 0x10000000`

### A8. `boot.scr` 会自动 import `uEnv.txt`
- 有它就能在**不重建镜像**的前提下覆盖内核 cmdline：
  `bootargs=console=ttyPS0,115200 earlycon`
- 优先级高于设备树 `chosen/bootargs`

---

## B. RTL / 驱动 / 测试

### B1. AXI HP 是 64 位 → 32 位读必须对齐 + 选半字
```verilog
ARADDR <= {addr[31:3], 3'b000};      // 8 字节对齐
hi_sel <= addr[2];
rdata  <= hi_sel ? RDATA[63:32] : RDATA[31:0];
```
- 不这么做的后果：读对象头 `+4`(ref_count) 拿回 `+0`(obj_id)；对象 0 的 id=0 → ref_count 读成 0 → **引擎立刻结束，只标记根**
- 现象：软件 BFS 2903、硬件只标记 **1**，且 HW cycles ≈ 4128（正好 4096 清位图 + 一点点）

### B2. 对象图布局重叠
- 头区 = `n*16` 字节；引用数组必须排在**所有头之后**
- 硬编码 `REF_BASE = 0x1000` 在 n>256 时**覆盖对象头** → 软件 BFS 报 `struct.error: offset ... out of range`
- 修：`REF_BASE = align_up(n*16, 0x1000)`

### B3. 完成检测不能用 DONE 轮询（会造成假 OK）
- 引擎跑完只要 ~40µs，而 Python 轮询要 100µs+ → 第一次读就已经是 `done=1`
- **无法区分"跑完"和"没跑"** → 会读到上一轮的旧 `MARKED/CYCLES` → 假 OK
- ✅ 用 `CYCLES` 寄存器**发生变化**判定（只有 `S_DONE` 会锁存它）

### B4. BFS 队列 `Q_MAX=4000` 溢出会静默漏标
- `S_PUSH` 里位图照样置位，但 `if (q_tail < Q_MAX)` 不成立就不入队 → 该对象的引用永不展开 → **经它可达的对象全漏**，`MARKED` 也偏小
- 现象：前沿宽度 > 4000 时 HW < SW

### B5. 测试判定必须对"已知真值"
- 活对象区建成**从 0 出发的生成树** → 全部可达 → 期望值 L 事先已知
- 硬件、软件**各自**对比 L（不只是互相对比，否则一起错就骗过）
- 垃圾区只在自己内部连边 → 期望 0
- 再叠 `marked>0` / 真跑过 / `cycles>=4096` 三道下限

---

## C. 板子登录 / 串口交互

### C1. root 是锁定的
- `/etc/shadow`: `root:*:...`（`*` = 锁定）；`CONFIG_ADD_EXTRA_USERS="root:root"` **没有真正设上密码**
- 用 `petalinux` + **空密码**登录（首次强制改密）→ `sudo -i`
- 或开 `CONFIG_imagefeature-empty-root-password=y`（推荐，root 空密码直接登）

### C2. 登录失败有 3 秒延迟，会"排队"
- `/etc/login.defs`: `FAIL_DELAY 3`
- 往 `login:` 提示符灌命令（比如 base64 那 96 行）→ 每次尝试等 3 秒 → 卡几分钟
- **现象**：按回车"没反应"，其实是在排队
- 只能**断电重启**恢复；别继续按键

### C3. 往 U-Boot 提示符发任何字节都会打断 autoboot
- 哪怕是一个空回车 `\n`（比如脚本"戳一下看有没有提示符"的逻辑）
- 现象：`Hit any key to stop autoboot: 0` 然后一串 `Zynq>`
- **结论**：控制台在**看到 `login:` 之前绝不能向串口发任何字节**

### C4. CH340 由板子供电 → 端口号在板子上电前不存在
- 脚本必须先**等待端口出现**（重试），并支持自动识别 CH340（COM 号可能变）
- `[System.IO.Ports.SerialPort]::GetPortNames()` 为空就是没插/没上电

### C5. exFAT 用不了
- 内核 `# CONFIG_EXFAT_FS is not set`；`CONFIG_VFAT_FS=y`、`CONFIG_EXT4_FS=y`
- 只能用 FAT32；Windows GUI 不能建 >32GB 的 FAT32 → 用板子 `mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2`

---

## D. 工具/环境（会浪费很多时间的）

### D1. WSL 里 `wsl -c "..."` 的引号转义极易坏
- 现象：`unexpected EOF while looking for matching`、`fatal: Invalid path '/include'`（git 消息里的 `/include/` 被当路径）
- **规矩**：一律**写 `.sh` 文件**再 `wsl bash /mnt/c/.../x.sh` 执行；git 提交消息用 `-F <file>`

### D2. PowerShell 5.1 读无 BOM 的 UTF-8 `.ps1` 按 GBK 解析
- **中文注释会吞掉后面的括号** → `MissingEndParenthesisInFunctionParameterList`
- **规矩**：`.ps1` 一律用**纯英文注释**；中文只放 `.md` / 输出文本

### D3. Windows PowerShell 里 `$` 会被外层先展开
- 内联 `powershell -Command "$x=[char]27; ..."` 这种会把 `$x` 吃掉 →
  改成**写 .ps1 文件**再跑

### D4. 控制台渲染的坑（自己写 TUI 时）
- `[Console]::SetCursorPosition(0,0)` 是**缓冲区顶部**，不是窗口顶部 → 用 `[Console]::WindowTop`
- 光标列不能用**填充后**的行宽（`PadRight($W)` 后长度恒为 W）→ 单独记未填充长度
- 未完成的行（无换行的当前行）要放 I/O 区**最下面**（放最上面会出现 `root@` / `root@f` 逐行堆叠）
- 行缓冲要按**终端语义**：`\r` 是"列号归零后覆盖写"，不是换行
- 只在"内容变了"才重绘（差分），能大幅减少闪烁

### D5. GitHub 单文件 >100MB 会被拒
- `image.ub` 106MB → 必须 `.gitignore`，让它由 PetaLinux 重新生成

### D6. JTAG 工具（XSDB/Vivado）必须在 Windows 跑
- WSL2 访问不到 USB JTAG

### D7. `find $VAR ...` 变量为空时会扫当前目录
- 曾把 `u-boot-xlnx-scr` 误当成 `u-boot-xlnx` → 用**绝对路径**或先判空

### D8. `cpio -i` 的"模式列表"和"归档数据"都从 stdin 读
- 必须 `cpio -i -F <archive> pattern...`，否则 `-i pattern` 什么也解不出来

---

## E. 快速自检清单（怀疑某层坏了时按这个顺序查）

```
1. 板子有没有电 / COM 口存不存在           GetPortNames()
2. FSBL 有没有跑（DONE LED / PC 在 OCM）   XSDB
3. ps7_init 对不对（UART 时钟/MIO）        grep XSA 的 ps7_init.c
4. U-Boot 起来没 / 卡在哪                  UART 输出 + PC
5. BOOT.BIN 位流是不是最新                 md5 vs Vivado impl_1
6. DT cmdline 对不对                       strings system.dtb | grep console=
7. 内存够不够                              free -m / /proc/cmdline 里别带 mem=
8. 能登进去没                              用 petalinux+空密码 或 empty-root-password
9. 寄存器通不通                            python3 读 0x43C00000
10.DDR 通不通                              python3 写读 0x1E000000
11.引擎真跑了没                            CYCLES 变了没（不是看 DONE）
12.结果对不对                              和已知真值 L 比 + 垃圾区 0
```

---

## F. ⚠️ 本轮优化（多笔未完成读 + 预取）自己引入的新坑 —— 专防复发

> 这一节记的是 **2026-10-16 优化轮里我自己改出来的 bug**，以及它们的判别特征。
> 共同教训：**RTL 改动必须先跑仿真**（`sim\run_sim.bat`）—— 上面 F1~F6 里有 4 个是仿真抓出来的，
> 上板才发现的代价就是一轮 15 分钟重编 + 一次插卡。

### F1. 位图单口 BRAM：读和写共用地址 → 写落到别人的字上（最致命）
- **现象**：去重**完全失效** —— `q_tail` 打满 4000、`marked=0`、整体不移标
- **根因**：`gc_bitmap` 只有**一个** `addra` 供读和写。快路径想"这拍读、下拍写"，但写脉冲是**寄存器**（下拍才有效），而那一拍地址已经被新取回的引用覆盖了 → 写进了别人的格子
- **判别**：看到"队列打满 + marked 为 0"这个组合，几乎必是它（不是少标，是全丢）
- **修法**：`gc_bitmap` 改成**读/写地址独立的简单双口 BRAM**（`waddr/we/din` + `raddr/dout`）

### F2. 位图读地址写成寄存器 → BRAM 采到旧地址
- **现象**：去重失效 / 结果错
- **根因**：`bm_raddr <= rd_data[11:0]`（非阻塞）要**下一拍**才生效，BRAM 在那一拍边沿采样到的是**旧地址** → `bm_rdata` 是别格的数据
- **修法**：读地址必须**组合**输出：`assign bm_raddr = (state==S_REFS_LOOP) ? rd_data[11:0] : 0;`
- **判别**：在 `S_REF_DEC` 那一拍，`bm_rdata` 是否等于 `mem[刚取回的那个 ref]`

### F3. FIFO 数组深度 ≠ 2^指针宽度 → 指针回绕后越界
- **现象**：仿真里读出 `X`（板上就是垃圾数据），引擎状态错乱直到卡死
- **根因**：`reg [32:0] cfifo [0:QD-1]`（32 深）却用 **6 位**回绕指针索引 → 指针一过 31 就访问到数组外
- **修法**：存储体必须声明成 `[0:(1<<PW)-1]`；容量用**另一个参数**判"满"
- **判别**：指针值超过数组深度之后，数据全变 X

### F4. 命令压入手握：握手成功后没撤销 `valid` → 同一笔被收两次
- **现象**：同一笔读命令**重复压入**（去重/计数都会错）
- **根因**：`valid` 在 `PUSHW` 里保持到下一拍，而 `addr` 要到**再下一拍**才更新 → 中间那拍主控又接收了一次
- **修法**：握手成功后**立刻** `valid <= 1'b0`

### F5. `REF_MAX` 静默截断（旧设计就有的隐患，本轮才修掉）
- **现象**：`ref_count > 64` 的对象**静默漏标**一部分引用，**不报任何错**
- **修法**：引用阶段改成**压入/取回交错**（命令队列满了就先取回已返回的数据）→ 上限本身就不需要了
- **回归保护**：测试台里**固定放一个 `rc=200` 的对象**，旧写法必挂

### F6. `w_rd_err` 使用在声明之前
- **现象**：`ERROR: [VRFC 10-3380] identifier 'w_rd_err' is used before its declaration`
- **根因**：消警告的 `_unused` 那一行放在 `wire w_rd_err;` **之前**
- **修法**：先声明，后 `_unused`

### F7. 监控台日志名 `com5.log` —— Windows 保留设备名
- **现象**：日志文件**永远不存在**；严重时 `StreamWriter` 抛异常，控制台"打完横幅就没反应了"
- **根因**：`COM5` 是保留设备名。串口开着时 `com5.log` 这个名字被解析到设备上，普通 API 建不出文件（实测 `New-Item ...\com5.log` → "正被另一个进程使用"）
- **补充实测**：这个文件**会出现在目录列表里**（`Get-ChildItem` 能看到 125KB），但 `Get-Content` / `Test-Path` 却说"路径不存在" —— 保留名解析时好时坏，所以它既不可靠也读不出来
- **修法**：改名 **`serial.log`** + 用 try/catch 包住 → 打不开就**只禁用落盘，绝不影响运行**

### F8. 监控台键盘门控的**死锁场景**
- **现象**：板子**早就启动好了**，重启监控台后**永远敲不进字**（横幅之后什么都不动）
- **根因**：监控台只显示**新收到**的数据，不重放历史。板子已启动 → 没有新输出 → "看到 `login:` 才解锁"这个条件**永远不成立** → 阶段停在 `raw` → 按键全被门控
- **修法**：加**串口静默 10 秒自动解锁**（U-Boot 自动启动窗口只有 ~3 秒，静默 10 秒绝不可能还在窗口内，不会误伤）+ 横幅写明
- **注意**：这**不是**板子/端口的问题，别去查硬件

### F9. 仪表盘每帧重绘在 Windows 控制台上很慢（"打字卡/粘贴不回显"的根因）
- **根因**：每帧对**每条变化的行**做 `SetCursorPosition` + `Out.Write`（一次 10~30 次 API 调用）；而"有数据就重绘"这个优化会让**打字时更频繁**触发，反而更卡
- **修法**：加 **`-Plain` 纯透传模式**（不画仪表盘，串口原样滚动，打字跟普通终端一样跟手）
- 另外三条：按键**一次循环攒成一个字符串**再写（别逐字符 `Write`）、**去掉每帧复制整份 3000 行历史**、日志**按秒刷盘**（`AutoFlush=$false`）

### F10. ⚠️ **绝对不要用 PowerShell 文本替换去改源码**
- **现象**：`gc_top.v` 里注释和代码被**并到同一行** → `syntax error near ','` / `redeclaration of ANSI port`
- **根因**：`Get-Content -Raw` + `Set-Content -NoNewline` 会动行尾
- **修法**：改 `.v` / `.ps1` **一律用 edit 工具**；PowerShell 只用来**比对、拷贝、跑命令**

### F11. `petalinux-build | tee` 会吞掉退出码
- **现象**：构建**失败**了脚本却继续往下打包 `BOOT.BIN`（拿旧的 image.ub），产出"**新位流 + 旧内核**"的不一致镜像
- **修法**：脚本开头 `set -o pipefail`

### F12. 复制 PetaLinux 工程 → Yocto 拒绝构建
- **现象**：`Error, TMPDIR has changed location`
- **根因**：`cp -a` 把**旧路径的 `build/tmp`** 一起带过去了
- **修法**：`rm -rf build/tmp` 再 build（sstate 缓存仍在，不会真从零编）

### F13. 交叉编译（cmark）的正确姿势
- **现象**：① `stdio.h: No such file or directory`；② `invalid -march= option: 'armv7-a+simd'`
- **根因**：① `sysroots-components/` 是**按 recipe 拆散**的，合并好的 `recipe-sysroot` 已被 `do_rm_work` 删掉；② gcc 13 会发新的 `+simd/+fp` 汇编语法，系统里的老 `as` 不认
- **修法**：用构建树里**存活的一对** `recipe-sysroot` + `recipe-sysroot-native`（后者带**配套的** gcc/as），并用 `COMPILER_PATH` 指过去。见 `csrc/build_c_bins.sh`（SDK 版）

### F14. `/tmp` 会被 WSL 重启清空
- **现象**：上一轮建好的 sysroot，下一轮不见了
- **修法**：中间产物放 `$HOME` 下（如 `~/fogccc2-sysroot`）

### F15. ⚠️ 用"整行替换成多行块"时**漏掉删除原行** → 代码重复 + 括号失衡
- **现象**：`Parser::ParseFile` 报 `Try 语句缺少 Catch 或 Finally 块`；token 计数 `RCurly` 比 `LCurly` 多（**注意**：原版就多 1，因为有空哈希表 `@{}`，`@{` 算另一个 token）
- **根因**：把 `if (A) { X }` 换成多行块时，oldString **没覆盖整行**，旧行留在原处 → 重复代码
- **判别**：`git diff --no-index 原版 新版`，看有没有"只有 `+` 没有 `-`"的块
- **修法**：**优先最小内联改动**（只改 `if` 条件，别整行换块）；改完**立刻**跑 `[Parser]::ParseFile` 验
- ⚠️ 报错位置是**解析器放弃的点**，不是根因所在行，别顺着它查

### F16. ⚠️ **不要**去关 Windows 控制台的 QuickEdit（会用不了鼠标选择/复制）
- **曾以为**：QuickEdit 模式下鼠标点一下会进入"选择"模式让控制台看起来卡住
- **实测后果（必须避免）**：一旦用 `SetConsoleMode(... -band (-bnot 0x0040))` 把 QuickEdit 关掉，
  **鼠标拖选和右键复制全部失效** —— 对这个项目是致命倒退（每次都要复制输出）
- **正确做法**：QuickEdit **保持默认开启**。看起来"卡住"时按一下 `Esc`/`Enter` 就退出选择模式、立即恢复
- **输出延迟**是另一回事，用 **F18 的显式 `Flush()`** 解决，不要动 QuickEdit

### F17. `.ps1` 里的中文**字符串字面量**在 PowerShell 5.1 下变 GBK 乱码
- **现象**：屏幕上出现 `涓插彛闈欓粯 10 绉?-> ...`（UTF-8 字节被当 GBK 显示）
- **根因**：脚本是 UTF-8 无 BOM，PS 5.1 按系统 ANSI(GBK) 读 → **中文注释没事，中文字符串会烂**
- **修法**：**脚本里的所有字符串一律用 ASCII**（见 D2）；要中文就写进 `.bat` 里别写在 `.ps1` 字符串里

### F18. ⚠️ `[Console]::Out.Write` 在这个 PowerShell 宿主里**屏幕上什么都不显示**
- **现象**：监控台日志（`serial.log`）里数据**完整正常**，但**屏幕上一直空白**（只有 `Write-Host` 打的横幅看得见）
- **根因**：PowerShell 宿主把 `Console.Out` 重定向到了它自己的 writer，**`[Console]::Out.Write` 不落到控制台画面**。
  `Write-Host` 走宿主的 UI 通道 → **正常显示**。（加 `Flush()` 也救不了，因为根本不是缓冲问题。）
- **修法**：串口输出**一律用 `Write-Host $chunk -NoNewline`**（原版就是这么写的，别乱"优化"成 `[Console]::Out.Write`）
- **判别**：`serial.log` 在长大、屏幕却没字 = 就是这个
- **附带**：`Write-Host` 比 `[Console]::Out.Write` 慢，但**能显示才是第一位**；性能问题靠"不画仪表盘"解决，不是靠换输出 API

### F19. ⚠️ **中文输入法**会让串口控制台"完全打不进字"
- **现象**：控制台对键盘**毫无反应**；切到英文输入法**立刻恢复**；表现为"时好时坏"
- **根因**：输入法激活时，字母先进入**组字/候选窗口**，而监控台是用 `[Console]::ReadKey` 直接读控制台输入的 → **根本收不到任何按键**
- **修法**：打字前把输入法切到 **EN (US)**（横幅里已加提示）。这不是代码能修的
- **判别（和 F8 区分）**：
  - **F8（门控）**：会打印 `[monitor] no serial data for 10s -> keyboard unlocked`
  - **F19（输入法）**：**什么提示都没有**，就是没反应，换英文就好

### F20. `.bat` 里的中文注释会乱码
- **现象**：启动 `fogccc.bat` 时那几行 `rem` 注释显示成乱码
- **根因**：cmd 按 **OEM 代码页(GBK)** 解析批处理文件本身，UTF-8 的中文注释就烂了。
  `chcp 65001` 只影响子进程的输出，**救不了文件内容的中文**
- **修法**：**`.bat` 里的注释也用 ASCII**（与 F17 对 `.ps1` 字符串同一条原则）

### F21. ⚠️ 注释和代码被并到**同一行** → 变量静默为 `$null`（本轮键盘打不进字的真因）
- **现象**：控制台完全打不进字（粘贴也不行）；屏幕打印
  `[monitor] KEYBOARD READ FAILED ... 不能对 Null 值表达式调用方法`
- **根因**：某次编辑把 `# 注释...` 和 `$kb = New-Object System.Text.StringBuilder` 并到了**同一行**
  → 赋值成了注释的一部分 → `$kb` 永远 `$null` → 后面 `$kb.Append()` 抛异常
- **为什么一直没发现（三个坑叠在一起）**：
  1. 语法**完全合法** —— `Parser::ParseFile` 报 0 错，**语法检查查不出来**
  2. 原来的 `} catch {}` 是**空的**，异常被无声吞掉
  3. 收数据/写日志和键盘是**两条独立路径**，前者正常把后者掩盖了
- **判别**（一行里既有注释、后面又跟代码）：
  ```powershell
  Select-String -Path monitor.ps1 -Pattern '#.*(\$\w+\s*=|\bif\s*\(|\bwhile\s*\(|\bforeach\s*\(|\btry\s*\{)'
  ```
- **修法**：拆回独立行；**永远不要用"整段文本替换"改脚本**（配合 F15）。
  catch 里**至少打印一次** `$_.Exception.Message`，别再留空 catch。

### F22. ⚠️ 基准测试把"一次性开销"算进计时区 → 结论会**反向**
- **现象**：`cmark` 报 `HW vs C-cached = 1.0x`（硬件打平）；把 memcpy 移出计时区后变成 **0.4x**
  （硬件其实慢 2.7 倍）—— 相差 2.5 倍，足以把结论说反
- **根因**：`c_mark_cached()` 里的 `memcpy(cbuf, gbase, used)` + 修指针循环被 `now_ms()` 前后差
  **一起计入了**。可真实进程内 GC 里那份数据本来就在堆上，根本不存在"拷贝"这一步（硬件也没有）
- **后果**：C 侧虚高 → **得出对自己有利、对对手不利的错误结论**
- **教训**：基准里**只有被测算法本身**进计时区；**准备数据 / 分配 / 拷贝 / 预热 全部放外面**；
  两组对比的"工作量"必须等价。这条对性能结论的可信度是致命的。
- **附带**：串口传源码时 **base64 + md5 校验** 才可靠（直传 UTF-8 源码会掉字节 8%，见 F23）

### F23. 经串口"直传源码文本"会掉字节，必须 base64 + 校验
- **现象**：`cat > file << 'EOF'` 传 11337 字节，板上 `wc -c` 只有 **10415**（丢 922 字节）
- **根因**：分块太密时板子的行编辑器吞字节；且 UTF-8 中文注释可能在分块边界被切断
- **修法**：**base64**（纯 ASCII，免疫多字节切断）+ 传完 **md5 校验**，不一致就重传。
  见 `tools/push_cmark2.ps1`

### F24. ⚠️ PowerShell 管道会**损坏二进制数据**（`git archive | tar` 直接报坏档）
- **现象**：`git archive b231a43 rtl | tar -x -C dir` → `tar: Damaged tar archive (bad header checksum)`
  刷屏上百行，**什么都没解出来**（而 git 命令本身返回 0，看起来像"跑了"）
- **根因**：PowerShell 管道把原生命令的输出当**文本/对象**传递并重新编码，二进制流被改坏
- **修法**：**先写文件再处理** —— `git archive -o x.tar <ref> <paths>` 然后 `tar -xf x.tar -C dir`
- **同类风险**：任何 `cmd1 | cmd2` 传二进制（图片 / 压缩包 / bitstream / 固件）都要走文件中转

### F25. ⚠️ 用 GitHub API 建 release：正文可能**悄悄丢字符**，建完必须回读复核
- **现象**：`POST /repos/.../releases` 返回 **201**，但 release 正文只存下 448 字符
  （源文件 1248 字符）—— **头尾都对、中间成片丢失**，肉眼看 release 页面不容易发现
- **根因**：未完全定位。怀疑是 `ConvertTo-Json` + `curl --data-binary @file` 这条链上
  JSON 转义/写文件的某一步；**同一条链另一次完全相同做法却是好的** → 属间歇性问题
- **修法**：**建完立刻 `GET /releases/tags/<tag>` 回读，与源文件比字符数和内容**；
  不一致就用 `PATCH /releases/<id>` 把正文重写一遍（本次就是这样修好的）
- **教训**：所有"写远端就不管了"的动作都要**回读比对**，别信 2xx；
  release 正文里带中文时尤其要查

### F26. 私有仓库的 Release 附件**不能**用 `/releases/download/...` 下
- **现象**：`curl https://github.com/HiEq/FPGA-Offload-GC-Coprocessor/releases/download/v1-original/BOOT.BIN` → **HTTP 404**（当时仓库是私有的）；
  但 `GET /repos/.../releases` 里附件明明在、大小也对
- **根因**：那是**网页登录态**的下载路径，私有仓库拿 `Authorization: Bearer <token>` 访问它一律 404
- **修法**：走 API 资产端点 —— `GET https://api.github.com/repos/<owner>/<repo>/releases/assets/<asset_id>`
  + `-H 'Accept: application/octet-stream'`；只想验证存在性就加 `-H 'Range: bytes=0-63'`（返回 206，只取 64 字节）
- **注意**：这个 404 **不代表附件坏了**，别据此判断上传失败（判断上传成功要看 POST 返回的 201）

### F27. ⚠️ 往 release 写正文：同一条链两次结果不同（间歇性丢字符）
- 与 F25 同源。本次"只留 MD5 + 说明"重写后**一次就对了**，说明问题不在写法而**在链路的不确定性**
- **结论**：正文写完**每次都回读比对字符数**，`remote == local` 才算过；不一致就 PATCH 重写
- **附带**：用来**核对**的 `.ps1` 里如果写中文**字面量**（如 `'## 说明'`）会因 F17 变乱码而**永远匹配不上**
  → 别用中文字面量做断言，直接用 `[System.IO.File]::ReadAllText(...,UTF8)` 与远端正文整串比

### F28. ⚠️ 验证结论一律以**落盘文件**为准，别信控制台渲染
- **现象**：`run_gc.sh` 的串口输出在控制台显示时，**部分行把所有 `e` 都丢了** ——
  `userdata`→`usrdata`、`PASSED`→`PASSD`、`gc_test.py`→`gc_tst.py`、32 位 md5 只剩 28 位，
  看起来像"串口在丢字节"，会让人误判链路有问题
- **实际**：用 `[System.IO.File]::ReadAllText()` 读同一份日志 → `userdata` / `PASSED` /
  完整 md5 **全都在**，串口链路完全正常，只是**控制台渲染**丢了字符
- **教训**：凡是"验证通过/失败"的判断，**一律以落盘文件为准**（`grep` / `ReadAllText`），
  控制台看到的只当参考
- **做法**：串口驱动脚本一律把 transcript **先写文件再解析**（本次 `board_verify_*.log`、
  `cmark_verify_*.log`、`cmark_sweep_verify_*.log` 都是这么做的）

### F29. ⚠️ 同一个 Vivado 工程目录**不能同时跑两个构建**
- **现象**：第二个构建启动即失败
  `ERROR: [Project 1-161] Failed to remove the directory '...fogccc_z7100.runs'. The directory might be in use by some other process.`
  同时第一个构建报"**实现失败**"
- **根因**：`create_project -force` 会删 `*.runs`，而前一个构建正占着它 → 两个互相破坏
- **修法**：**同一工程同一时间只允许一个构建**；重跑前先确认 `Get-Process vivado` 为空，
  必要时整个删掉 `fogccc_proj`（可从 `build.tcl` 重新生成）
- **教训**：后台构建必须**等到完成通知**再启动下一个，别看日志"好像跑完了"就抢跑

---

### F31. PetaLinux 复制工程的 `SDKBASEMETAPATH` 仍指向旧工程
- **现象**：`fogccc2_linux` 的构建日志里全是 `~/xilinx/fogccc_linux/...` 路径
- **根因**：`build/conf/bblayers.conf` 里 `SDKBASEMETAPATH` 是**绝对路径**，复制工程时被一起复制；
  `petalinux-config --get-hw-description` 只更新硬件相关部分，**不会**重写层路径
- **影响**：产物仍写进新工程（`TMPDIR=${TOPDIR}/tmp`、`meta-user`/`workspace` 指向新工程）→
  内容正确；但**依赖旧工程目录一直存在**，且改旧工程的层会静默影响新工程
- **修法（已验证，零重编）**：把旧目录做成指向新工程的**软链接** ——
  `mv ~/xilinx/fogccc_linux ~/xilinx/fogccc_linux.OLD && ln -s fogccc2_linux ~/xilinx/fogccc_linux`。
  路径字符串不变 → Yocto 签名不变（实测 `petalinux-build -c ...` 报 5887 任务全部无需重跑）。
  确认无误后再删 `OLD`（本机释放 38 GB）。
- **正确的做法（2026-10-17 实测通过）**：**不要**手工改 `build/conf` ✗ —— 一旦改了，
  `petalinux-build` 会认为配置过期 → 去调 `gen-machineconf` ✗，而**本机安装里没有这个工具** ✗ →
  `[ERROR] Command gen-machineconf ... failed`，构建在动任何东西之前就退出 ✗。
  正确路径是：**把工程配置入库** ✓（`petalinux/project-spec/`：`configs/config`、
  `configs/rootfs_config`、`meta-user/`）+ **删掉旧工程** ✓ + 让 `build_fogccc2.sh`
  首次运行**自动 bootstrap** ✓。实测：全新工程 → `petalinux-create` → 骨架套用 →
  六项配置校验 → 全量构建 **6438 任务 rc=0** ✓，**全程不需要 `gen-machineconf`** ✓
  （只要 `config`/`rootfs_config` 先就位 ✓，`petalinux-config --silentconfig` 不会重新生成）。
- **教训**：想"清理工程依赖"时，先确认**配置本身是否可重建** ✗ —— 把配置入库比修路径更重要 ✓。
- **还有 3 处也指向旧工程**（删旧目录前必须确认都能解析，否则构建崩）：
  - `build/conf/plnxtool.conf`: `UNINATIVE_URL`、`PETALINUX_PRODUCT:pn-base-files-plnx`
  - `build/conf/machine/zynq-generic-7z100.conf`: `HDF_URI`（**硬件描述从这里取！**）
  - 软链接方案会一并解决这三处
- **自查**：
  `grep -rn 'xilinx/fogccc_linux' $PROJ/build/conf` 应为空或全部可解析

### F32. 嵌套 `powershell -File` 会吃掉引号（也会提前展开 `$?` / `$HOME`）
- **现象**：`-Cmd 'grep -E "total HW cycles" file'` 传到子进程后引号消失 →
  `找不到与参数名称"HW"匹配的实际参数`；`$?` 被外层 PowerShell 展开成 True/False
- **根因**：外层 PowerShell 解析完再拼命令行交给 `powershell.exe`，内层引号与变量在此过程中丢失/展开
- **修法**：把要发送的串口命令**写进文件**，脚本用 `ReadAllText` 读出来再发送；
  或者干脆不嵌套，直接在脚本内部拼命令

### F33. TF 卡分区在板上自动挂载到 `/run/media/<LABEL>-mmcblk0pN`
- **现象**：板上 `cat /mnt/data/run_gc.sh` → `No such file or directory`
- **根因**：PetaLinux 2026.1 的 udev 自动挂载到 `/run/media`，旧的 `mount_data.sh`（挂到 `/mnt/data`）不再需要
- **修法**：`ls /run/media` 定位；卡上的脚本都用 `DIR=$(dirname "$0")`，
  直接 `sh /run/media/USERDATA-mmcblk0p2/run_gc.sh` 即可

### F34. PowerShell 5.1 的 `Invoke-RestMethod -Body <字符串>` 会把非 ASCII 变成 `?`
- **现象**：用 PowerShell 调 GitHub API 更新 release notes 后，页面上**所有中文都变成问号**
  （实测 310 个 `?`），但本地源文件是好好的
- **根因**：`-Body` 传 `[string]` 时，PS 5.1 用 ISO-8859-1/ASCII 编码请求体，中文字符全部落成 `0x3F`
- **修法**：显式编码成 UTF-8 字节再传：
  ```powershell
  $json  = @{ body = $body } | ConvertTo-Json -Depth 3
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Invoke-RestMethod -Uri $url -Method Patch -Body $bytes -ContentType 'application/json; charset=utf-8'
  ```
- **诊断**：读完 body 后统计 `U+FFFD`(EF BF BD) 与 `?`(0x3F) 的字节出现次数，并用
  `New-Object System.Text.UTF8Encoding($false,$true)` 做严格 UTF-8 校验（会抛异常才算无效）
- **注意**：终端/`Get-Content` 的显示也可能把正常中文显示成问号 —— **先查字节再下结论**

## G. 改动后回归自检清单（每次都跑，别省）

```
1. 仿真必须先过        sim\run_sim.bat  → PASS(250/250, 孤岛 0)
   测试台里必须含: ref_count=0 对象 / rc=200 高引用对象 / 不可达孤岛
2. 动过位图？          重点查 F1/F2（去重失效 = q_tail 打满 + marked 0）
3. 动过 FIFO 指针？    重点查 F3（数组深度必须是 2^指针宽度）
4. 动过压入握手？      重点查 F4（握手后立刻撤销 valid）
5. 动过引用上限？      重点查 F5（别再有静默截断）
6. 改 .v/.ps1          只用 edit 工具，不用 PowerShell 文本替换（F10）
7. 构建脚本            `set -o pipefail`（F11）；PetaLinux 复制后 `rm -rf build/tmp`（F12）
8. 打包前              BOOT.BIN 的 md5 与 Vivado `impl_1/system_wrapper.bit` 对得上
9. 监控台              永远别用 `com5.log` 这个名字（F7）；被门控卡住先等 10 秒（F8）
                       改完 .ps1 **一定**跑 `[Parser]::ParseFile` 验语法（F15）
                       字符串只用 ASCII（F17）；别用"整行换多行块"（F15）
10.结果解读            严格判据 8/8 + 每对象周期数，两者都要看
```
