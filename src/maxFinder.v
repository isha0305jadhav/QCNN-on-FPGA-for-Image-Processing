`timescale 1ns/1ps
//======================================================
// File: sigmoid_to_max_wrapper.v
// Desc: Collects numInput sequential sigmoid values (sig_valid)
//       into a flat bus, then pulses maxFinder once per frame.
//======================================================
module sigmoid_to_max_wrapper #(
  parameter integer numInput   = 10,
  parameter integer inputWidth = 16
)(
  input  wire                    clk,
  input  wire                    rst,

  // Stream from sigmoid_ht_mif (one value per valid_in=1)
  input  wire [inputWidth-1:0]   sig_value,
  input  wire                    sig_valid,
  input  wire                    frame_start,  // 1-cycle pulse at first value in frame

  // Result from maxFinder
  output wire [31:0]             max_index,
  output wire                    max_index_valid
);

  // Avoid 'buf' reserved word
  reg  [(numInput*inputWidth)-1:0] frame_buf;

  // idx width
  localparam IDXW = (numInput <= 2) ? 1 :
                    (numInput <= 4) ? 2 :
                    (numInput <= 8) ? 3 :
                    (numInput <= 16)? 4 :
                    (numInput <= 32)? 5 :
                    (numInput <= 64)? 6 :
                    (numInput <=128)? 7 :
                    (numInput <=256)? 8 : 9;
  reg [IDXW-1:0] wr_idx;

  reg            mf_i_valid;
  wire [31:0]    mf_o_data;
  wire           mf_o_valid;

  always @(posedge clk) begin
    mf_i_valid <= 1'b0;

    if (rst) begin
      wr_idx <= {IDXW{1'b0}};
    end else begin
      if (frame_start)
        wr_idx <= {IDXW{1'b0}};

      if (sig_valid) begin
        // variable part-select avoided: place value by shift & OR
        // Clear then place (safe approach)
        // Compute start bit
        // Note: to avoid a multiplier, use shift inside a loop or function if needed.
        frame_buf <= (frame_buf & ~({{(numInput*inputWidth){1'b0}}} | 
                      ({{(numInput*inputWidth-inputWidth){1'b0}}, {inputWidth{1'b1}}} << (wr_idx*inputWidth))))
                     | ({{(numInput*inputWidth-inputWidth){1'b0}}, sig_value} << (wr_idx*inputWidth));

        if (wr_idx == numInput-1) begin
          mf_i_valid <= 1'b1;           // kick maxFinder for this frame
          wr_idx     <= {IDXW{1'b0}};
        end else begin
          wr_idx <= wr_idx + 1'b1;
        end
      end
    end
  end

  maxFinder #(
    .numInput   (numInput),
    .inputWidth (inputWidth)
  ) u_maxFinder (
    .i_clk        (clk),
    .i_data       (frame_buf),
    .i_valid      (mf_i_valid),
    .o_data       (mf_o_data),
    .o_data_valid (mf_o_valid)
  );

  assign max_index       = mf_o_data;
  assign max_index_valid = mf_o_valid;

endmodule
