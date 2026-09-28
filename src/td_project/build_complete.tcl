# 由 td_commands_prompt.exe 调用；所有输出写在当前工程中。
cd [file dirname [info script]]
file mkdir build_complete
import_device eagle_s20.db -package EG4S20BG256
open_project lab_ex5_i2s_v1.0.al
elaborate -top top
read_adc ../user_source/constraints_source/pin.adc
read_sdc ../user_source/constraints_source/timing.sdc
optimize_rtl
report_area -file build_complete/complete_rtl.area
export_db build_complete/complete_rtl.db
optimize_gate -packarea build_complete/complete_gate.area
legalize_phy_inst
update_timing
report_timing_status -file build_complete/complete_gate.ts
report_timing_summary -file build_complete/complete_gate.timing
export_db build_complete/complete_gate.db
exit
