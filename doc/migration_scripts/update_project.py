from pathlib import Path
import xml.etree.ElementTree as E
P=Path(__file__).resolve().parents[1];R=P/'src/user_source/rtl';D=P/'src/td_project'
project=D/'lab_ex5_i2s_v1.0.al'
tree=E.ElementTree(E.fromstring(project.read_text(encoding='utf-8-sig').replace('P&R','P&amp;R')));root=tree.getroot();root.set('Path',D.as_posix())
sources=root.find('Source_Files');sources.clear()
files=sorted(p for p in R.glob('*.v') if p.name!='global_def_125.v')
files += [P/'src/user_source/hdl_source'/n for n in ['top_tf_hdmi_audio.v','hdmi_phy_warpper.v','lane_lvds_10_1.v','SD/sdram.v','include/sdr_as_ram.enc.v','include/sdr_init_ref.enc.v','include/sdr_wrrd.enc.v']]
import os
for typ,items in [('Verilog',files),('ADC_FILE',[P/'src/user_source/constraints_source/pin.adc']),('SDC_FILE',[P/'src/user_source/constraints_source/timing.sdc'])]:
 group=E.SubElement(sources,typ)
 for i,p in enumerate(items):
  f=E.SubElement(group,'File',Path=os.path.relpath(p,D).replace('\\','/'));info=E.SubElement(f,'FileInfo')
  for name,val in [('UsedInSyn','true'),('UsedInP&R','true'),('BelongTo','design_1' if typ=='Verilog' else 'constraint_1'),('CompileOrder',str(i+1))]:E.SubElement(info,'Attr',Name=name,Val=val)
E.indent(tree,space='    ');tree.write(project,encoding='utf-8',xml_declaration=True)
# 保留既有项目入口，移除旧IP重复定义；另存语义清晰的同源工程入口。
root.find('Name').text='lab_ex4_tf_complete';tree.write(D/'lab_ex4_tf_complete.al',encoding='utf-8',xml_declaration=True)
(P/'tools/rtl_files.f').write_text('\n'.join(os.path.relpath(p,P).replace('\\','/') for p in files)+'\n',encoding='utf-8')
pins={'clk':'R7','rst_n':'A2','key1':'B2','key3':'B1','key2':'C1',
'uart_rx':'F12','uart_tx':'D12','flash_cs_n':'P8','flash_miso':'N8','flash_mosi':'P7','flash_sclk':'M9','flash_wp_n':'P9','flash_hold_n':'R9',
'sd_dclk':'A14','sd_miso':'B14','sd_mosi':'A13','sd_ncs':'A12',
'HDMI_DDC_SCL':'P2','HDMI_DDC_SDA':'R2','HDMI_CLK_P':'C3','HDMI_D0_P':'G5','HDMI_D1_P':'F1','HDMI_D2_P':'E1'}
for prefix,balls in [('sw',['C8','C7','C6','C5']),('seg_data',['C15','C16','B6','A5','B5','A8','A7','A6']),('seg_sel',['F16','E16','E12','E10','C13','F10','E11','D11'])]:
 for i,b in enumerate(balls):pins[f'{prefix}[{i}]']=b
lines=['# HX4S20C: 3_原理图/开发板原理图/2_FPGA.pdf + 6_EX_DEVICE.pdf。', '# key1=物理K2；key3=物理K3；key2=物理K4；rst_n=物理K1。']
for n,b in pins.items():
 io='LVDS33' if n.startswith('HDMI_') and n.endswith('_P') else 'LVCMOS33'
 pull='PULLUP' if n in ['rst_n','key1','key2','key3','uart_rx','HDMI_DDC_SCL','HDMI_DDC_SDA'] else 'NONE'
 lines.append(f'set_pin_assignment {{{n}}} {{ LOCATION = {b}; IOSTANDARD = {io}; PULLTYPE = {pull}; }}')
(P/'src/user_source/constraints_source/pin.adc').write_text('\n'.join(lines)+'\n',encoding='utf-8')
(P/'src/user_source/constraints_source/timing.sdc').write_text('''# 教程最终单PLL时钟合同；输入端口沿用官方 clk/rst_n。
create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {clk}]
create_generated_clock -name pixel_clk_5x -source [get_ports {clk}] -master_clock sys_clk -multiply_by 2.5 [get_nets {pixel_clk_5x}]
create_generated_clock -name pixel_clk -source [get_ports {clk}] -master_clock sys_clk -divide_by 2 [get_nets {pixel_clk}]
create_generated_clock -name mem_clk -source [get_ports {clk}] -master_clock sys_clk -divide_by 1.25 [get_pins {u_mem_pll/pll_inst.clkc[1]}]
create_generated_clock -name mem_clk_shift -source [get_ports {clk}] -master_clock sys_clk -divide_by 1.25 -phase 172.8 [get_pins {u_mem_pll/pll_inst.clkc[2]}]
# 移相输出仅服务器件内置SDRAM采样，保持教程硬IP边界约束。
set_false_path -from [get_clocks {mem_clk}] -to [get_clocks {mem_clk_shift}]
set_false_path -from [get_clocks {mem_clk_shift}] -to [get_clocks {mem_clk}]
set_clock_uncertainty -hold 0.050 [get_clocks {sys_clk pixel_clk pixel_clk_5x mem_clk mem_clk_shift}]
set_false_path -from [get_ports {rst_n}]
set_false_path -to [get_regs -hier {*/s1}]
set_false_path -to [get_regs -hier {*/request_sync1_mem}]
set_false_path -to [get_regs -hier {*/index_sync1_mem[*]}]
set_false_path -to [get_regs -hier {*/req_sync1}]
set_false_path -to [get_regs -hier {*/ack_sync1}]
set_false_path -to [get_regs -hier {*/commit_sync1}]
set_false_path -to [get_regs -hier {*/busy_sync1}]
# frame_config_cdc 的 held 在请求至应答期间保持；目的端只在帧沿采样。
set_false_path -from [get_regs -hier {*/held[*]}] -to [get_regs -hier {*/dst_data[*]}]
# 原始FIFO的Gray指针跨域只限定数据路径，不把整个时钟组设为互斥。
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/sync_r1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/sync_r1[*]}] 40.000 -datapath_only
set_max_delay -from [get_regs -hier {u_write_cdc/u_fifo/wr_gray[*]}] -to [get_regs -hier {u_write_cdc/u_fifo/wr_gray_sync1[*]}] 20.000 -datapath_only
set_max_delay -from [get_regs -hier {u_write_cdc/u_fifo/rd_gray[*]}] -to [get_regs -hier {u_write_cdc/u_fifo/rd_gray_sync1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {u_write_cdc/src_block_gray[*]}] -to [get_regs -hier {u_write_cdc/src_block_gray_sync1[*]}] 20.000 -datapath_only
set_max_delay -from [get_clocks {pixel_clk_5x}] -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] 8.000 -datapath_only
''',encoding='utf-8')
