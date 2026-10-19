// ============================================================
// axi_proto_check.v - AXI3 read-channel protocol checker
//
// A behavioural memory model is NOT a protocol checker: it will happily
// answer a request with the wrong ARSIZE/ARLEN/ARBURST and only the data
// would look odd.  This module watches the master port itself and counts
// every violation of the contract the design assumes:
//
//   1. ARSIZE  == 3'b011   (8 bytes per beat)
//   2. ARLEN   == 0        (one beat, no bursts)
//   3. ARBURST == 2'b01    (INCR; required by AXI even for a single beat)
//   4. ARADDR[2:0] == 0    (8-byte aligned, RDATA is 64-bit)
//   5. ARID    <= 1        (two logical streams: 0 = refs, 1 = headers)
//   6. VALID must stay asserted, with a stable payload, until READY
//   7. no RVALID without an outstanding AR
//
// errors is sticky; the testbench fails the run when it is non-zero.
// ============================================================
module axi_proto_check (
    input  wire        clk,
    input  wire        rstn,

    input  wire [31:0] ARADDR,
    input  wire [5:0]  ARID,
    input  wire [3:0]  ARLEN,
    input  wire [2:0]  ARSIZE,
    input  wire [1:0]  ARBURST,
    input  wire [3:0]  ARCACHE,
    input  wire        ARVALID,
    input  wire        ARREADY,

    input  wire [5:0]  RID,
    input  wire [1:0]  RRESP,
    input  wire        RVALID,
    input  wire        RREADY,

    output reg  [31:0] errors
);
    reg        p_valid = 1'b0;
    reg        p_ready = 1'b0;
    reg [31:0] p_addr  = 32'h0;
    reg [5:0]  p_id    = 6'h0;
    reg [3:0]  p_len   = 4'h0;
    reg [2:0]  p_size  = 3'h0;
    reg [1:0]  p_burst = 2'h0;
    integer    outstanding = 0;

    wire ar_fire = ARVALID && ARREADY;
    wire r_fire  = RVALID  && RREADY;

    always @(posedge clk) begin
        if (!rstn) begin
            errors      <= 32'd0;
            p_valid     <= 1'b0;
            p_ready     <= 1'b0;
            outstanding <= 0;
        end else begin
            // ---- 1..5: geometry must be correct whenever a request is offered
            if (ARVALID === 1'bx || ARVALID === 1'bz) begin
                errors <= errors + 1;
                $display("[AXI][FAIL] ARVALID is x/z @%0t", $time);
            end else if (ARVALID) begin
                if (ARSIZE !== 3'b011) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARSIZE=%b (expect 011 = 8 bytes) @%0t", ARSIZE, $time);
                end
                if (ARLEN !== 4'd0) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARLEN=%0d (expect 0 = single beat) @%0t", ARLEN, $time);
                end
                if (ARBURST !== 2'b01) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARBURST=%b (expect 01 = INCR) @%0t", ARBURST, $time);
                end
                if (ARADDR[2:0] !== 3'b000) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARADDR[2:0]=%b not 8-byte aligned @%0t", ARADDR[2:0], $time);
                end
                if (ARID > 6'd1) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARID=%0d out of range 0/1 @%0t", ARID, $time);
                end
                if (ARCACHE !== 4'b0011) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARCACHE=%b (expect 0011) @%0t", ARCACHE, $time);
                end
            end

            // ---- 6: VALID must not be withdrawn before READY
            if (p_valid && !p_ready) begin
                if (!ARVALID) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] ARVALID dropped before ARREADY @%0t", $time);
                end else if (ARADDR !== p_addr || ARID !== p_id || ARLEN !== p_len ||
                             ARSIZE !== p_size || ARBURST !== p_burst) begin
                    errors <= errors + 1;
                    $display("[AXI][FAIL] AR payload changed while waiting for ARREADY @%0t", $time);
                end
            end

            // ---- 7: a response must belong to an outstanding request
            if (r_fire && outstanding == 0) begin
                errors <= errors + 1;
                $display("[AXI][FAIL] RVALID with no outstanding AR (RID=%0d) @%0t", RID, $time);
            end

            if (ar_fire && !r_fire)      outstanding <= outstanding + 1;
            else if (!ar_fire && r_fire && outstanding > 0) outstanding <= outstanding - 1;

            p_valid <= ARVALID;
            p_ready <= ARREADY;
            p_addr  <= ARADDR;
            p_id    <= ARID;
            p_len   <= ARLEN;
            p_size  <= ARSIZE;
            p_burst <= ARBURST;
        end
    end
endmodule
