`timescale 1ns/1ps
module tb_boot_mute;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,update=0,save=0,flash_fail=0,key=1,boot_guard=1;
    reg [31:0] period=12345;
    reg [7:0] vol=255,mode=1;
    wire ready,ld,sd,fatal,cs,sclk,mosi,model_miso;
    wire [7:0] lv,lm,err,mv;
    wire [31:0] lp,mp;
    wire mu;
    player_config_persistence #(.DEFAULT_VOLUME(0),.RESTORE_VOLUME_ON_BOOT(0),
        .SPI_CLK_DIV(2),.STARTUP_CYCLES(4),.WAKE_CYCLES(4),.POLL_INTERVAL_CYCLES(4)) dut(
        .clk(clk),.rst_n(rst),.cfg_update_valid(update || mu),
        .cfg_period_ms(mu ? mp : period),.cfg_volume(mu ? mv : vol),.cfg_mode(mode),.save_request(save),
        .service_ready(ready),.load_done(ld),.save_done(sd),.fatal_error(fatal),.error_code(err),
        .live_period_ms(lp),.live_volume(lv),.live_mode(lm),
        .flash_miso(flash_fail ? 1'b1 : model_miso),.flash_cs_n(cs),.flash_sclk(sclk),.flash_mosi(mosi));
    // Disconnect the chip as well as pulling MISO up for the absent-Flash case.
    spi_flash_model flash(clk,cs || flash_fail,sclk,mosi,model_miso);
    param_menu_controller #(.CLKS_PER_MS(1),.DEBOUNCE_MS(2),.LONG_HOLD_MS(100)) menu(
        .clk(clk),.rst_n(rst),.key4_n(key),.service_ready(ready),.live_volume(lv),.live_period_ms(lp),
        .cfg_update_valid(mu),.cfg_period_ms(mp),.cfg_volume(mv));
    reg [5:0] count=0;
    always @(posedge clk) if(!rst) count<=0;else count<=count+1'b1;
    wire [7:0] pixel_volume;
    frame_config_cdc #(.WIDTH(8),.RESET_VALUE(8'd0)) cdc(
        .src_clk(clk),.src_rst_n(rst),.src_data(lv),.dst_clk(clk),.dst_rst_n(rst),
        .frame_start(count==0),.dst_data(pixel_volume));
    always @(negedge clk) if(rst && boot_guard && (lv!==0 || pixel_volume!==0))
        $fatal(1,"boot gain escaped zero live=%d pixel=%d",lv,pixel_volume);
    task reboot;begin
        @(negedge clk);rst=0;boot_guard=1;
        repeat(4)@(negedge clk);rst=1;wait(ld || fatal);repeat(128)@(negedge clk);
        if(lv!=0 || pixel_volume!=0)$fatal(1,"reboot mute");
    end endtask
    task update_save;begin
        boot_guard=0;
        @(negedge clk);update=1;@(negedge clk);update=0;
        repeat(4)@(negedge clk);save=1;@(negedge clk);save=0;
        wait(sd || fatal);repeat(128)@(negedge clk);
        if(fatal || lv!=vol || pixel_volume!=vol || lp!=period || lm!=mode)
            $fatal(1,"runtime update/save/readback %h %d",err,lv);
    end endtask
    initial begin
        #12;rst=1;wait(ld || fatal);repeat(128)@(negedge clk);
        if(fatal || lv!=0 || lp!=5000 || lm!=0)$fatal(1,"blank Flash");
        boot_guard=0;key=0;repeat(12)@(negedge clk);key=1;repeat(24)@(negedge clk);
        if(lv!=64)$fatal(1,"first volume press did not select 64");
        update_save; // Save maximum volume and a non-preset period.
        reboot;if(fatal || lp!=12345 || lm!=1)$fatal(1,"saved period/mode not restored");
        // K1-equivalent reset must remain silent even when both slots contain 255.
        period=30000;update_save;reboot;
        if(fatal || lp!=30000 || lm!=1)$fatal(1,"second slot restoration");
        flash.mem[4096]=flash.mem[4096]^8'h80;reboot;
        if(fatal || lp!=12345 || lm!=1)$fatal(1,"corrupt-slot fallback");
        flash.mem[0]=flash.mem[0]^8'h80;reboot;
        if(fatal || lp!=5000 || lm!=0)$fatal(1,"both corrupt default");
        flash_fail=1;reboot;
        if(!fatal || ready)$fatal(1,"missing Flash not rejected");
        // Flash failure still permits RAM adjustments; boot muting is not a lock.
        boot_guard=0;vol=64;period=10000;mode=0;
        update=1;@(negedge clk);update=0;repeat(128)@(negedge clk);
        if(lv!=64 || pixel_volume!=64 || lp!=10000)$fatal(1,"RAM adjustment after Flash error");
        $display("PASS boot mute: blank, saved 255, K1 reset, corrupt slots, Flash failure, first key=64, runtime save/readback, period/mode, pixel CDC");
        $finish;
    end
    initial begin #20000000;$fatal(1,"boot mute watchdog");end
endmodule
