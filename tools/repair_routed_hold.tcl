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
# Refresh the pre-repair QoR so every report describes this repaired database.
report_qor -step route -file route.qor
flow_status -file route_flow.status
# Reject failed timing before generating a new BIT, including direct TD use.
set timing_handle [open ${prj_name}_phy.ts r]
set timing_text [read $timing_handle]
close $timing_handle
foreach timing_key {SWNS STNS HWNS HTNS} {
    set pattern [format {%s:\s*([-+0-9.eE]+)ns} $timing_key]
    if {![regexp $pattern $timing_text match slack] || ![string is double -strict $slack]} {
        error "FINAL_TIMING_REJECTED: missing or invalid $timing_key"
    }
    if {$slack < 0} { error "FINAL_TIMING_REJECTED: $timing_key = $slack ns" }
}
set checks_handle [open timing_checks.rpt r]
set checks_text [read $checks_handle]
close $checks_handle
foreach check_name {{no clock} {clock definition} {invalid constraint} {combinational loops} {no path constraints}} {
    set pattern [format {checking %s\(([0-9]+)\)} $check_name]
    if {![regexp $pattern $checks_text match count] || $count != 0} {
        error "FINAL_TIMING_REJECTED: unresolved $check_name"
    }
}
set pll_matches [regexp -all -inline {There are ([0-9]+) (?:clock pins that have no clock constraints|clocks whose clock frequency do not match the PLL setting)} $checks_text]
if {[llength $pll_matches] < 4} { error "FINAL_TIMING_REJECTED: missing PLL constraint checks" }
foreach {pll_message pll_count} $pll_matches {
    if {$pll_count != 0} { error "FINAL_TIMING_REJECTED: $pll_message" }
}
export_db ${prj_name}_pr.db
bitgen -bit ${prj_name}.bit
puts "FINAL_TIMING_ACCEPTED: repaired database, reports and BIT are consistent"
