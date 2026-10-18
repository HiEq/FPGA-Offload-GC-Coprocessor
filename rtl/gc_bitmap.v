// ============================================================
// gc_bitmap.v — 标记位图 (简单双口 BRAM, 读/写地址独立)
//
// 映射: 对象 x 的状态 = mem[x] 的第 (x%32) 位
//   与 gc_test.py / fpga_gc.c 一致
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

    // 写口
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= din;
    end

    // 读口 (独立 always 块)
    always @(posedge clk) begin
        dout <= mem[raddr];
    end

endmodule
