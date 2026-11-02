`timescale 1ns/1ps
// Line quarantine and session/CRC gate. Only complete authenticated writes
// are replayed to the existing command parser. Legacy queries remain readable.
module uart_secure_ingress_retired(
    input wire clk, rst_n, tick_ms,
    input wire [7:0] rx_data,
    input wire rx_valid, rx_framing_error,
    output reg [7:0] parser_data,
    output reg parser_valid,
    output reg status_valid,
    output reg status_ok,
    output reg [31:0] session_id
);
    localparam integer MAX_LINE=40;
    reg [319:0] line_buf, previous_line, replay_buf;
    reg [5:0] line_len, previous_len;
    reg [5:0] replay_index, replay_end;
    reg replay_active, replay_eol, overflow, poisoned, discard_lf;
    reg session_valid, previous_valid;
    reg [15:0] last_seq;
    reg [5:0] idle_ms;
    reg [15:0] line_crc;
    reg [39:0] trailer;
    reg [31:0] frame_sid;
    reg [15:0] frame_seq;
    reg header_good, crc_good, hello_frame, query_frame, payload_allowed;
    integer i;

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
    function [7:0] ch;
        input integer n;
        begin ch=line_buf[n*8 +: 8]; end
    endfunction
    always @* begin
        header_good=(line_len>=20 && ch(0)=="@" && ch(9)==":" && ch(14)==":" && trailer[7:0]=="*");
        frame_sid=0;frame_seq=0;
        for(i=0;i<8;i=i+1) begin
            if(hex_value(ch(i+1))>15) header_good=0;
            frame_sid={frame_sid[27:0],nibble(ch(i+1))};
        end
        for(i=0;i<4;i=i+1) begin
            if(hex_value(ch(i+10))>15) header_good=0;
            frame_seq={frame_seq[11:0],nibble(ch(i+10))};
        end
        crc_good=header_good;
        for(i=1;i<5;i=i+1) if(hex_value(trailer[i*8 +:8])>15) crc_good=0;
        if({nibble(trailer[15:8]),nibble(trailer[23:16]),
            nibble(trailer[31:24]),nibble(trailer[39:32])}!=line_crc) crc_good=0;
        hello_frame=(line_len==25 && ch(15)=="H" && ch(16)=="E" && ch(17)=="L" && ch(18)=="L" && ch(19)=="O");
        payload_allowed=(ch(15)=="F" && ch(16)=="L" && ch(17)=="O" && ch(18)=="O" && ch(19)=="R" && ch(20)=="=") ||
                        (ch(15)=="A" && ch(16)=="L" && ch(17)=="E" && ch(18)=="R" && ch(19)=="T" && ch(20)=="=") ||
                        (ch(15)=="A" && ch(16)=="C" && ch(17)=="K" && ch(18)=="=") ||
                        (ch(15)=="S" && ch(16)=="U" && ch(17)=="B" && ch(18)=="=");
        query_frame=(line_len==4 && ch(0)=="S" && ch(1)=="U" && ch(2)=="B" && ch(3)=="?") ||
                    (line_len==5 && ((ch(0)=="B" && ch(1)=="O" && ch(2)=="O" && ch(3)=="T" && ch(4)=="?") ||
                                     (ch(0)=="E" && ch(1)=="L" && ch(2)=="E" && ch(3)=="V" && ch(4)=="?"))) ||
                    (line_len==7 && ch(0)=="R" && ch(1)=="E" && ch(2)=="S" && ch(3)=="C" && ch(4)=="U" && ch(5)=="E" && ch(6)=="?");
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            line_buf<=0;previous_line<=0;replay_buf<=0;line_len<=0;previous_len<=0;
            replay_index<=0;replay_end<=0;replay_active<=0;replay_eol<=0;
            overflow<=0;poisoned<=0;discard_lf<=0;session_valid<=0;previous_valid<=0;
            last_seq<=0;idle_ms<=0;line_crc<=16'hffff;trailer<=0;
            parser_data<=0;parser_valid<=0;status_valid<=0;status_ok<=0;session_id<=0;
        end else begin
            parser_valid<=0;status_valid<=0;
            if(replay_active) begin
                parser_valid<=1;
                if(replay_eol) begin
                    parser_data<=8'h0d;replay_active<=0;replay_eol<=0;
                end else begin
                    parser_data<=replay_buf[7:0];
                    replay_buf<=replay_buf>>8;
                    if(replay_index+1>=replay_end) replay_eol<=1;
                    else replay_index<=replay_index+1'b1;
                end
            end
            if(tick_ms && line_len!=0 && !poisoned) begin
                if(idle_ms>=49) begin poisoned<=1;line_len<=0;overflow<=0;end
                else idle_ms<=idle_ms+1'b1;
            end
            if(rx_framing_error) begin
                poisoned<=1;line_len<=0;overflow<=0;
            end
            if(rx_valid) begin
                idle_ms<=0;
                if(discard_lf && rx_data==8'h0a) discard_lf<=0;
                else if(rx_data==8'h0d || rx_data==8'h0a) begin
                    discard_lf<=rx_data==8'h0d;
                    if(!poisoned && !rx_framing_error && !overflow && !replay_active && line_len!=0) begin
                        if(query_frame) begin
                            replay_buf<=line_buf;replay_index<=0;replay_end<=line_len;replay_eol<=0;replay_active<=1;
                        end else if(crc_good && frame_seq==0 && hello_frame &&
                                    (!session_valid || frame_sid!=session_id)) begin
                            session_id<=frame_sid;session_valid<=1;last_seq<=0;previous_valid<=0;
                            status_valid<=1;status_ok<=1;
                        end else if(crc_good && frame_seq==0 && hello_frame && session_valid &&
                                    frame_sid==session_id && last_seq==0) begin
                            status_valid<=1;status_ok<=1;
                        end else if(crc_good && payload_allowed && line_len>20 && session_valid && frame_sid==session_id && frame_seq!=0 &&
                                    frame_seq==last_seq+1'b1 && last_seq!=16'hffff) begin
                            last_seq<=frame_seq;previous_line<=line_buf;previous_len<=line_len;previous_valid<=1;
                            replay_buf<=line_buf>>120;replay_index<=0;replay_end<=line_len-20;replay_eol<=0;replay_active<=1;
                        end else if(crc_good && session_valid && frame_sid==session_id && previous_valid &&
                                    frame_seq==last_seq && line_len==previous_len && line_buf==previous_line) begin
                            status_valid<=1;status_ok<=1;
                        end else begin status_valid<=1;status_ok<=0;end
                    end else if(poisoned || rx_framing_error || overflow) begin status_valid<=1;status_ok<=0;end
                    line_buf<=0;line_len<=0;line_crc<=16'hffff;trailer<=0;overflow<=0;poisoned<=0;
                end else begin
                    discard_lf<=0;
                    if(!poisoned && !rx_framing_error) begin
                        if(line_len<MAX_LINE) begin
                            line_buf[line_len*8 +:8]<=rx_data;
                            line_len<=line_len+1'b1;
                            if(line_len>=5) line_crc<=crc_byte(line_crc,trailer[7:0]);
                            trailer<={rx_data,trailer[39:8]};
                        end else overflow<=1;
                    end
                end
            end
        end
    end
endmodule
