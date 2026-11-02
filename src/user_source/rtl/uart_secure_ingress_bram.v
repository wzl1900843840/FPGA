`timescale 1ns/1ps
// Two 18-byte payload banks in one block RAM: current line and exact previous
// command. CRC excludes the five trailing *CCCC bytes. Replay starts only
// after the whole line passes validation; the physical UART byte interval is
// far longer than the 20-cycle replay.
module uart_secure_ingress_bram(
    input wire clk,rst_n,tick_ms,
    input wire [7:0] rx_data,
    input wire rx_valid,rx_framing_error,
    output reg [7:0] parser_data,
    output reg parser_valid,status_valid,status_ok,
    output reg [31:0] session_id
);
    reg [7:0] payload_ram[0:63] /* fehdl force_ram=1, ram_style="bram" */;
    reg [7:0] ram_out;
    reg [5:0] line_len;
    reg [4:0] payload_len,previous_len,replay_len;
    reg [4:0] replay_read_index,replay_send_index;
    localparam [2:0] Q_NONE=0,Q_BOOT=1,Q_ELEV=2,Q_SUB=3,Q_RESCUE=4;
    reg [2:0] query_kind;
    reg query_good;
    reg [4:0] prefix_match; // HELLO, FLOOR=, ALERT=, ACK=, SUB=
    reg [39:0] trailer;
    reg [15:0] line_crc,last_seq,frame_seq;
    reg [31:0] frame_sid;
    reg protected_line,header_good,overflow,payload_overflow,poisoned,discard_lf;
    reg session_valid,previous_valid,write_bank,previous_bank,replay_bank;
    reg replay_active,replay_prime,line_done,same_previous,compare_pending;
    reg [7:0] compare_byte;
    reg [5:0] idle_ms;
    wire incoming_char=rx_valid && rx_data!=8'h0d && rx_data!=8'h0a &&
        !poisoned && !rx_framing_error && !line_done && line_len<40;
    wire query_write=incoming_char && line_len<7 &&
        (line_len==0 ? rx_data!="@" : !protected_line);
    wire payload_write=incoming_char && protected_line && line_len>=20 && payload_len<18;
    wire [5:0] write_addr={write_bank,query_write ? line_len[4:0] : payload_len[4:0]};
    wire [7:0] write_data=query_write ? rx_data : trailer[7:0];
    wire [5:0] read_addr=replay_active ? {replay_bank,replay_read_index[4:0]} :
        {previous_bank,payload_len[4:0]};
    always @(posedge clk) begin
        if(query_write || payload_write)payload_ram[write_addr]<=write_data;
        ram_out<=payload_ram[read_addr];
    end
    wire [4:0] tail1=hex_value(trailer[15:8]);
    wire [4:0] tail2=hex_value(trailer[23:16]);
    wire [4:0] tail3=hex_value(trailer[31:24]);
    wire [4:0] tail4=hex_value(trailer[39:32]);
    wire crc_good=protected_line && header_good && line_len>=20 &&
        trailer[7:0]=="*" && tail1<16 && tail2<16 && tail3<16 && tail4<16 &&
        {tail1[3:0],tail2[3:0],tail3[3:0],tail4[3:0]}==line_crc;
    wire hello_frame=payload_len==5 && prefix_match[0];
    wire payload_allowed=(payload_len>=6 && (prefix_match[1] || prefix_match[2])) ||
                         (payload_len>=4 && (prefix_match[3] || prefix_match[4]));
    wire query_frame=!protected_line && query_good &&
        ((line_len==4 && query_kind==Q_SUB) ||
         (line_len==5 && (query_kind==Q_BOOT || query_kind==Q_ELEV)) ||
         (line_len==7 && query_kind==Q_RESCUE));
    function [7:0] query_expected;
        input [2:0] kind,pos;
        begin
            query_expected=0;
            case({kind,pos})
                {Q_BOOT,3'd1}:query_expected="O";
                {Q_BOOT,3'd2}:query_expected="O";
                {Q_BOOT,3'd3}:query_expected="T";
                {Q_BOOT,3'd4}:query_expected="?";
                {Q_ELEV,3'd1}:query_expected="L";
                {Q_ELEV,3'd2}:query_expected="E";
                {Q_ELEV,3'd3}:query_expected="V";
                {Q_ELEV,3'd4}:query_expected="?";
                {Q_SUB,3'd1}:query_expected="U";
                {Q_SUB,3'd2}:query_expected="B";
                {Q_SUB,3'd3}:query_expected="?";
                {Q_RESCUE,3'd1}:query_expected="E";
                {Q_RESCUE,3'd2}:query_expected="S";
                {Q_RESCUE,3'd3}:query_expected="C";
                {Q_RESCUE,3'd4}:query_expected="U";
                {Q_RESCUE,3'd5}:query_expected="E";
                {Q_RESCUE,3'd6}:query_expected="?";
                default:query_expected=0;
            endcase
        end
    endfunction
    function [7:0] prefix_expected;
        input [2:0] kind,pos;
        begin
            prefix_expected=0;
            case({kind,pos})
                6'd0:prefix_expected="H";6'd1:prefix_expected="E";
                6'd2:prefix_expected="L";6'd3:prefix_expected="L";
                6'd4:prefix_expected="O";
                6'd8:prefix_expected="F";6'd9:prefix_expected="L";
                6'd10:prefix_expected="O";6'd11:prefix_expected="O";
                6'd12:prefix_expected="R";6'd13:prefix_expected="=";
                6'd16:prefix_expected="A";6'd17:prefix_expected="L";
                6'd18:prefix_expected="E";6'd19:prefix_expected="R";
                6'd20:prefix_expected="T";6'd21:prefix_expected="=";
                6'd24:prefix_expected="A";6'd25:prefix_expected="C";
                6'd26:prefix_expected="K";6'd27:prefix_expected="=";
                6'd32:prefix_expected="S";6'd33:prefix_expected="U";
                6'd34:prefix_expected="B";6'd35:prefix_expected="=";
                default:prefix_expected=0;
            endcase
        end
    endfunction
    function [4:0] hex_value;
        input [7:0] c;
        begin
            if(c>="0" && c<="9") hex_value={1'b0,c-"0"};
            else if(c>="A" && c<="F") hex_value={1'b0,c-"A"+8'd10};
            else if(c>="a" && c<="f") hex_value={1'b0,c-"a"+8'd10};
            else hex_value=5'h10;
        end
    endfunction
    function [3:0] nibble;
        input [7:0] c;
        begin nibble=hex_value(c);end
    endfunction
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] c;
        reg [15:0] v;
        integer j;
        begin
            v=old_crc^{c,8'h00};
            for(j=0;j<8;j=j+1)v=v[15] ? (v<<1)^16'h1021 : (v<<1);
            crc_byte=v;
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            line_len<=0;payload_len<=0;previous_len<=0;replay_len<=0;
            replay_read_index<=0;replay_send_index<=0;query_kind<=Q_NONE;
            query_good<=0;prefix_match<=0;trailer<=0;
            line_crc<=16'hffff;last_seq<=0;frame_seq<=0;frame_sid<=0;
            protected_line<=0;header_good<=0;overflow<=0;payload_overflow<=0;
            poisoned<=0;discard_lf<=0;session_valid<=0;previous_valid<=0;
            write_bank<=0;previous_bank<=1;replay_bank<=0;replay_active<=0;
            replay_prime<=0;line_done<=0;same_previous<=1;compare_pending<=0;
            compare_byte<=0;idle_ms<=0;parser_data<=0;parser_valid<=0;
            status_valid<=0;status_ok<=0;session_id<=0;
        end else begin
            parser_valid<=0;status_valid<=0;
            if(compare_pending) begin
                if(compare_byte!=ram_out)same_previous<=0;
                compare_pending<=0;
            end
            if(replay_active) begin
                if(replay_prime) begin
                    replay_prime<=0;replay_read_index<=1;
                end else if(replay_send_index<replay_len) begin
                    parser_valid<=1;parser_data<=ram_out;
                    replay_send_index<=replay_send_index+1'b1;
                    replay_read_index<=replay_read_index+1'b1;
                end else begin
                    parser_valid<=1;parser_data<=8'h0d;replay_active<=0;
                end
            end
            if(line_done) begin
                line_done<=0;
                if(!poisoned && !overflow && !payload_overflow && !replay_active && line_len!=0) begin
                    if(query_frame) begin
                        replay_bank<=write_bank;replay_len<=line_len;
                        replay_send_index<=0;replay_read_index<=0;
                        replay_prime<=1;replay_active<=1;
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
                        last_seq<=frame_seq;previous_bank<=write_bank;write_bank<=~write_bank;
                        previous_len<=payload_len;previous_valid<=1;
                        replay_bank<=write_bank;replay_len<=payload_len;
                        replay_send_index<=0;replay_read_index<=0;
                        replay_prime<=1;replay_active<=1;
                    end else if(crc_good && session_valid && frame_sid==session_id &&
                                previous_valid && frame_seq==last_seq &&
                                payload_len==previous_len && same_previous) begin
                        status_valid<=1;status_ok<=1;
                    end else begin status_valid<=1;status_ok<=0;end
                end else if(poisoned || overflow || payload_overflow) begin
                    status_valid<=1;status_ok<=0;
                end
                line_len<=0;payload_len<=0;query_kind<=Q_NONE;query_good<=0;
                prefix_match<=0;trailer<=0;
                line_crc<=16'hffff;overflow<=0;payload_overflow<=0;poisoned<=0;
            end else begin
                if(tick_ms && line_len!=0 && !poisoned) begin
                    if(idle_ms>=49)begin poisoned<=1;line_len<=0;overflow<=0;end
                    else idle_ms<=idle_ms+1'b1;
                end
                if(rx_framing_error)begin poisoned<=1;line_len<=0;overflow<=0;end
                if(rx_valid)begin
                    idle_ms<=0;
                    if(discard_lf && rx_data==8'h0a)discard_lf<=0;
                    else if(rx_data==8'h0d || rx_data==8'h0a)begin
                        discard_lf<=rx_data==8'h0d;
                        line_done<=1;
                        if(rx_framing_error)poisoned<=1;
                    end else begin
                        discard_lf<=0;
                        if(!poisoned && !rx_framing_error)begin
                            if(line_len<40)begin
                                line_len<=line_len+1'b1;
                                trailer<={rx_data,trailer[39:8]};
                                if(line_len==0)begin
                                    protected_line<=rx_data=="@";header_good<=rx_data=="@";
                                    frame_sid<=0;frame_seq<=0;payload_len<=0;
                                    prefix_match<=5'b11111;
                                    query_good<=rx_data!="@";
                                    case(rx_data)
                                        "B":query_kind<=Q_BOOT;
                                        "E":query_kind<=Q_ELEV;
                                        "S":query_kind<=Q_SUB;
                                        "R":query_kind<=Q_RESCUE;
                                        default:begin query_kind<=Q_NONE;query_good<=0;end
                                    endcase
                                    payload_overflow<=0;same_previous<=1;
                                end else if(line_len>=1 && line_len<=8)begin
                                    if(hex_value(rx_data)>15)header_good<=0;
                                    frame_sid<={frame_sid[27:0],nibble(rx_data)};
                                end else if(line_len==9 || line_len==14)begin
                                    if(rx_data!=":")header_good<=0;
                                end else if(line_len>=10 && line_len<=13)begin
                                    if(hex_value(rx_data)>15)header_good<=0;
                                    frame_seq<={frame_seq[11:0],nibble(rx_data)};
                                end
                                if(line_len!=0 && line_len<7)
                                    query_good<=query_good && rx_data==query_expected(query_kind,line_len[2:0]);
                                if(line_len>=5)begin
                                    line_crc<=crc_byte(line_crc,trailer[7:0]);
                                    if(protected_line && line_len>=20)begin
                                        if(payload_len<18)begin
                                            if(payload_len<5)prefix_match[0]<=prefix_match[0] &&
                                                trailer[7:0]==prefix_expected(3'd0,payload_len[2:0]);
                                            else prefix_match[0]<=0;
                                            if(payload_len<6)begin
                                                prefix_match[1]<=prefix_match[1] &&
                                                    trailer[7:0]==prefix_expected(3'd1,payload_len[2:0]);
                                                prefix_match[2]<=prefix_match[2] &&
                                                    trailer[7:0]==prefix_expected(3'd2,payload_len[2:0]);
                                            end
                                            if(payload_len<4)begin
                                                prefix_match[3]<=prefix_match[3] &&
                                                    trailer[7:0]==prefix_expected(3'd3,payload_len[2:0]);
                                                prefix_match[4]<=prefix_match[4] &&
                                                    trailer[7:0]==prefix_expected(3'd4,payload_len[2:0]);
                                            end
                                            payload_len<=payload_len+1'b1;
                                            compare_byte<=trailer[7:0];compare_pending<=1;
                                        end else payload_overflow<=1;
                                    end
                                end
                            end else overflow<=1;
                        end
                    end
                end
            end
        end
    end
endmodule
