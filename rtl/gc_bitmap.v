// gc_bitmap.v - mark bitmap (simple dual-port BRAM, independent R/W addresses)
//
// Packed layout (P1 64K): object x = bit (x % 32) of word mem[x / 32].
// The read port bypasses a same-cycle write to the same word (write-first),
// so a read-modify-write never observes stale data when a write and a read
// land on one address in the same cycle.
module gc_bitmap (
    input  wire        clk,

    input  wire [12:0] waddr,
    input  wire [31:0] din,
    input  wire        we,

    input  wire [12:0] raddr,
    output reg  [31:0] dout
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:8191];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= din;
    end

    always @(posedge clk) begin
        if (we && (waddr == raddr))
            dout <= din;        // write-first bypass: same-word hazard
        else
            dout <= mem[raddr];
    end

endmodule
