// ============================================================
// gc_bitmap.v — 标记位图 (简单双口 BRAM: 读口/写口 地址独立)
//
// 为什么必须是"独立地址口":
//   引擎的引用快路径要"这一拍读/下一拍写", 而单口 BRAM 读写共用地址线,
//   写脉冲(寄存器)生效那一拍地址已经被新引用覆盖 → 会写到别人的字上,
//   去重失效. 拆成独立读写地址口后, 同拍读写互不干扰.
//
// 映射: 对象 x 的状态 = mem[x] 的第 (x%32) 位
//   (历史约定, 与 gc_test.py / fpga_gc.c 一致, 不要改)
// ============================================================
module gc_bitmap (
    input  wire        clk,

    // ---- 写口 ----
    input  wire [11:0] waddr,
    input  wire [31:0] din,
    input  wire        we,

    // ---- 读口 (独立地址, 1 拍延迟) ----
    input  wire [11:0] raddr,
    output reg  [31:0] dout
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:4095];

    // 写口 — Xilinx 官方推荐模板
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= din;
    end

    // 读口 — 独立 always 块, 无条件读取
    always @(posedge clk) begin
        dout <= mem[raddr];
    end

endmodule
