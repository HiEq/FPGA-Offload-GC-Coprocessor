// ============================================================
// gc_dump.v - copy the mark bitmap to DDR through the HP write channel
//
// The PS cannot read the 128 KiB bitmap quickly over AXI-Lite (one probe
// address + one data read per word), but the HP port already carries a
// 64-bit write channel that the design leaves idle.  This module streams the
// whole bitmap (32768 x 32 bit = 128 KiB) into DDR with 4-beat bursts of
// 32 bytes, then raises `done`.
//
// Read port: borrows the bitmap read port (gc_top muxes it while `busy`).
// 8 words are fetched per burst (2 per 64-bit beat), so the transfer is
// bandwidth-limited rather than probe-limited.
//
// Read timing: gc_bitmap.dout is valid one cycle after bm_raddr.  The address
// for word k is loaded one cycle before D_RDB captures it (D_AW for k = 0, the
// previous D_RDB for k > 0).  Loading it in D_RDA instead captures word k-1.
//
// Clock/reset: single clock, async active-low reset.
// ============================================================
module gc_dump (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,      // 1-cycle: begin a dump
    input  wire [31:0] base,       // destination physical address (32-byte aligned)
    output reg         busy,
    output reg         done,

    output reg  [14:0] bm_raddr,   // bitmap read address
    input  wire [31:0] bm_rdata,   // valid one cycle after bm_raddr

    output reg  [31:0] AWADDR,
    output reg  [5:0]  AWID,
    output reg  [3:0]  AWLEN,
    output reg  [2:0]  AWSIZE,
    output reg  [1:0]  AWBURST,
    output reg  [3:0]  AWCACHE,
    output reg  [2:0]  AWPROT,
    output reg         AWVALID,
    input  wire        AWREADY,

    output reg  [63:0] WDATA,
    output reg  [5:0]  WID,
    output reg  [7:0]  WSTRB,
    output reg         WLAST,
    output reg         WVALID,
    input  wire        WREADY,

    input  wire [5:0]  BID,
    input  wire [1:0]  BRESP,
    input  wire        BVALID,
    output reg         BREADY
);

    localparam integer WORDS  = 32768;   // 1M bits
    localparam integer BURST  = 4;       // beats per AW
    localparam integer BWORDS = BURST*2; // 32-bit words per burst
    localparam integer NBURST = WORDS/BWORDS;   // 4096

    localparam [2:0] D_IDLE = 3'd0, D_AW = 3'd1, D_RDA = 3'd2, D_RDB = 3'd3,
                     D_W = 3'd4, D_B = 3'd5;

    reg [2:0]  state;
    reg [11:0] burst;      // 0 .. NBURST-1
    reg [2:0]  k;          // word index inside the burst (0..7)
    reg [1:0]  beat;       // W beat index
    reg [2:0]  widx;       // next word pair for WDATA
    reg [31:0] dbuf [0:7];

    wire [31:0] burst_addr = base + {15'd0, burst, 5'd0};      // burst*32
    wire [14:0] word_addr  = {burst, 3'd0} + {12'd0, k};       // burst*8 + k

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= D_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            burst    <= 12'd0;
            k        <= 3'd0;
            beat     <= 2'd0;
            widx     <= 3'd0;
            bm_raddr <= 15'd0;
            AWADDR   <= 32'd0;
            AWID     <= 6'd2;
            AWLEN    <= 4'd3;
            AWSIZE   <= 3'b011;         // 8 bytes
            AWBURST  <= 2'b01;          // INCR
            AWCACHE  <= 4'b0011;
            AWPROT   <= 3'b000;
            AWVALID  <= 1'b0;
            WDATA    <= 64'd0;
            WID      <= 6'd2;
            WSTRB    <= 8'hFF;
            WLAST    <= 1'b0;
            WVALID   <= 1'b0;
            BREADY   <= 1'b0;
        end else begin
            case (state)
                D_IDLE: begin
                    BREADY <= 1'b0;
                    if (start) begin
                        done    <= 1'b0;
                        busy    <= 1'b1;
                        burst   <= 12'd0;
                        k       <= 3'd0;
                        beat    <= 2'd0;
                        widx    <= 3'd0;
                        AWADDR  <= base;
                        AWVALID <= 1'b1;
                        state   <= D_AW;
                    end
                end

                D_AW: begin
                    if (AWREADY) begin
                        AWVALID  <= 1'b0;
                        bm_raddr <= {burst, 3'd0};
                        k        <= 3'd0;
                        state    <= D_RDA;
                    end
                end

                D_RDA: begin
                    // The bitmap presents its data one cycle after bm_raddr.
                    // The address for word k was loaded in D_AW (k = 0) or in
                    // the previous D_RDB (k > 0), so this cycle only waits.
                    state <= D_RDB;
                end

                D_RDB: begin
                    dbuf[k] <= bm_rdata;
                    if (k == 3'd7) begin
                        k      <= 3'd0;
                        beat   <= 2'd0;
                        widx   <= 3'd2;
                        WDATA  <= {dbuf[1], dbuf[0]};
                        WVALID <= 1'b1;
                        WLAST  <= 1'b0;
                        state  <= D_W;
                    end else begin
                        bm_raddr <= word_addr + 15'd1;   // next word
                        k       <= k + 3'd1;
                        state   <= D_RDA;
                    end
                end

                D_W: begin
                    if (WREADY) begin
                        if (beat == BURST-1) begin
                            WVALID <= 1'b0;
                            WLAST  <= 1'b0;
                            BREADY <= 1'b1;
                            state  <= D_B;
                        end else begin
                            beat  <= beat + 2'd1;
                            WDATA <= {dbuf[widx + 3'd1], dbuf[widx]};
                            widx  <= widx + 3'd2;
                            WLAST <= (beat == BURST-2);
                        end
                    end
                end

                D_B: begin
                    if (BVALID) begin
                        BREADY <= 1'b0;
                        if (burst == NBURST-1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= D_IDLE;
                        end else begin
                            burst   <= burst + 12'd1;
                            AWADDR  <= burst_addr + 32'd32;
                            AWVALID <= 1'b1;
                            state   <= D_AW;
                        end
                    end
                end

                default: state <= D_IDLE;
            endcase
        end
    end

endmodule
