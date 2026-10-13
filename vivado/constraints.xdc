# ============================================================
# constraints.xdc — XC7Z100 时钟约束
#
# 注意: PS7 IP 会自动生成 FCLK_CLK0/CLK1 的时钟约束,
#       不需要手动 create_clock。此文件仅保留IO约束。
#
# 如果需要额外的PL侧时钟约束, 在此添加。
# ============================================================

# PS7 FCLK_CLK0 (100MHz) 和 FCLK_CLK1 (200MHz)
# 已由 processing_system7 IP 自动生成约束, 无需重复定义

# IO约束 (根据板卡引脚修改)
# set_property PACKAGE_PIN <PIN> [get_ports <port>]
# set_property IOSTANDARD LVCMOS33 [get_ports <port>]
