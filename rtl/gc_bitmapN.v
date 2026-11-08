// gc_bitmapN.v - N-bank mark bitmap for the multi-lane engine.
//
// Word w lives in bank w[SEL-1:0] at address w[14:SEL].  Each bank is its own
// simple dual-port BRAM, so the lanes read and write concurrently without
// cross-lane arbitration.  Total capacity stays 32768 x 32 bit.
//
// LANES must be a power of two (2 or 4).
//
// id -> word = id[19:5]; bank = word[SEL-1:0]; addr = word[14:SEL]; bit = id[4:0]
// LANES=2 -> AW=14 (16384 words/bank)
// LANES=4 -> AW=13 ( 8192 words/bank)
module gc_bitmapN #(
    parameter integer LANES = 2,
    parameter integer SEL   = 1,          // log2(LANES)
    parameter integer AW    = 15 - SEL    // bank address width
) (
    input  wire                  clk,

    input  wire [LANES-1:0]      we,
    input  wire [AW*LANES-1:0]   waddr,
    input  wire [32*LANES-1:0]   din,

    input  wire [AW*LANES-1:0]   raddr,
    output wire [32*LANES-1:0]   dout
);

    localparam integer DEPTH = 1 << AW;

    genvar k;
    generate
        for (k = 0; k < LANES; k = k + 1) begin : g_bank
            (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];
            reg [31:0] dout_r;

            always @(posedge clk) begin
                if (we[k])
                    mem[waddr[AW*k +: AW]] <= din[32*k +: 32];
            end

            always @(posedge clk) begin
                dout_r <= mem[raddr[AW*k +: AW]];
            end

            assign dout[32*k +: 32] = dout_r;
        end
    endgenerate

endmodule
