`timescale 1ns/1ps
// One automatic rebuild per external reset/manual reload. The display confirms
// its frame-stable fallback before every shared-memory reset. All memory clients
// and the vendor controller share this reset; HDMI timing/UART/UI do not.
module media_recovery_manager #(parameter integer RESET_MS=2,
 parameter integer STARTUP_TIMEOUT_MS=180000)(
 input wire clk,rst_n,tick_ms,manual_request,transaction_fault,boot_ready,display_ack,
 output wire media_reset_n,output wire display_fallback,output wire busy,
 output reg failed,output reg [7:0] retries);
 localparam RUN=0,SHOW=1,RESET=2,LOAD=3,STOP=4;
 reg [2:0] state;reg [17:0] timeout_ms;reg [7:0] hold_ms;reg auto_used;
 assign display_fallback=state!=RUN || failed;
 assign media_reset_n=state!=RESET && state!=STOP;
 // STOP is an operable fallback: UI must allow a fresh confirmed reload.
 assign busy=state!=RUN && state!=STOP;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=RUN;timeout_ms<=0;hold_ms<=0;auto_used<=0;failed<=0;retries<=0;end
  else begin
   if(manual_request && state!=SHOW && state!=RESET && state!=LOAD)begin
    state<=SHOW;auto_used<=0;failed<=0;timeout_ms<=0;
   end else case(state)
    RUN:begin
     if(tick_ms && !boot_ready && timeout_ms<STARTUP_TIMEOUT_MS)timeout_ms<=timeout_ms+1'b1;
     if(boot_ready)timeout_ms<=0;
     if(transaction_fault || timeout_ms>=STARTUP_TIMEOUT_MS)begin
      state<=SHOW;failed<=auto_used;timeout_ms<=0;
     end
    end
    SHOW:if(display_ack)begin
     if(failed)state<=STOP;
     else begin state<=RESET;hold_ms<=0;end
    end
    RESET:if(tick_ms)begin
     if(hold_ms>=RESET_MS-1)begin state<=LOAD;timeout_ms<=0;auto_used<=1;if(retries!=255)retries<=retries+1'b1;end
     else hold_ms<=hold_ms+1'b1;
    end
    LOAD:begin
     if(tick_ms && timeout_ms<STARTUP_TIMEOUT_MS)timeout_ms<=timeout_ms+1'b1;
     if(transaction_fault || timeout_ms>=STARTUP_TIMEOUT_MS)begin failed<=1;state<=SHOW;end
     else if(boot_ready)begin state<=RUN;timeout_ms<=0;end
    end
    STOP:failed<=1;
    default:state<=STOP;
   endcase
  end
 end
endmodule
