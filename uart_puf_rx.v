`timescale 1ns / 1ps

// ============================================================================
// UART PUF Receiver (Replaces sram_puf_core.v)
// Receives 256 bits (32 bytes) over UART and provides it as PUF response.
// ============================================================================

module uart_puf_rx #(
    parameter N = 256,
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         uart_rxd,     // Connect to STM32 TX
    input  wire         read_enable,
    output reg          read_done,
    output reg  [N-1:0] puf_response,
    output wire [N-1:0] meta_flags    // Tie to 0 since physical PUF stability isn't meta here
);

    assign meta_flags = {N{1'b0}};

    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;

    reg [2:0] rxd_sync;
    always @(posedge clk) begin
        if (rst) rxd_sync <= 3'b111;
        else     rxd_sync <= {rxd_sync[1:0], uart_rxd};
    end
    wire rxd_fall = (rxd_sync[2:1] == 2'b10);

    reg [3:0]  state;
    localparam S_IDLE  = 4'd0;
    localparam S_START = 4'd1;
    localparam S_DATA  = 4'd2;
    localparam S_STOP  = 4'd3;

    reg [15:0] baud_cnt;
    reg [2:0]  bit_cnt;
    reg [7:0]  rx_byte;
    reg        rx_valid;

    // UART RX State Machine
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            baud_cnt <= 0;
            bit_cnt  <= 0;
            rx_byte  <= 8'h00;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (rxd_fall) begin
                        baud_cnt <= BAUD_DIV / 2;
                        state    <= S_START;
                    end
                end
                S_START: begin
                    if (baud_cnt == 0) begin
                        if (rxd_sync[2] == 1'b0) begin
                            baud_cnt <= BAUD_DIV;
                            bit_cnt  <= 0;
                            state    <= S_DATA;
                        end else begin
                            state <= S_IDLE;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                S_DATA: begin
                    if (baud_cnt == 0) begin
                        rx_byte  <= {rxd_sync[2], rx_byte[7:1]};
                        baud_cnt <= BAUD_DIV;
                        if (bit_cnt == 7) begin
                            state <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                S_STOP: begin
                    if (baud_cnt == 0) begin
                        rx_valid <= 1'b1;
                        state    <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // PUF Buffer
    reg [5:0] byte_count;
    reg [N-1:0] puf_buffer;
    reg data_ready;

    always @(posedge clk) begin
        if (rst) begin
            byte_count <= 0;
            data_ready <= 1'b0;
            puf_buffer <= {N{1'b0}};
        end else begin
            if (rx_valid && !data_ready) begin
                // Shift in the new byte
                puf_buffer <= {puf_buffer[N-9:0], rx_byte};
                if (byte_count == 31) begin
                    data_ready <= 1'b1;
                end else begin
                    byte_count <= byte_count + 1;
                end
            end
        end
    end

    // Read Logic
    always @(posedge clk) begin
        if (rst) begin
            read_done <= 1'b0;
            puf_response <= {N{1'b0}};
        end else begin
            if (read_enable && !read_done) begin
                if (data_ready) begin
                    puf_response <= puf_buffer;
                    read_done    <= 1'b1;
                end
            end else if (!read_enable) begin
                read_done <= 1'b0;
            end
        end
    end

endmodule
