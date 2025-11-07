`timescale 1ns/1ps
`include "include.v"
// ====================================================================
// File: q_layer.v  (FULL FILE)
// Purpose: Provide q-layer streams (values like 0.7 / 0.6 -> Q1.15),
//          frame packing into a flattened bus, and a dual-bus top
//          that can plug directly into maxFinder(i_data/i_valid).
//
// Contains (in order):
//   (1) q_layer                 : emits 1 value/clk from a small LUT
//   (2) q_layer_frame_packer    : packs NUMINPUT samples into a bus
//   (3) ht_pos_lut10 (shim)     : compatibility wrapper -> q_layer
//   (4) q_layer_dual_bus_top    : two packed q-layers (layer0/layer1)
//
// NOTE: The shim (3) fixes "Module <ht_pos_lut10> not found" by
//       providing that module name and internally instantiating q_layer.
//       No changes required to other files/instantiations.
// ====================================================================


// ------------------------------------------------------------
// (1) q_layer: Emits one positive value per clock from a small
//     LUT table. Index cycles 0..FRAME_LEN-1, then wraps.
//     Output is signed Q1.15 (DATAW=16). sig_valid=1 only for >0.
// ------------------------------------------------------------
module q_layer #(
  parameter integer DATAW      = 16,   // signed data width (Q1.15)
  parameter integer FRAME_LEN  = 10,   // fixed frame length (indices 0..9)
  parameter integer LAYER_ID   = 0     // 0 or 1: choose which table
)(
  input  wire                      i_clk,
  input  wire                      i_rst,       // sync reset
  input  wire                      i_start,     // 1: stream frames continuously (or a gated enable)
  output reg  signed [DATAW-1:0]   sig_value,   // positive value only (Q1.15)
  output reg                       sig_valid,   // 1 when sig_value > 0
  output reg                       o_frame_done // 1-cycle pulse at end of frame
);

  // index 0..FRAME_LEN-1 across the frame
  // FRAME_LEN is 10 in your setup, so 4 bits are sufficient.
  reg [3:0] idx;

  // Layer-0 LUT (examples shown; replace with your real values if needed)
  function automatic signed [DATAW-1:0] lut_q15_layer0;
    input [3:0] i;
    begin
      case (i)
        4'd0: lut_q15_layer0 = 16'sh5B6B; // +0.7142
        4'd1: lut_q15_layer0 = 16'sh5A82; // +0.7071
        4'd2: lut_q15_layer0 = 16'sh5A82;
        4'd3: lut_q15_layer0 = 16'sh5A82;
        4'd4: lut_q15_layer0 = 16'sh5A82;
        4'd5: lut_q15_layer0 = 16'sh5A82;
        4'd6: lut_q15_layer0 = 16'sh5A82;
        4'd7: lut_q15_layer0 = 16'sh5A82;
        4'd8: lut_q15_layer0 = 16'sh5A82;
        4'd9: lut_q15_layer0 = 16'sh5A82;
        default: lut_q15_layer0 = 16'sh0000;
      endcase
    end
  endfunction

  // Layer-1 LUT (slightly different constants)
  function automatic signed [DATAW-1:0] lut_q15_layer1;
    input [3:0] i;
    begin
      case (i)
        4'd0: lut_q15_layer1 = 16'sh4CCC; // ~+0.6000
        4'd1: lut_q15_layer1 = 16'sh5000; // ~+0.6250
        4'd2: lut_q15_layer1 = 16'sh51EC; // ~+0.6400
        4'd3: lut_q15_layer1 = 16'sh5400; // ~+0.6563
        4'd4: lut_q15_layer1 = 16'sh5555; // ~+0.6667
        4'd5: lut_q15_layer1 = 16'sh570A; // ~+0.6800
        4'd6: lut_q15_layer1 = 16'sh5800; // ~+0.6875
        4'd7: lut_q15_layer1 = 16'sh58E4; // ~+0.6953
        4'd8: lut_q15_layer1 = 16'sh5A00; // ~+0.7031
        4'd9: lut_q15_layer1 = 16'sh5A82; // ~+0.7071
        default: lut_q15_layer1 = 16'sh0000;
      endcase
    end
  endfunction

  function automatic signed [DATAW-1:0] lut_q15;
    input [3:0] i;
    begin
      lut_q15 = (LAYER_ID==0) ? lut_q15_layer0(i)
                              : lut_q15_layer1(i);
    end
  endfunction

  // Sequencer: one LUT output per clock when i_start=1.
  always @(posedge i_clk) begin
    if (i_rst) begin
      idx          <= 4'd0;
      sig_value    <= {DATAW{1'b0}};
      sig_valid    <= 1'b0;
      o_frame_done <= 1'b0;
    end else begin
      o_frame_done <= 1'b0; // default (deassert)

      if (i_start) begin
        // Current entry
        sig_value <= lut_q15(idx);
        // Positive-only selection (drive valid only if >0)
        sig_valid <= (lut_q15(idx) > 0);

        // Advance index; wrap at FRAME_LEN-1 and pulse frame_done
        if (idx == (FRAME_LEN-1)) begin
          idx          <= 4'd0;   // auto-reset counter after every frame
          o_frame_done <= 1'b1;   // 1-cycle pulse
        end else begin
          idx <= idx + 1'b1;
        end
      end else begin
        // Hold at start (idle)
        idx          <= 4'd0;
        sig_value    <= lut_q15(4'd0);
        sig_valid    <= (lut_q15(4'd0) > 0);
        o_frame_done <= 1'b0;
      end
    end
  end

endmodule


// --------------------------------------------------------------------
// (2) q_layer_frame_packer:
//     Packs NUMINPUT sequential values (when sig_valid=1) into a single
//     concatenated bus: o_data[(NUMINPUT*DATAW)-1:0], where slice k
//     is [k*DATAW +: DATAW]. Pulses o_valid for 1 cycle at end.
//     Counter auto-resets after each frame.
// --------------------------------------------------------------------
module q_layer_frame_packer #(
  parameter integer DATAW     = 16,
  parameter integer NUMINPUT  = 10
)(
  input  wire                        clk,
  input  wire                        rst,
  // stream in from LUT (positive-only values, 1 per clk)
  input  wire signed [DATAW-1:0]     sig_value,
  input  wire                        sig_valid,
  // packed frame out -> directly to maxFinder (i_data/i_valid)
  output reg  [(NUMINPUT*DATAW)-1:0] o_data,
  output reg                         o_valid
);
  // Compute minimal index width for NUMINPUT
  localparam IDXW = (NUMINPUT<=2)  ? 1 :
                    (NUMINPUT<=4)  ? 2 :
                    (NUMINPUT<=8)  ? 3 :
                    (NUMINPUT<=16) ? 4 : 5;

  reg [IDXW-1:0] wr_idx;

  integer ii;

  always @(posedge clk) begin
    if (rst) begin
      o_valid <= 1'b0;
      wr_idx  <= {IDXW{1'b0}};
      o_data  <= {(NUMINPUT*DATAW){1'b0}};
    end else begin
      o_valid <= 1'b0; // default

      if (sig_valid) begin
        // place current sample into its slot
        o_data[wr_idx*DATAW +: DATAW] <= sig_value;

        // advance / wrap
        if (wr_idx == NUMINPUT-1) begin
          wr_idx  <= {IDXW{1'b0}}; // frame complete -> auto reset index
          o_valid <= 1'b1;         // 1-cycle strobe to maxFinder i_valid
        end else begin
          wr_idx <= wr_idx + 1'b1;
        end
      end
    end
  end

endmodule


// --------------------------------------------------------------------
// (3) ht_pos_lut10 (compatibility shim):
//     Your top uses 'ht_pos_lut10' in q_layer_dual_bus_top.
//     This wrapper simply maps that name to the q_layer module,
//     fixing "Module <ht_pos_lut10> not found" without changing
//     any other code.
// --------------------------------------------------------------------
module ht_pos_lut10 #(
  parameter integer DATAW     = 16,
  parameter integer FRAME_LEN = 10,
  parameter integer LAYER_ID  = 0
)(
  input  wire                    i_clk,
  input  wire                    i_rst,
  input  wire                    i_start,
  output wire signed [DATAW-1:0] sig_value,
  output wire                    sig_valid,
  output wire                    o_frame_done
);
  q_layer #(
    .DATAW     (DATAW),
    .FRAME_LEN (FRAME_LEN),
    .LAYER_ID  (LAYER_ID)
  ) u_q_layer (
    .i_clk        (i_clk),
    .i_rst        (i_rst),
    .i_start      (i_start),
    .sig_value    (sig_value),
    .sig_valid    (sig_valid),
    .o_frame_done (o_frame_done)
  );
endmodule


// --------------------------------------------------------------------
// (4) q_layer_dual_bus_top:
//     Builds TWO independent q-layers (LAYER_ID=0 and 1), each
//     producing a packed bus + valid that can be wired *directly*
//     into maxFinder(i_data, i_valid). No change to maxFinder needed.
// --------------------------------------------------------------------
module q_layer_dual_bus_top #(
  parameter integer DATAW     = 16,
  parameter integer NUMINPUT  = 10
)(
  input  wire                                 clk,
  input  wire                                 rst,
  input  wire                                 start_frames,  // gate/enable frames

  // --- Layer 0 outputs -> plug to maxFinder instance A ---
  output wire [(NUMINPUT*DATAW)-1:0]          o_data_layer0,
  output wire                                 o_valid_layer0,

  // --- Layer 1 outputs -> plug to maxFinder instance B ---
  output wire [(NUMINPUT*DATAW)-1:0]          o_data_layer1,
  output wire                                 o_valid_layer1
);

  // ---------- Layer 0 stream ----------
  wire signed [DATAW-1:0] l0_sig_value;
  wire                    l0_sig_valid;
  wire                    l0_frame_done;

  ht_pos_lut10 #(
    .DATAW     (DATAW),
    .FRAME_LEN (NUMINPUT),
    .LAYER_ID  (0)
  ) u_lut_l0 (
    .i_clk        (clk),
    .i_rst        (rst),
    .i_start      (start_frames),
    .sig_value    (l0_sig_value),
    .sig_valid    (l0_sig_valid),
    .o_frame_done (l0_frame_done)
  );

  q_layer_frame_packer #(
    .DATAW    (DATAW),
    .NUMINPUT (NUMINPUT)
  ) u_pack_l0 (
    .clk       (clk),
    .rst       (rst),
    .sig_value (l0_sig_value),
    .sig_valid (l0_sig_valid),
    .o_data    (o_data_layer0),
    .o_valid   (o_valid_layer0)
  );

  // ---------- Layer 1 stream ----------
  wire signed [DATAW-1:0] l1_sig_value;
  wire                    l1_sig_valid;
  wire                    l1_frame_done;

  ht_pos_lut10 #(
    .DATAW     (DATAW),
    .FRAME_LEN (NUMINPUT),
    .LAYER_ID  (1)
  ) u_lut_l1 (
    .i_clk        (clk),
    .i_rst        (rst),
    .i_start      (start_frames),
    .sig_value    (l1_sig_value),
    .sig_valid    (l1_sig_valid),
    .o_frame_done (l1_frame_done)
  );

  q_layer_frame_packer #(
    .DATAW    (DATAW),
    .NUMINPUT (NUMINPUT)
  ) u_pack_l1 (
    .clk       (clk),
    .rst       (rst),
    .sig_value (l1_sig_value),
    .sig_valid (l1_sig_valid),
    .o_data    (o_data_layer1),
    .o_valid   (o_valid_layer1)
  );

endmodule
