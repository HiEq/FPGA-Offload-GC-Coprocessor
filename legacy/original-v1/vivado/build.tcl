# ============================================================
# build.tcl — FOGCCC Vivado工程自动创建脚本
# 平台: Xilinx Zynq-7000 XC7Z100
#
# 用法 (三选一):
#   1. Vivado Tcl Console:  source C:/Users/wwwmt/Desktop/fogccc/vivado/build.tcl
#   2. Vivado Tcl Console:  cd到本目录后:  source build.tcl
#   3. 命令行:              vivado -mode batch -source build.tcl
#
# 产出:
#   fogccc_proj/system.bd              (Block Design)
#   fogccc_proj/.../system_wrapper.v   (HDL Wrapper)
#   fogccc_proj/.../system_wrapper.bit  (Bitstream)
#   fogccc_proj/system.xsa             (硬件导出)
# ============================================================

# ============ 配置 ============
set PART      "xc7z100ffg900-2"
set PROJ_NAME "fogccc_z7100"
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set PROJ_DIR  [file normalize [file join $SCRIPT_DIR "fogccc_proj"]]
set RTL_DIR    [file normalize [file join $SCRIPT_DIR ".." "rtl"]]

puts "INFO: RTL dir = $RTL_DIR"
puts "INFO: Part    = $PART"

# ============ 创建工程 ============
create_project $PROJ_NAME $PROJ_DIR -part $PART -force
puts "INFO: Project created"

# ============ 添加RTL ============
set rtl_files [glob -nocomplain [file join $RTL_DIR "*.v"]]
if {[llength $rtl_files] == 0} {
    puts "ERROR: No .v files in $RTL_DIR"
    exit 1
}
add_files -norecurse $rtl_files
puts "INFO: Added [llength $rtl_files] RTL files"

# ============ 创建Block Design ============
create_bd_design "system"
puts "INFO: Creating Block Design..."

# ---- 1. PS7 (开源骚客 OS-ZYNQ7100 Lite 板卡配置) ----
# 参照厂商 design_1.bd: 只设必需参数, DDR延迟/时序由IP按型号自动计算
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0
set_property -dict [list \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15} \
    CONFIG.PCW_UART0_BAUD_RATE {115200} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
    CONFIG.PCW_EN_DDR {1} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.333333} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
] [get_bd_cells ps7_0]
puts "INFO: PS7 configured for OS-ZYNQ7100 Lite board (minimal, IP auto DDR)"

# ---- 2. AXI Interconnect (AXI-Lite) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_lite_ic
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] [get_bd_cells axi_lite_ic]
puts "INFO: AXI Interconnect created"

# ---- 3. Reset Generator (100MHz域) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_gen

# ---- 3.1 Reset Generator (200MHz域, AXI HP专用) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_gen_hp
puts "INFO: Two reset generators created (100MHz + 200MHz)"

# ---- 4. GC Coprocessor ----
create_bd_cell -type module -reference gc_top gc_top_0
puts "INFO: gc_top instantiated"

# ---- 5. AXI Interconnect for HP path (AXI4 -> AXI3 自动转换) ----
# 用Interconnect替代ProtocolConverter, 自动协商ID宽度和协议
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 hp_ic
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] [get_bd_cells hp_ic]
puts "INFO: AXI Interconnect for HP path created"

# ============================================================
# 6. 时钟连接
# ============================================================
# FCLK_CLK0 (100MHz)
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_lite_ic/ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins gc_top_0/S_AXI_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins rst_gen/slowest_sync_clk]

# PS7 AXI接口时钟 (必须单独连接!)
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins ps7_0/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins ps7_0/S_AXI_HP0_ACLK]

# AXI互联每通道时钟
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_lite_ic/S00_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0] [get_bd_pins axi_lite_ic/M00_ACLK]

# FCLK_CLK1 (200MHz) -> AXI HP + HP Interconnect + rst_gen_hp
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins gc_top_0/S_AXI_HP_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins hp_ic/ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins hp_ic/S00_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins hp_ic/M00_ACLK]
connect_bd_net [get_bd_pins ps7_0/FCLK_CLK1] [get_bd_pins rst_gen_hp/slowest_sync_clk]

puts "INFO: Clocks connected"

# ============================================================
# 6. 复位连接
# ============================================================
# 100MHz域 (AXI-Lite + 引擎)
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_gen/ext_reset_in]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins axi_lite_ic/ARESETN]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins axi_lite_ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins axi_lite_ic/M00_ARESETN]
connect_bd_net [get_bd_pins rst_gen/peripheral_aresetn] [get_bd_pins gc_top_0/S_AXI_ARESETN]

# 200MHz域 (AXI HP) — 必须用独立的rst_gen_hp, 保证复位同步到FCLK_CLK1
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_gen_hp/ext_reset_in]
connect_bd_net [get_bd_pins rst_gen_hp/peripheral_aresetn] [get_bd_pins gc_top_0/S_AXI_HP_ARESETN]
connect_bd_net [get_bd_pins rst_gen_hp/peripheral_aresetn] [get_bd_pins hp_ic/ARESETN]
connect_bd_net [get_bd_pins rst_gen_hp/peripheral_aresetn] [get_bd_pins hp_ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst_gen_hp/peripheral_aresetn] [get_bd_pins hp_ic/M00_ARESETN]

puts "INFO: Resets connected (100MHz + 200MHz domains)"

# ============================================================
# 7. AXI-Lite 数据通路 (PS7 -> gc_top 控制寄存器)
# ============================================================
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0] \
                    [get_bd_intf_pins axi_lite_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_lite_ic/M00_AXI] \
                    [get_bd_intf_pins gc_top_0/S_AXI]

puts "INFO: AXI-Lite path connected (GP0 -> interconnect -> gc_top)"

# ============================================================
# 8. AXI HP 数据通路 (gc_top 读DDR, 经AXI Interconnect)
# ============================================================
connect_bd_intf_net [get_bd_intf_pins gc_top_0/S_AXI_HP] \
                    [get_bd_intf_pins hp_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins hp_ic/M00_AXI] \
                    [get_bd_intf_pins ps7_0/S_AXI_HP0]

puts "INFO: AXI HP path connected (gc_top -> hp_ic -> HP0)"

# ============================================================
# 9. 地址映射
# ============================================================
# 先自动分配所有地址段
assign_bd_address

# 找到gc_top在PS7地址空间中的映射段并设置偏移
# 注意: 该段属于 /ps7_0/Data (主机地址空间), 形如 /ps7_0/Data/SEG_gc_top_0_reg0,
#       既不能用 interconnect 引脚找, 也不能用 gc_top 单元找
set gc_seg ""
foreach s [get_bd_addr_segs -quiet] {
    set p [get_property PATH $s]
    if {[string match "*/ps7_0/Data*" $p] && [string match "*gc_top*" $p]} {
        set gc_seg $s
        break
    }
}
if {$gc_seg ne ""} {
    set_property offset 0x43C00000 $gc_seg
    set_property range  64K        $gc_seg
    puts "INFO: gc_top @ 0x43C00000 (64KB) seg=[get_property PATH $gc_seg]"
} else {
    puts "WARNING: gc_top address segment not found!"
}

# 确保HP0指向DDR (gc_top通过HP0读DDR, PS7的HP0 slave段应映射到DDR)
set hp_seg [get_bd_addr_segs -quiet -of_objects \
            [get_bd_intf_pins ps7_0/S_AXI_HP0]]
if {[llength $hp_seg] > 0} {
    # HP0的slave段由PS7自动映射到DDR, 无需手动设置
    puts "INFO: HP0 address segment: [get_property PATH [lindex $hp_seg 0]]"
}

# ============================================================
# 10. 验证并保存
# ============================================================
validate_bd_design
save_bd_design
puts "INFO: Block Design validated and saved"

# 防止OOC综合在Windows上因路径冒号报错
set_property generate_synth_checkpoint false [get_files system.bd]
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1

# ============================================================
# 11. 生成Output Products
# ============================================================
generate_target all [get_files system.bd]
puts "INFO: Output products generated"

# ============================================================
# 12. 生成HDL Wrapper并设为顶层
# ============================================================
make_wrapper -files [get_files system.bd] -top

# 查找wrapper文件
set wrapper_file ""
foreach f [get_files -quiet -filter {NAME =~ "*system_wrapper*"}] {
    set wrapper_file $f
    break
}

if {$wrapper_file eq ""} {
    # 尝试常见路径
    set candidates [glob -nocomplain \
        [file join $PROJ_DIR ${PROJ_NAME}.srcs sources_1 bd system hdl system_wrapper.v] \
        [file join $PROJ_DIR ${PROJ_NAME}.gen sources_1 bd system hdl system_wrapper.v]]
    if {[llength $candidates] > 0} {
        set wrapper_file [lindex $candidates 0]
    }
}

if {$wrapper_file ne ""} {
    add_files -norecurse $wrapper_file
    set_property top system_wrapper [current_fileset]
    puts "INFO: Wrapper found and set as top: $wrapper_file"
} else {
    puts "WARNING: Wrapper file not found! Check project manually."
}

# 更新编译顺序
update_compile_order -fileset sources_1

# ============================================================
# 13. 打印设计摘要
# ============================================================
puts ""
puts "============================================"
puts "  BLOCK DESIGN SUMMARY"
puts "============================================"
puts "  Cells:"
foreach c [get_bd_cells] {
    puts "    $c : [get_property VLNV [get_bd_cells $c]]"
}
puts ""
puts "  Interface Nets:"
foreach n [get_bd_intf_nets] {
    set src [get_bd_intf_pins -of_objects $n -filter {DIR == O}]
    set dst [get_bd_intf_pins -of_objects $n -filter {DIR == I}]
    puts "    [lindex $src 0] -> [lindex $dst 0]"
}
puts ""
puts "  Address Segments:"
foreach s [get_bd_addr_segs] {
    puts "    [get_property PATH $s] @ [get_property OFFSET $s] ([get_property RANGE $s])"
}
puts "============================================"
puts ""

# ============================================================
# 14. 综合
# ============================================================
puts "INFO: Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed! Check logs."
    exit 1
}
puts "INFO: Synthesis PASSED"

# ============================================================
# 15. 实现
# ============================================================
puts "INFO: Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed! Check logs."
    exit 1
}
puts "INFO: Implementation PASSED"

# ============================================================
# 16. 时序检查
# ============================================================
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns < 0} {
    puts "WARNING: TIMING VIOLATION! WNS = $wns ns"
} else {
    puts "INFO: Timing MET! WNS = $wns ns"
}

# ============================================================
# 17. 资源报告
# ============================================================
# 用 file join + forward slash 避免Windows路径冒号问题
report_utilization -file [file join [file normalize $PROJ_DIR] utilization.rpt]
report_timing_summary -file [file join [file normalize $PROJ_DIR] timing.rpt]
puts "INFO: Reports saved to [file normalize $PROJ_DIR]"

# 设置最大线程数 (加速综合/实现)
set_param general.maxThreads 20

# ============================================================
# 18. 生成Bitstream
# ============================================================
puts "INFO: Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ============================================================
# 19. 导出硬件
# ============================================================
write_hw_platform -fixed -include_bit -force \
    [file join [file normalize $PROJ_DIR] "system.xsa"]

# ============ 完成 ============
set bit_file [file join $PROJ_DIR ${PROJ_NAME}.runs impl_1 system_wrapper.bit]
puts ""
puts "============================================"
puts "  BUILD COMPLETE"
puts "============================================"
puts "  Block Design : [file join $PROJ_DIR ${PROJ_NAME}.srcs sources_1 bd system system.bd]"
puts "  Bitstream    : $bit_file"
puts "  Hardware     : [file join $PROJ_DIR system.xsa]"
puts "  Utilization  : [file join $PROJ_DIR utilization.rpt]"
puts "  Timing       : [file join $PROJ_DIR timing.rpt]"
puts "============================================"
