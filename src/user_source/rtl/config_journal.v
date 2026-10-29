`timescale 1ns/1ps

module config_journal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        slot0_present,
    input  wire [31:0] slot0_version,
    input  wire [31:0] slot0_period,
    input  wire [7:0]  slot0_volume,
    input  wire [7:0]  slot0_mode,
    input  wire [15:0] slot0_crc,
    input  wire        slot1_present,
    input  wire [31:0] slot1_version,
    input  wire [31:0] slot1_period,
    input  wire [7:0]  slot1_volume,
    input  wire [7:0]  slot1_mode,
    input  wire [15:0] slot1_crc,
    output reg         load_done,
    output reg         config_valid,
    output reg  [31:0] active_version,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    output reg         active_slot,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         record_ready,
    output reg         target_slot,
    output reg  [31:0] record_version,
    output reg  [31:0] record_period,
    output reg  [7:0]  record_volume,
    output reg  [7:0]  record_mode,
    output reg  [15:0] record_crc
);
    // One byte-wide CRC engine shared by both load slots and save.
    // Record ordering and CRC16-CCITT (init FFFF, MSB first) are unchanged.
    // The parent serializes requests and waits for load_done/record_ready.
    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] payload;
        integer i;
        reg [15:0] crc;
        begin
            crc=crc_in;
            for(i=7;i>=0;i=i-1)
                crc=(crc[15]^payload[i]) ? ({crc[14:0],1'b0}^16'h1021) : {crc[14:0],1'b0};
            crc16_byte=crc;
        end
    endfunction
    function version_newer;
        input [31:0] candidate;
        input [31:0] reference;
        reg [31:0] delta;
        begin
            delta = candidate - reference;
            version_newer = (candidate != reference) && !delta[31];
        end
    endfunction


    localparam [2:0] ST_IDLE=0, ST_LOAD0=1, ST_LOAD1=2, ST_CHOOSE=3, ST_SAVE=4;
    reg [2:0] state;
    reg [3:0] crc_byte_index;
    reg [15:0] crc_accumulator;
    reg [79:0] slot1_payload_q;
    // Reuse the record registers for slot0's load snapshot. Do not shift an
    // extra 80-bit copy merely to serialize ten bytes.
    wire [79:0] crc_source=state==ST_LOAD1 ? slot1_payload_q :
                             {record_version,record_period,record_volume,record_mode};
    reg [7:0] crc_data;
    always @* begin
        case(crc_byte_index)
            0:crc_data=crc_source[79:72];1:crc_data=crc_source[71:64];
            2:crc_data=crc_source[63:56];3:crc_data=crc_source[55:48];
            4:crc_data=crc_source[47:40];5:crc_data=crc_source[39:32];
            6:crc_data=crc_source[31:24];7:crc_data=crc_source[23:16];
            8:crc_data=crc_source[15:8];default:crc_data=crc_source[7:0];
        endcase
    end
    wire [15:0] crc_next=crc16_byte(crc_accumulator,crc_data);
    reg slot0_present_q,slot1_present_q;
    reg [15:0] slot0_crc_q,slot1_crc_q;
    reg slot0_good,slot1_good;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            load_done<=0;config_valid<=0;active_version<=0;active_period<=0;
            active_volume<=0;active_mode<=0;active_slot<=0;
            record_ready<=0;target_slot<=0;record_version<=0;record_period<=0;
            record_volume<=0;record_mode<=0;record_crc<=0;
            state<=ST_IDLE;crc_byte_index<=0;crc_accumulator<=16'hffff;
            slot0_present_q<=0;slot1_present_q<=0;slot1_payload_q<=0;
            slot0_crc_q<=0;slot1_crc_q<=0;slot0_good<=0;slot1_good<=0;
        end else begin
            load_done<=0;record_ready<=0;
            case(state)
                ST_IDLE: begin
                    if(load_start) begin
                        slot0_present_q<=slot0_present;slot1_present_q<=slot1_present;
                        {record_version,record_period,record_volume,record_mode}<={slot0_version,slot0_period,slot0_volume,slot0_mode};
                        slot1_payload_q<={slot1_version,slot1_period,slot1_volume,slot1_mode};
                        slot0_crc_q<=slot0_crc;slot1_crc_q<=slot1_crc;
                        crc_accumulator<=16'hffff;crc_byte_index<=0;state<=ST_LOAD0;
                    end else if(save_start) begin
                        target_slot<=config_valid ? ~active_slot : 1'b0;
                        record_version<=active_version+1'b1;record_period<=save_period;
                        record_volume<=save_volume;record_mode<=save_mode;
                        crc_accumulator<=16'hffff;crc_byte_index<=0;state<=ST_SAVE;
                    end
                end
                ST_LOAD0,ST_LOAD1,ST_SAVE: begin
                    crc_accumulator<=crc_next;
                    if(crc_byte_index==9) begin
                        crc_byte_index<=0;
                        case(state)
                            ST_LOAD0: begin
                                slot0_good<=slot0_present_q && slot0_crc_q==crc_next;
                                crc_accumulator<=16'hffff;
                                state<=ST_LOAD1;
                            end
                            ST_LOAD1: begin
                                slot1_good<=slot1_present_q && slot1_crc_q==crc_next;
                                state<=ST_CHOOSE;
                            end
                            default: begin
                                record_crc<=crc_next;record_ready<=1;state<=ST_IDLE;
                            end
                        endcase
                    end else crc_byte_index<=crc_byte_index+1'b1;
                end
                ST_CHOOSE: begin
                    load_done<=1;state<=ST_IDLE;
                    if(slot0_good && (!slot1_good || !version_newer(slot1_payload_q[79:48],record_version))) begin
                        config_valid<=1;active_slot<=0;
                        {active_version,active_period,active_volume,active_mode}<={record_version,record_period,record_volume,record_mode};
                    end else if(slot1_good) begin
                        config_valid<=1;active_slot<=1;
                        {active_version,active_period,active_volume,active_mode}<=slot1_payload_q;
                    end else begin
                        config_valid<=0;active_slot<=0;active_version<=0;active_period<=0;
                        active_volume<=0;active_mode<=0;
                    end
                end
                default: state<=ST_IDLE;
            endcase
        end
    end
endmodule
