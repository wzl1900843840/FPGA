cd [file dirname [info script]]
import_device eagle_s20.db -package EG4S20BG256
open_project lab_ex5_i2s_v1.0.al -noanalyze
import_db build_complete/complete_gate.db
place
update_timing -mode manhattan
report_timing_summary -file build_complete/complete_place.timing
export_db build_complete/complete_place.db
route
update_timing -mode final
report_area -io_info -file build_complete/complete_phy.area
report_timing_status -file build_complete/complete_phy.ts
report_timing_summary -file build_complete/complete_pr.timing
report_timing_exception -file build_complete/complete_exception.timing
export_db build_complete/complete_pr.db
bitgen -bit build_complete/lab_ex4_tf_complete.bit
exit
