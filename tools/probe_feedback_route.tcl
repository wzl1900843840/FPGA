source settings.cfg
import_device $device_name -package $package_name
open_project ${prj_name}.prj -noanalyze
import_db ${prj_name}_pr.db
set_clock_net {u_mem_pll/clk0_buf}
set_clock_net {u_mem_pll/clk0_out}
set_clock_route_enforce {u_mem_pll/clk0_buf}
route
fix_hold
update_timing -mode final
check_timing -verbose -file feedback_probe_checks.rpt
report_timing_summary -file feedback_probe.timing
export_db feedback_probe.db
