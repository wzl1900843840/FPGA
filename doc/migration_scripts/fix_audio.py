from pathlib import Path
R=Path(__file__).resolve().parents[1]/'src/user_source/rtl'
p=R/'wav_stream_player.v'
t=p.read_text(encoding='utf-8-sig');t=t[:t.index('    // ---------------- circular buffer')]
t+='''    // 二进制指针多一位表示回卷；Gray 编码必须在源域生成。
    localparam integer DEPTH=1<<ADDR_WIDTH;
    reg [15:0] buffer [0:DEPTH-1];
    reg [ADDR_WIDTH:0] wr_ptr,rd_ptr,wr_gray,rd_gray;
    reg [ADDR_WIDTH:0] rd_gray_sync1,rd_gray_sync2,wr_gray_sync1,wr_gray_sync2;
    reg play_sync1,play_sync2,end_sync1,end_sync2;
    reg [31:0] sectors_read;
    reg [7:0] low_byte;
    reg [2:0] state;
    reg started;
    localparam IDLE=0,WAIT_SPACE=1,REQUEST=2,FILL=3,FINISHED=4;
    function [ADDR_WIDTH:0] binary;
        input [ADDR_WIDTH:0] gray;
        integer i;
        begin
            binary[ADDR_WIDTH]=gray[ADDR_WIDTH];
            for(i=ADDR_WIDTH-1;i>=0;i=i-1) binary[i]=binary[i+1]^gray[i];
        end
    endfunction
    wire [ADDR_WIDTH:0] used_wr=wr_ptr-binary(rd_gray_sync2);
    wire [ADDR_WIDTH:0] used_rd=binary(wr_gray_sync2)-rd_ptr;
    assign sd_req=state==REQUEST;
    // 状态输出属于读域；必须等尾部样本（包括 valid 尚未握手的数据）排空。
    assign stream_end=play_sync2 && end_sync2 && used_rd==0 && !sample_valid;
    assign stream_active=play_sync2 && !stream_end;
    assign buffer_low=used_rd < DEPTH/4;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if(!wr_rst_n) begin
            state<=IDLE;wr_ptr<=0;wr_gray<=0;rd_gray_sync1<=0;rd_gray_sync2<=0;
            sectors_read<=0;sd_lba<=0;low_byte<=0;
        end else begin
            rd_gray_sync1<=rd_gray;rd_gray_sync2<=rd_gray_sync1;
            if(!play_enable && state!=FILL && state!=REQUEST) begin
                state<=IDLE;wr_ptr<=0;wr_gray<=0;sectors_read<=0;
            end else case(state)
                IDLE: if(play_enable && start_lba!=0 && total_sectors!=0) begin
                    sd_lba<=start_lba;state<=WAIT_SPACE;
                end
                WAIT_SPACE: if(used_wr<=DEPTH-SAMPLES_PER_SECTOR && !sd_busy)
                    state<=REQUEST;
                REQUEST: if(!sd_busy) state<=FILL;
                FILL: begin
                    if(sd_valid && play_enable) begin
                        if(!sd_byte_index[0]) low_byte<=sd_byte;
                        else if(used_wr<DEPTH) begin
                            buffer[wr_ptr[ADDR_WIDTH-1:0]]<={sd_byte,low_byte};
                            wr_ptr<=wr_ptr+1'b1;
                            wr_gray<=((wr_ptr+1'b1)>>1)^(wr_ptr+1'b1);
                        end
                    end
                    if(sd_done) begin
                        sectors_read<=sectors_read+1'b1;
                        sd_lba<=sd_lba+1'b1;
                        state<=(sd_error!=0 || sectors_read+1>=total_sectors || !play_enable)
                            ? FINISHED : WAIT_SPACE;
                    end
                end
                FINISHED: ;
                default: state<=IDLE;
            endcase
        end
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if(!rd_rst_n) begin
            rd_ptr<=0;rd_gray<=0;wr_gray_sync1<=0;wr_gray_sync2<=0;
            play_sync1<=0;play_sync2<=0;end_sync1<=0;end_sync2<=0;
            sample_valid<=0;sample_out<=0;sample_counter<=0;started<=0;
        end else begin
            wr_gray_sync1<=wr_gray;wr_gray_sync2<=wr_gray_sync1;
            play_sync1<=play_enable;play_sync2<=play_sync1;
            end_sync1<=state==FINISHED;end_sync2<=end_sync1;
            if(sample_valid && sample_ready) sample_valid<=0;
            if(!play_sync2) begin
                rd_ptr<=0;rd_gray<=0;sample_valid<=0;sample_counter<=0;started<=0;
            end else begin
                if(used_rd>=SAMPLES_PER_SECTOR || end_sync2) started<=1;
                if(sample_tick && (!sample_valid || sample_ready) && !stream_end) begin
                    sample_valid<=1;
                    sample_out<=0;
                    if(started && used_rd!=0) begin
                        sample_out<=buffer[rd_ptr[ADDR_WIDTH-1:0]];
                        rd_ptr<=rd_ptr+1'b1;
                        rd_gray<=((rd_ptr+1'b1)>>1)^(rd_ptr+1'b1);
                        sample_counter<=sample_counter+1'b1;
                    end
                end
            end
        end
    end
endmodule
'''
p.write_text(t,encoding='utf-8')
# 初始化时 SPI <= 400 kHz，读数据仍使用高速分频。
p=R/'sd_media_service.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('parameter integer SPI_CLK_DIV = 4,','parameter integer SPI_CLK_DIV = 4,\n    parameter integer INIT_SPI_CLK_DIV = 64,')
t=t.replace('.SPI_CLK_DIV(SPI_CLK_DIV), .POWER_UP_BYTES','.SPI_CLK_DIV(INIT_SPI_CLK_DIV), .POWER_UP_BYTES')
p.write_text(t,encoding='utf-8')
# 复用 SD 引擎，在图像 ingest 结束后允许 PCM 独占；不在扇区中途切换所有者。
p=R/'media_storage_ingest_top.v';t=p.read_text(encoding='utf-8-sig')
t=t.replace('input  wire                  sd_miso\n','''input  wire                  sd_miso,
    input  wire                  audio_owner,
    input  wire                  audio_req,
    input  wire [31:0]           audio_lba,
    output wire                 audio_busy, audio_done, audio_valid,
    output wire [7:0]           audio_byte, audio_error,
    output wire [8:0]           audio_byte_index
''')
t=t.replace('    sd_media_service #','''    assign audio_busy=service_sector_busy || !audio_owner;
    assign audio_done=service_sector_done && audio_owner;
    assign audio_valid=service_sector_valid && audio_owner;
    assign audio_byte=service_sector_byte;
    assign audio_byte_index=service_sector_byte_index;
    assign audio_error=service_sector_error;
    sd_media_service #''')
t=t.replace('.sector_req(service_sector_req), .sector_lba(service_sector_lba)', '.sector_req(audio_owner ? audio_req : service_sector_req),\n        .sector_lba(audio_owner ? audio_lba : service_sector_lba)')
p.write_text(t,encoding='utf-8')
