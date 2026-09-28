`timescale 1ns/1ps
// Icarus-compatible truth-table model of the one vendor LUT used by FIFO RTL.
// Equivalent to TD sim_release/common/al_map_lut.v AL_MAP_LUT1 (no timing claims).
module AL_MAP_LUT1 #(parameter INIT=2'b00)(output wire o,input wire a);
assign o=(INIT[0]==INIT[1])?INIT[0]:INIT[a];
endmodule
