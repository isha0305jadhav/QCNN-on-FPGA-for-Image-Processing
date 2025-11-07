//======================================================
// File: sigmoid_ht_mif.v  (Verilog-2001 compatible)
// Desc: Sigmoid Look-Up Table reader for an Intel/Altera-style MIF
//       Lines like:  <addr> : <data> ;
// Notes:
//   - Uses a packed byte vector for MEM_FILE (no SystemVerilog 'string').
//   - Parses the MIF at simulation time. For synthesis, initialize BRAM
//     via MEM/COE or vendor IP.
//======================================================
`timescale 1ns/1ps

module sigmoid_ht_mif #(
    parameter integer DEPTH      = 512,     // set to your table depth (e.g., 391)
    parameter integer IN_WIDTH   = 9,       // ceil(log2(DEPTH)); 391 -> 9
    parameter integer DATA_WIDTH = 16,      // 16-bit entries
    // Packed byte vector to hold filename (max 256 chars). Edit default as needed.
    parameter integer MAX_PATH_CHARS = 256,
    parameter [8*MAX_PATH_CHARS-1:0] MEM_FILE = "sigmoid.mif"
)(
    input  wire                      clk,
    input  wire [IN_WIDTH-1:0]       addr_in,    // quantized input/address
    input  wire                      valid_in,   // 1 = read entry at addr_in this cycle
    output reg  [DATA_WIDTH-1:0]     out_value,  // LUT value (registered)
    output reg                       out_valid   // 1-cycle pulse when out_value is fresh
);

    // Memory
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // --- MIF loader (simulation only) ---
    // Parses lines "addr : data ;" in decimal. Ignores non-matching lines.
    integer fd, n, addr, data;
    integer line_len;
    reg [8*256-1:0] line;  // line buffer (256 chars)

    initial begin : load_mif
        integer i;
        // Init to zero (optional)
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_WIDTH{1'b0}};

        fd = $fopen(MEM_FILE, "r");
        if (fd == 0) begin
            $display("ERROR: Cannot open MIF file: %0s", MEM_FILE);
            $finish;
        end

        // Read file line-by-line; try to parse "<addr> : <data> ;"
        while (!$feof(fd)) begin
            line_len = $fgets(line, fd);
            if (line_len > 0) begin
                // $sscanf is widely supported by simulators; if your tool lacks it,
                // convert the MIF to a simple .mem and use $readmemh/b instead.
                n = $sscanf(line, "%d : %d ;", addr, data);
                if (n == 2) begin
                    if (addr >= 0 && addr < DEPTH)
                        mem[addr] = data[DATA_WIDTH-1:0];
                end
                // else ignore headers/whitespace/other lines
            end
        end
        $fclose(fd);
        $display("MIF load complete: %0s", MEM_FILE);
    end

    // 1-cycle registered output
    always @(posedge clk) begin
        out_valid <= valid_in;
        if (valid_in) begin
            if (addr_in < DEPTH)
                out_value <= mem[addr_in];
            else
                out_value <= {DATA_WIDTH{1'b0}}; // out-of-range guard
        end
    end

endmodule
