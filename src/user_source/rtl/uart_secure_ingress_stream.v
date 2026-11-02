`timescale 1ns/1ps
// Streaming authenticated-line gate. The five-byte tail delay excludes
// *CCCC from CRC and payload storage without a second full-line RAM.
module uart_secure_ingress(
    input wire clk,rst_n,tick_ms,
    input wire [7:0] rx_data,
    input wire rx_valid,rx_framing_error,
    output reg [7:0] parser_data,
    output reg parser_valid,status_valid,status_ok,
    output reg [31:0] session_id
);
    reg [143:0] payload_buf,previous_payload;
    reg [5:0] line_len,payload_len,previous_len,replay_len,replay_index;
    reg [39:0] trailer;
    reg [15:0] line_crc,last_seq;
    reg [31:0] frame_sid;
    reg [15:0] frame_seq;
    reg protected_line,header_good,overflow,payload_overflow,poisoned,discard_lf;
    reg session_valid,previous_valid,replay_active,replay_eol;
    reg [5:0] idle_ms;
    wire [4:0] tail1=hex_value(trailer[15:8]);
    wire [4:0] tail2=hex_value(trailer[23:16]);
    wire [4:0] tail3=hex_value(trailer[31:24]);
    wire [4:0] tail4=hex_value(trailer[39:32]);
    wire crc_good=protected_line && header_good && line_len>=20 &&
        trailer[7:0]=="*" && tail1<16 && tail2<16 && tail3<16 && tail4<16 &&
        {tail1[3:0],tail2[3:0],tail3[3:0],tail4[3:0]}==line_crc;
    wire hello_frame=payload_len==5 && payload_buf[39:0]=={"O","L","L","E","H"};
    wire payload_allowed=(payload_buf[47:0]=={"=","R","O","O","L","F"}) ||
        (payload_buf[47:0]=={"=","T","R","E","L","A"}) ||
        (payload_buf[31:0]=={"=","K","C","A"}) ||
        (payload_buf[31:0]=={"=","B","U","S"});
    wire query_frame=!protected_line &&
        ((line_len==4 && payload_buf[31:0]=={"?","B","U","S"}) ||
         (line_len==5 && (payload_buf[39:0]=={"?","T","O","O","B"} ||
                          payload_buf[39:0]=={"?","V","E","L","E"})) ||
         (line_len==7 && payload_buf[55:0]=={"?","E","U","C","S","E","R"}));

    function [4:0] hex_value;
        input [7:0] c;
        begin
            if(c>="0" && c<="9") hex_value={1'b0,c-"0"};
            else if(c>="A" && c<="F") hex_value={1'b0,c-"A"+8'd10};
            else if(c>="a" && c<="f") hex_value={1'b0,c-"a"+8'd10};
            else hex_value=5'h10;
        end
    endfunction
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] c;
        reg [15:0] v;
        integer j;
        begin
            v=old_crc^{c,8'h00};
            for(j=0;j<8;j=j+1) v=v[15] ? (v<<1)^16'h1021 : (v<<1);
            crc_byte=v;
        end
    endfunction
    function [3:0] nibble;
        input [7:0] c;
        begin nibble=hex_value(c); end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            payload_buf<=0;previous_payload<=0;
            line_len<=0;payload_len<=0;previous_len<=0;replay_len<=0;replay_index<=0;
            trailer<=0;line_crc<=16'hffff;last_seq<=0;frame_sid<=0;frame_seq<=0;
            protected_line<=0;header_good<=0;overflow<=0;payload_overflow<=0;poisoned<=0;discard_lf<=0;
            session_valid<=0;previous_valid<=0;replay_active<=0;replay_eol<=0;idle_ms<=0;
            parser_data<=0;parser_valid<=0;status_valid<=0;status_ok<=0;session_id<=0;
        end else begin
            parser_valid<=0;status_valid<=0;
            if(replay_active) begin
                parser_valid<=1;
                if(replay_eol) begin
                    parser_data<=8'h0d;replay_active<=0;replay_eol<=0;
                end else begin
                    parser_data<=payload_buf[replay_index*8 +:8];
                    if(replay_index+1>=replay_len) replay_eol<=1;
                    else replay_index<=replay_index+1'b1;
                end
            end
            if(tick_ms && line_len!=0 && !poisoned) begin
                if(idle_ms>=49) begin poisoned<=1;line_len<=0;overflow<=0;end
                else idle_ms<=idle_ms+1'b1;
            end
            if(rx_framing_error) begin poisoned<=1;line_len<=0;overflow<=0;end
            if(rx_valid) begin
                idle_ms<=0;
                if(discard_lf && rx_data==8'h0a) discard_lf<=0;
                else if(rx_data==8'h0d || rx_data==8'h0a) begin
                    discard_lf<=rx_data==8'h0d;
                    if(!poisoned && !rx_framing_error && !overflow && !payload_overflow && !replay_active && line_len!=0) begin
                        if(query_frame) begin
                            replay_len<=line_len;replay_index<=0;
                            replay_eol<=0;replay_active<=1;
                        end else if(crc_good && frame_seq==0 && hello_frame &&
                                    (!session_valid || frame_sid!=session_id)) begin
                            session_id<=frame_sid;session_valid<=1;last_seq<=0;previous_valid<=0;
                            status_valid<=1;status_ok<=1;
                        end else if(crc_good && frame_seq==0 && hello_frame && session_valid &&
                                    frame_sid==session_id && last_seq==0) begin
                            status_valid<=1;status_ok<=1;
                        end else if(crc_good && payload_allowed && payload_len!=0 &&
                                    session_valid && frame_sid==session_id && frame_seq!=0 &&
                                    frame_seq==last_seq+1'b1 && last_seq!=16'hffff) begin
                            last_seq<=frame_seq;previous_payload<=payload_buf;
                            previous_len<=payload_len;previous_valid<=1;
                            replay_len<=payload_len;replay_index<=0;
                            replay_eol<=0;replay_active<=1;
                        end else if(crc_good && session_valid && frame_sid==session_id &&
                                    previous_valid && frame_seq==last_seq &&
                                    payload_len==previous_len && payload_buf==previous_payload) begin
                            status_valid<=1;status_ok<=1;
                        end else begin status_valid<=1;status_ok<=0;end
                    end else if(poisoned || rx_framing_error || overflow || payload_overflow) begin
                        status_valid<=1;status_ok<=0;
                    end
                    line_len<=0;payload_len<=0;trailer<=0;
                    line_crc<=16'hffff;overflow<=0;payload_overflow<=0;poisoned<=0;
                end else begin
                    discard_lf<=0;
                    if(!poisoned && !rx_framing_error) begin
                        if(line_len<40) begin
                            line_len<=line_len+1'b1;
                            trailer<={rx_data,trailer[39:8]};
                            if(line_len==0) begin
                                protected_line<=rx_data=="@";header_good<=rx_data=="@";
                                frame_sid<=0;frame_seq<=0;payload_buf<=0;payload_len<=0;payload_overflow<=0;
                            end else if(line_len>=1 && line_len<=8) begin
                                if(hex_value(rx_data)>15)header_good<=0;
                                frame_sid<={frame_sid[27:0],nibble(rx_data)};
                            end else if(line_len==9 || line_len==14) begin
                                if(rx_data!=":")header_good<=0;
                            end else if(line_len>=10 && line_len<=13) begin
                                if(hex_value(rx_data)>15)header_good<=0;
                                frame_seq<={frame_seq[11:0],nibble(rx_data)};
                            end
                            if(line_len<7 && (line_len==0 || !protected_line))
                                payload_buf[line_len*8 +:8]<=rx_data;
                            if(line_len>=5) begin
                                line_crc<=crc_byte(line_crc,trailer[7:0]);
                                if(protected_line && line_len>=20) begin
                                    if(payload_len<18) begin
                                        payload_buf[payload_len*8 +:8]<=trailer[7:0];
                                        payload_len<=payload_len+1'b1;
                                    end else payload_overflow<=1;
                                end
                            end
                        end else overflow<=1;
                    end
                end
            end
        end
    end
endmodule
