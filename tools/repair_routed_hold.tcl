# Run from an isolated phy_1 directory after the complete routed flow.
# TD's native fix_hold changes physical routing, not RTL or timing constraints.
source settings.cfg
import_device $device_name -package $package_name
open_project ${prj_name}.prj -noanalyze
import_db ${prj_name}_pr.db
report_param -stage route -detail -file hold_parameters.txt
fix_hold
update_timing -mode final
report_timing_status -file ${prj_name}_phy.ts
report_timing_summary -file ${prj_name}_pr.timing
report_timing_summary -file final_timing.rpt -ep_num 10 -path_num 1
check_timing -verbose -file timing_checks.rpt
report_timing_exception -file ${prj_name}_exception.timing
report_area -io_info -file ${prj_name}_phy.area
export_db ${prj_name}_pr.db
bitgen -bit ${prj_name}.bit
