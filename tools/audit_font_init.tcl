# Run with td_commands_prompt.exe from a completed syn_1 directory.
source settings.cfg
import_device $device_name -package $package_name
open_project ${prj_name}.prj -noanalyze
import_db ${prj_name}_gate.db
write_verilog font_gate.v
exit
