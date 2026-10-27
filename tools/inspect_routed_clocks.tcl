source settings.cfg
import_device $device_name -package $package_name
open_project ${prj_name}.prj -noanalyze
import_db ${prj_name}_pr.db
report_clock_utilization -file inspected_clocks.txt
puts {FEEDBACK_CELLS}
puts [get_cells -hier {*bufg_feedback* *pll_inst*}]
puts {FEEDBACK_NETS}
puts [get_nets -hier {*clk0*}]
foreach net [get_nets -hier {*clk0*}] { report_property $net }
foreach cell [get_cells -hier {*bufg_feedback* *bufg_memory* *pll_inst*}] { report_property $cell }
