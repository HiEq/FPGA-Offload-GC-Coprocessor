// gc_bitmap.v - mark bitmap (simple dual-port BRAM, independent R/W addresses)
//
// Packed layout (P1 1M): object x = bit (x % 32) of word mem[x / 32].
//
// Keep this module *plain*: one clocked write port and one clocked read port.
// A conditional read (`dout <= mem[raddr]` or `din` on a same-word write) makes
// Vivado declare ram_style=block infeasible and fall back to LUTRAM, which is
// both enormous at 1M bits and stalls physical optimisation.
//
// The write-first bypass lives in gc_top, where the read address and the write
// data are pipelined together (see w_bm_rdata_eff there).  That keeps this
// memory inferable and preserves the 1-cycle read latency the engine expects.
module gc_bitmap (
    input  wire        clk,

    input  wire [14:0] waddr,
    input  wire [31:0] din,
    input  wire        we,

    input  wire [14:0] raddr,
    output reg  [31:0] dout
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:32767];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= din;
    end

    always @(posedge clk) begin
        dout <= mem[raddr];
    end

endmodule
