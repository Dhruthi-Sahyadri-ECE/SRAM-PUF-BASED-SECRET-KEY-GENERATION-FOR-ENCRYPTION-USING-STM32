`timescale 1ns / 1ps
`include "sram_puf_params.vh"

module nexys_a7_top (
    input  wire        clk,
    input  wire        btnL,
    input  wire        btnC,
    input  wire        btnR,
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [7:0]  an,
    output wire        uart_txd,
    input  wire        uart_rxd_stm32
);

    localparam HELPER_BITS = 248;
    localparam DB_MAX      = 2_000_000;
    localparam SEG_REFRESH = 100_000;
    localparam BAUD_DIV    = 868;

    // Button debounce
    reg [20:0] db_cnt [0:2];
    reg        btn_d  [0:2];
    reg        btn_db [0:2];
    wire       btn_in [0:2];
    assign btn_in[0] = btnL;
    assign btn_in[1] = btnC;
    assign btn_in[2] = btnR;

    genvar gi;
    generate
        for (gi = 0; gi < 3; gi = gi + 1) begin : debounce
            always @(posedge clk) begin
                if (btn_in[gi] != btn_d[gi]) begin
                    db_cnt[gi] <= 0;
                    btn_d[gi]  <= btn_in[gi];
                end else if (db_cnt[gi] < DB_MAX)
                    db_cnt[gi] <= db_cnt[gi] + 1;
                else
                    btn_db[gi] <= btn_d[gi];
            end
        end
    endgenerate

    reg [2:0] btn_prev;
    wire pulse_rst    = btn_db[0] & ~btn_prev[0];
    wire pulse_enroll = btn_db[1] & ~btn_prev[1];
    wire pulse_recon  = btn_db[2] & ~btn_prev[2];
    always @(posedge clk)
        btn_prev <= {btn_db[2], btn_db[1], btn_db[0]};

    // System reset
    reg [3:0] rst_pipe;
    wire sys_rst = |rst_pipe;
    always @(posedge clk) begin
        if (pulse_rst) rst_pipe <= 4'hF;
        else           rst_pipe <= {1'b0, rst_pipe[3:1]};
    end

    // PUF controller signals
    reg  start_enroll_r;
    reg  start_recon_r;
    reg  [HELPER_BITS-1:0] stored_helper;
    reg  helper_valid;
    reg  enrolled_pending;
    reg  op_done_prev;
    reg  fsm_busy;

    wire operation_done;
    wire [255:0] key_out;
    wire [HELPER_BITS-1:0] helper_data_out;
    wire error_flag;
    wire [3:0] fsm_state;

    always @(posedge clk) begin
        if (sys_rst) begin
            start_enroll_r   <= 1'b0;
            start_recon_r    <= 1'b0;
            helper_valid     <= 1'b0;
            enrolled_pending <= 1'b0;
            stored_helper    <= {HELPER_BITS{1'b0}};
            op_done_prev     <= 1'b0;
            fsm_busy         <= 1'b0;
        end else begin
            op_done_prev   <= operation_done;
            start_enroll_r <= 1'b0;
            start_recon_r  <= 1'b0;
            if (operation_done && !op_done_prev)
                fsm_busy <= 1'b0;
            if (pulse_enroll && !fsm_busy) begin
                start_enroll_r   <= 1'b1;
                enrolled_pending <= 1'b1;
                fsm_busy         <= 1'b1;
            end
            if (pulse_recon && !fsm_busy && helper_valid) begin
                start_recon_r    <= 1'b1;
                enrolled_pending <= 1'b0;
                fsm_busy         <= 1'b1;
            end
            if (operation_done && !op_done_prev && !error_flag && enrolled_pending) begin
                stored_helper    <= helper_data_out;
                helper_valid     <= 1'b1;
                enrolled_pending <= 1'b0;
            end
        end
    end

    // PUF controller instantiation
    sram_puf_controller #(
        .N                  (256),
        .SECRET_BITS        (128),
        .USE_BCH            (1),
        .HELPER_BITS        (HELPER_BITS),
        .ENROLL_CYCLES      (10),
        .STABILITY_THRESHOLD(8)
    ) puf_ctrl (
        .clk               (clk),
        .rst               (sys_rst),
        .start_enroll      (start_enroll_r),
        .start_reconstruct (start_recon_r),
        .uart_rxd          (uart_rxd_stm32),
        .helper_data_in    (stored_helper),
        .operation_done    (operation_done),
        .key_out           (key_out),
        .helper_data_out   (helper_data_out),
        .error_flag        (error_flag),
        .fsm_state_out     (fsm_state)
    );

    // LEDs
    reg done_latch;
    reg [5:0] stage_latch;
    always @(posedge clk) begin
        if (sys_rst) begin
            done_latch  <= 1'b0;
            stage_latch <= 6'b0;
        end else begin
            if (operation_done && !error_flag) done_latch <= 1'b1;
            if (fsm_state == `STATE_ENROLL_POWERUP    || fsm_state == `STATE_RECONSTRUCT_POWERUP) stage_latch[0] <= 1'b1;
            if (fsm_state == `STATE_ENROLL_WAIT_READ  || fsm_state == `STATE_RECONSTRUCT_READ)    stage_latch[1] <= 1'b1;
            if (fsm_state == `STATE_ENROLL_ANALYZE    || fsm_state == `STATE_ENROLL_SELECT)       stage_latch[2] <= 1'b1;
            if (fsm_state == `STATE_ENROLL_EXTRACT    || fsm_state == `STATE_RECONSTRUCT_DECODE)  stage_latch[3] <= 1'b1;
            if (fsm_state == `STATE_KEYGEN)                                                        stage_latch[4] <= 1'b1;
            if (fsm_state == `STATE_LFSR)                                                          stage_latch[5] <= 1'b1;
        end
    end

    assign led[0]    = stage_latch[0];
    assign led[1]    = stage_latch[1];
    assign led[2]    = stage_latch[2];
    assign led[3]    = stage_latch[3];
    assign led[4]    = stage_latch[4];
    assign led[5]    = stage_latch[5];
    assign led[13:6] = key_out[7:0];
    assign led[14]   = error_flag;
    assign led[15]   = done_latch;

    // 7-Segment display - DEMO MODE
    reg [16:0] seg_cnt;
    reg [2:0]  digit_sel;
    reg        disp_frozen;
    reg [31:0] frozen_key;
    reg        op_done_d3;

    always @(posedge clk) begin
        if (sys_rst) begin
            seg_cnt     <= 0;
            digit_sel   <= 0;
            disp_frozen <= 1'b0;
            frozen_key  <= 32'b0;
            op_done_d3  <= 1'b0;
        end else begin
            op_done_d3 <= operation_done;
            if (pulse_enroll || pulse_recon)
                disp_frozen <= 1'b0;
            if (operation_done && !op_done_d3 && !error_flag) begin
                frozen_key  <= key_out[31:0];
                disp_frozen <= 1'b1;
            end
            if (seg_cnt == SEG_REFRESH - 1) begin
                seg_cnt   <= 0;
                digit_sel <= digit_sel + 1;
            end else
                seg_cnt <= seg_cnt + 1;
        end
    end

    // Nexys A7: an[7]=leftmost, an[0]=rightmost
    reg [3:0] active_nib;
    always @(*) begin
        if (!disp_frozen) active_nib = 4'b0000;
        else begin
            case (digit_sel)
                3'd7: active_nib = frozen_key[31:28];
                3'd6: active_nib = frozen_key[27:24];
                3'd5: active_nib = frozen_key[23:20];
                3'd4: active_nib = frozen_key[19:16];
                3'd3: active_nib = frozen_key[15:12];
                3'd2: active_nib = frozen_key[11:8];
                3'd1: active_nib = frozen_key[7:4];
                3'd0: active_nib = frozen_key[3:0];
                default: active_nib = 4'b0000;
            endcase
        end
    end

    function [6:0] hex_seg;
        input [3:0] h;
        begin
            case (h)
                4'h0: hex_seg = 7'b100_0000;
                4'h1: hex_seg = 7'b111_1001;
                4'h2: hex_seg = 7'b010_0100;
                4'h3: hex_seg = 7'b011_0000;
                4'h4: hex_seg = 7'b001_1001;
                4'h5: hex_seg = 7'b001_0010;
                4'h6: hex_seg = 7'b000_0010;
                4'h7: hex_seg = 7'b111_1000;
                4'h8: hex_seg = 7'b000_0000;
                4'h9: hex_seg = 7'b001_0000;
                4'hA: hex_seg = 7'b000_1000;
                4'hB: hex_seg = 7'b000_0011;
                4'hC: hex_seg = 7'b100_0110;
                4'hD: hex_seg = 7'b010_0001;
                4'hE: hex_seg = 7'b000_0110;
                4'hF: hex_seg = 7'b000_1110;
                default: hex_seg = 7'b111_1111;
            endcase
        end
    endfunction

    assign seg = hex_seg(active_nib);
    assign dp  = 1'b1;
    assign an  = disp_frozen ? ~(8'b0000_0001 << digit_sel) : 8'hFF;

    // UART TX - 115200 baud 8N1 - sends 64 hex chars + CRLF
    reg [255:0] key_latch;
    reg [6:0]   byte_idx;
    reg         sending;
    reg         op_done_d2;
    reg         tx_valid;
    reg [7:0]   tx_byte;
    reg         tx_busy;
    reg [9:0]   tx_shift;
    reg [9:0]   baud_cnt;
    reg [3:0]   tx_bit_cnt;

    // Nibble selector - purely combinational outside always block
    reg [3:0] tx_nib;
    always @(*) begin
        case (byte_idx)
            7'd0:  tx_nib = key_latch[255:252];
            7'd1:  tx_nib = key_latch[251:248];
            7'd2:  tx_nib = key_latch[247:244];
            7'd3:  tx_nib = key_latch[243:240];
            7'd4:  tx_nib = key_latch[239:236];
            7'd5:  tx_nib = key_latch[235:232];
            7'd6:  tx_nib = key_latch[231:228];
            7'd7:  tx_nib = key_latch[227:224];
            7'd8:  tx_nib = key_latch[223:220];
            7'd9:  tx_nib = key_latch[219:216];
            7'd10: tx_nib = key_latch[215:212];
            7'd11: tx_nib = key_latch[211:208];
            7'd12: tx_nib = key_latch[207:204];
            7'd13: tx_nib = key_latch[203:200];
            7'd14: tx_nib = key_latch[199:196];
            7'd15: tx_nib = key_latch[195:192];
            7'd16: tx_nib = key_latch[191:188];
            7'd17: tx_nib = key_latch[187:184];
            7'd18: tx_nib = key_latch[183:180];
            7'd19: tx_nib = key_latch[179:176];
            7'd20: tx_nib = key_latch[175:172];
            7'd21: tx_nib = key_latch[171:168];
            7'd22: tx_nib = key_latch[167:164];
            7'd23: tx_nib = key_latch[163:160];
            7'd24: tx_nib = key_latch[159:156];
            7'd25: tx_nib = key_latch[155:152];
            7'd26: tx_nib = key_latch[151:148];
            7'd27: tx_nib = key_latch[147:144];
            7'd28: tx_nib = key_latch[143:140];
            7'd29: tx_nib = key_latch[139:136];
            7'd30: tx_nib = key_latch[135:132];
            7'd31: tx_nib = key_latch[131:128];
            7'd32: tx_nib = key_latch[127:124];
            7'd33: tx_nib = key_latch[123:120];
            7'd34: tx_nib = key_latch[119:116];
            7'd35: tx_nib = key_latch[115:112];
            7'd36: tx_nib = key_latch[111:108];
            7'd37: tx_nib = key_latch[107:104];
            7'd38: tx_nib = key_latch[103:100];
            7'd39: tx_nib = key_latch[99:96];
            7'd40: tx_nib = key_latch[95:92];
            7'd41: tx_nib = key_latch[91:88];
            7'd42: tx_nib = key_latch[87:84];
            7'd43: tx_nib = key_latch[83:80];
            7'd44: tx_nib = key_latch[79:76];
            7'd45: tx_nib = key_latch[75:72];
            7'd46: tx_nib = key_latch[71:68];
            7'd47: tx_nib = key_latch[67:64];
            7'd48: tx_nib = key_latch[63:60];
            7'd49: tx_nib = key_latch[59:56];
            7'd50: tx_nib = key_latch[55:52];
            7'd51: tx_nib = key_latch[51:48];
            7'd52: tx_nib = key_latch[47:44];
            7'd53: tx_nib = key_latch[43:40];
            7'd54: tx_nib = key_latch[39:36];
            7'd55: tx_nib = key_latch[35:32];
            7'd56: tx_nib = key_latch[31:28];
            7'd57: tx_nib = key_latch[27:24];
            7'd58: tx_nib = key_latch[23:20];
            7'd59: tx_nib = key_latch[19:16];
            7'd60: tx_nib = key_latch[15:12];
            7'd61: tx_nib = key_latch[11:8];
            7'd62: tx_nib = key_latch[7:4];
            7'd63: tx_nib = key_latch[3:0];
            default: tx_nib = 4'h0;
        endcase
    end

    always @(posedge clk) begin
        op_done_d2 <= operation_done;
        if (sys_rst) begin
            sending   <= 1'b0;
            byte_idx  <= 0;
            key_latch <= 256'b0;
            tx_valid  <= 1'b0;
            tx_byte   <= 8'h00;
        end else begin
            tx_valid <= 1'b0;
            if (operation_done && !op_done_d2 && !error_flag) begin
                key_latch <= key_out;
                byte_idx  <= 0;
                sending   <= 1'b1;
            end
            if (sending && !tx_busy && !tx_valid) begin
                if (byte_idx < 64) begin
                    tx_byte  <= (tx_nib < 4'd10) ? (8'h30 + tx_nib)
                                                  : (8'h61 + tx_nib - 4'd10);
                    tx_valid <= 1'b1;
                    byte_idx <= byte_idx + 1;
                end else if (byte_idx == 64) begin
                    tx_byte  <= 8'h0D;
                    tx_valid <= 1'b1;
                    byte_idx <= byte_idx + 1;
                end else if (byte_idx == 65) begin
                    tx_byte  <= 8'h0A;
                    tx_valid <= 1'b1;
                    byte_idx <= byte_idx + 1;
                end else begin
                    sending <= 1'b0;
                end
            end
        end
    end

    // UART shift register
    always @(posedge clk) begin
        if (sys_rst) begin
            baud_cnt   <= 0;
            tx_bit_cnt <= 0;
            tx_busy    <= 1'b0;
            tx_shift   <= 10'h3FF;
        end else if (!tx_busy && tx_valid) begin
            tx_shift   <= {1'b1, tx_byte, 1'b0};
            tx_bit_cnt <= 0;
            baud_cnt   <= 0;
            tx_busy    <= 1'b1;
        end else if (tx_busy) begin
            if (baud_cnt == BAUD_DIV - 1) begin
                baud_cnt   <= 0;
                tx_shift   <= {1'b1, tx_shift[9:1]};
                tx_bit_cnt <= tx_bit_cnt + 1;
                if (tx_bit_cnt == 9)
                    tx_busy <= 1'b0;
            end else
                baud_cnt <= baud_cnt + 1;
        end
    end

    assign uart_txd = tx_shift[0];

endmodule
