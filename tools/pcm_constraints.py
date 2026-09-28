"""Generate an actual SDC block: TD's SDC reader does not honor Tcl if guards."""
import re
def configure_text(text,enabled):
    block='# PCM_BEGIN: build.py/prepare_media.py generate these optional constraints.\n'
    if enabled:
        block+='set_max_delay -from [get_regs -hier {u_wav/wr_gray[*]}] -to [get_regs -hier {u_wav/wr_gray_sync1[*]}] 20.000 -datapath_only\n'
        block+='set_max_delay -from [get_regs -hier {u_wav/rd_gray[*]}] -to [get_regs -hier {u_wav/rd_gray_sync1[*]}] 40.000 -datapath_only\n'
    else:
        block+='# PCM disabled: no hardware pointers remain after constant optimization.\n'
    block+='# PCM_END'
    value,count=re.subn(r'# PCM_BEGIN[^\n]*\n.*?# PCM_END',lambda _:block,text,flags=re.S)
    if count!=1:raise ValueError('Expected exactly one PCM constraint block')
    return value
