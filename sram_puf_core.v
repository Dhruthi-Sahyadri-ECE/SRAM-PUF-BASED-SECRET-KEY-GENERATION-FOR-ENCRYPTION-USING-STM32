`timescale 1ns / 1ps
// ============================================================================
// SRAM PUF Core Module -- synthesizable, single always block
// ============================================================================

`include "sram_puf_params.vh"

module sram_puf_core #(
    parameter N              = `DEFAULT_PUF_SIZE,
    parameter BIAS_WIDTH     = `DEFAULT_BIAS_WIDTH,
    parameter NOISE_PROB     = `DEFAULT_NOISE_PROB,
    parameter META_THRESHOLD = `DEFAULT_META_THRESHOLD
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         enable_noise,
    input  wire [7:0]   temp_factor,
    input  wire [7:0]   voltage_factor,
    input  wire         read_enable,
    output reg          read_done,
    output reg  [N-1:0] puf_response,
    output reg          puf_bit,
    output reg  [N-1:0] meta_flags
);

    reg [N-1:0]          sram_cells;
    reg [BIAS_WIDTH-1:0] cell_bias    [0:N-1];
    reg [3:0]            settling_time[0:N-1];
    reg [$clog2(N):0]    read_index;
    reg [N-1:0]          noise_source;
    reg [7:0]            noise_counter;

    // -----------------------------------------------------------------------
    // Bias function -- deterministic, no function-call indexing at call site
    // -----------------------------------------------------------------------
    function [BIAS_WIDTH-1:0] compute_bias;
        input integer idx;
        reg [31:0] t;
        begin
            t = (idx * 32'd214013  + 32'd2531011);
            t =  t ^ (t >> 16);
            t = (t * 32'd1103515245 + 32'd12345);
            compute_bias = t[BIAS_WIDTH-1:0];
        end
    endfunction

    integer i;

    // Temporaries used inside the reset block
    reg [BIAS_WIDTH-1:0] b;   // holds compute_bias result for current cell

    always @(posedge clk) begin
        if (rst) begin
            // ------------------------------------------------------------------
            // Power-up: initialise every cell from its bias
            // ------------------------------------------------------------------
            for (i = 0; i < N; i = i + 1) begin
                b = compute_bias(i);          // evaluate once, store in temp
                cell_bias[i]    <= b;
                sram_cells[i]   <= (b > (8'h80 + i[3:0])) ? 1'b1 : 1'b0;

                if ((b > 8'h70) && (b < 8'h90))
                    settling_time[i] <= META_THRESHOLD + 2;  // near threshold = metastable
                else
                    settling_time[i] <= b[3:0];              // safe: index on reg, not function call
            end

            for (i = 0; i < N; i = i + 1)
                meta_flags[i] <= (settling_time[i] > META_THRESHOLD);

            noise_source  <= {N{1'b1}};
            noise_counter <= 8'hA5;
            read_index    <= 0;
            read_done     <= 1'b0;
            puf_response  <= {N{1'b0}};
            puf_bit       <= 1'b0;

        end else begin
            // ------------------------------------------------------------------
            // One cycle after reset: latch noise source from real cell values
            // ------------------------------------------------------------------
            if (noise_source == {N{1'b1}})
                noise_source <= sram_cells;

            // ------------------------------------------------------------------
            // Readout with optional noise injection
            // ------------------------------------------------------------------
            if (read_enable && !read_done) begin
                begin : readout
                    reg [15:0] eff_noise;
                    reg [7:0]  thresh;
                    reg        nbit;

                    puf_bit <= sram_cells[read_index];

                    if (enable_noise) begin
                        eff_noise = NOISE_PROB * temp_factor * voltage_factor;
                        eff_noise = eff_noise >> 14;
                        thresh    = (eff_noise > 16'd255) ? 8'hFF : eff_noise[7:0];
                        nbit      = noise_source[noise_counter];
                        noise_counter <= noise_counter + 1;

                        if (nbit && (noise_counter < thresh)) begin
                            puf_bit                  <= ~sram_cells[read_index];
                            puf_response[read_index] <= ~sram_cells[read_index];
                        end else begin
                            puf_response[read_index] <= sram_cells[read_index];
                        end
                    end else begin
                        puf_response[read_index] <= sram_cells[read_index];
                    end
                end

                if (read_index == N-1)
                    read_done  <= 1'b1;
                else
                    read_index <= read_index + 1;

            end else if (!read_enable) begin
                read_index <= 0;
                read_done  <= 1'b0;
            end
        end
    end

endmodule
