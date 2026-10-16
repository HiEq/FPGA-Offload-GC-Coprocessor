// ============================================================
// gc_bitmap.v — 标记位图
//
// 修复策略: 不依赖综合器推断, 用最标准的Xilinx BRAM模板
//   - 写口: 单一always块, 单一条件, 单一地址
//   - 读口: 单一always块, 无条件
//   - 清零: 完全由外部引擎通过写口完成 (不在此模块内)
// ============================================================
module gc_bitmap (
    input  wire        clk,
    input  wire [11:0] addra,
    input  wire [31:0] dina,
    input  wire        wea,
    output reg  [31:0] douta
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:4095];

    // 写口 — Xilinx官方推荐模板
    always @(posedge clk) begin
        if (wea)
            mem[addra] <= dina;
    end

    // 读口 — Xilinx官方推荐模板
    always @(posedge clk) begin
        douta <= mem[addra];
    end

endmodule
