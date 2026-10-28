# 上板 bring-up 踩坑清单

格式：现象 → 判别方法 → 根因 → 处理。全部来自 Zynq-7000 + PetaLinux 2026.1 + 串口控制台
的实际调试，换板卡时先按“判别方法”确认是否同一问题，再套用处理。

## 1. 串口登录时出现 `[8;24;80t` 或 `sh: [8: command not found`

- **判别**：在登录 shell 的 profile 里存在 `resize` 调用（Yocto 的 `/etc/profile` 默认有）。
- **根因**：`resize` 发送 `CSI 18 t` 后等待时间过短，串口回包晚到，被 shell 当成键盘输入。
- **处理**：串口 tty 上禁用该调用，改由登录脚本统一探测一次尺寸并 `stty`；确保全系统只有
  **一个** 进程发 `CSI 18 t`（两个调用者会互相读走对方的回包）。

## 2. 顶栏/全屏程序只占 80 列

- **判别**：`stty -F /dev/ttyPS0 size` 与实际窗口不符。
- **根因**：串口没有窗口协商，内核保持上一次的 winsize。
- **处理**：登录时向终端问一次尺寸（`CSI 18 t`）并 `stty rows/cols`；tmux/byobu 在启动前读取。

## 3. 程序退出后画面残留、光标乱跳

- **判别**：`TERM=screen`/`vt100` 下运行 busybox 的 `vi`/`less`。
- **根因**：busybox 的 `vi` 没有备用屏（smcup/rmcup），整屏重绘在慢速串口上必然撕裂。
- **处理**：换 `vim-tiny` 或正式 `vim`；或在程序退出后显式 `ESC[H ESC[2J` 清屏。

## 4. 串口日志里出现 `[>0;10;1c`

- **判别**：这是 DA2 查询（`CSI > c`）的应答；只在 VT100-like 终端（如 tmux）上出现。
- **根因**：tmux 启动时查询终端能力，应答晚到后被投递进 pane。
- **处理**：把该查询改成终端会忽略的序列（本项目改为 `CSI > z`），tmux 退回 terminfo 默认能力。

## 5. 登录每次都打印欢迎语

- **判别**：`byobu-shell` 的欢迎语条件文件 `~/.config/byobu/.welcome-displayed` 不存在。
- **根因**：initramfs 每次启动都是新根。
- **处理**：镜像里预置该文件。

## 6. 串口脚本发送失败、`git push` 被重置

- **判别**：`Connection was reset` / TLS handshake timeout，但同机 `gh api` 正常。
- **根因**：到 `github.com:443` 的链路被中间设备重置（API 域名不受影响）。
- **处理**：改用 API 建 blob/tree/commit/ref（内容不变），或换网络/代理后重试。

## 7. 位流重新综合后 md5 变化

- **判别**：同一套 RTL、同版本 Vivado，两次综合的 `.bit` md5 不同。
- **根因**：布局布线不可比特复现。
- **处理**：以**功能与时序**为准；发布资产记录 md5，重建的位流不得替换已发布哈希。

## 8. `Could not open 'C' for writing`（Vivado 批处理）

- **判别**：工程路径含空格，报告写不出去。
- **根因**：Tcl 里拼路径未加引号，空格把 `C:\...` 截断成 `C`。
- **处理**：路径加引号或使用无空格目录联接。

## 9. 板子启动后掉进 U-Boot `Zynq>` 提示符

- **判别**：`boot.scr` 只处理一种启动分支（如仅 FOGCCC），切换标记文件后落到 else。
- **根因**：启动脚本缺少默认分支或依赖的文件被删。
- **处理**：在 U-Boot 里恢复标记文件（`fatmv`），或改用 `distro_bootcmd` 的 extlinux 路径。

## 10. 内核 panic：`VFS: Unable to mount root fs`

- **判别**：日志里 `root=` 解析失败、分区列表只有 ram 设备。
- **根因**：DTB 未启用 SD 控制器，或 `root=` 用了当前内核不认的写法。
- **处理**：用镜像自带的 DTB；`root=/dev/mmcblk0pN` 与 `rootwait` 一起用。

## 11. lf 打开文件没反应

- **判别**：`open` 走 `$OPENER`（默认 `xdg-open`），镜像里没有该程序。
- **处理**：在 `lfrc` 里定义 `cmd open`，文本用 `$PAGER`/`$EDITOR`，并 `map <enter> open`。

## 12. 状态栏 CPU% 恒为 0

- **判别**：脚本把上次采样写到 `/run`，而 byobu 以普通用户运行。
- **根因**：`/run` 不可写 → 每次都当首次采样。
- **处理**：改用用户目录（`$BYOBU_CONFIG_DIR`）保存状态，或直接在 item 内采样固定窗口。

## 13. 主机串口脚本无响应（`push_tests.ps1` / `serial_cmd.ps1`）

- **判别**：脚本报 `shell did not answer 'stty -echo'`，但手工用同一端口发回车能收到提示符。
- **根因**：两处默认值不一致。`serial-session.ps1` 与两个推送脚本默认 115200，控制台实际
  921600；另外 byobu/tmux 状态栏在提示符之后持续重绘，按“提示符结尾”匹配的正则会失败。
- **处理**：三个脚本的默认波特率统一为 921600；推送前先 `tmux set -g status off`。
- **验证**：修改后 `serial_push_chunked.ps1` 逐文件 `md5 MATCH`，`serial_cmd.ps1` 正常回显。

## 失效条件

- 换到 PYNQ 镜像（systemd + Jupyter）后，第 1、2、5、6 条的路径与机制不同。
- 换到 Versal 平台后，启动链（PLM/PDI）与第 9、10 条无关。
