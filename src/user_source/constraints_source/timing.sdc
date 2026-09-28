# 教程最终单PLL时钟合同；输入端口沿用官方 clk/rst_n。
create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {clk}]
create_generated_clock -name pixel_clk_5x -source [get_ports {clk}] -master_clock sys_clk -multiply_by 2.5 [get_nets {pixel_clk_5x}]
create_generated_clock -name pixel_clk -source [get_ports {clk}] -master_clock sys_clk -divide_by 2 [get_nets {pixel_clk}]
create_generated_clock -name mem_clk -source [get_ports {clk}] -master_clock sys_clk -divide_by 1.25 [get_pins {u_mem_pll/pll_inst.clkc[1]}]
create_generated_clock -name mem_clk_shift -source [get_ports {clk}] -master_clock sys_clk -divide_by 1.25 -phase 144.0 [get_pins {u_mem_pll/pll_inst.clkc[2]}]
# 移相输出仅服务器件内置SDRAM采样，保持教程硬IP边界约束。
set_false_path -from [get_clocks {mem_clk}] -to [get_clocks {mem_clk_shift}]
set_false_path -from [get_clocks {mem_clk_shift}] -to [get_clocks {mem_clk}]
set_clock_uncertainty -hold 0.050 [get_clocks {sys_clk pixel_clk pixel_clk_5x mem_clk mem_clk_shift}]
set_false_path -from [get_ports {rst_n}]
# 公共 FIFO 复位进入的就是异步置位/同步释放链；仅豁免这些复位同步触发器。
set_false_path -from [get_regs -hier {u_pix_reset/s2}] -to [get_regs -hier {u_video/u_reader/fifo_ready_mem[*] u_video/u_reader/u_read_fifo/asy_w_rst0 u_video/u_reader/u_read_fifo/asy_w_rst1}]
set_false_path -to [get_regs -hier {*/s1}]
set_false_path -to [get_regs -hier {*/request_sync1_mem}]
set_false_path -to [get_regs -hier {*/index_sync1_mem[*]}]
set_false_path -to [get_regs -hier {*/req_sync1}]
set_false_path -to [get_regs -hier {*/ack_sync1}]
# fade 与控制器在本工程均为 pixel_clk，无需跨域例外。
# frame_config_cdc 的 held 在请求至应答期间保持；目的端只在帧沿采样。
set_false_path -from [get_regs -hier {*/held[*]}] -to [get_regs -hier {*/dst_data[*]}]
# 原始FIFO的Gray指针跨域只限定数据路径，不把整个时钟组设为互斥。
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/sync_r1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/sync_r1[*]}] 40.000 -datapath_only
set_max_delay -from [get_regs -hier {u_write_cdc/u_fifo/wr_gray[*]}] -to [get_regs -hier {u_write_cdc/u_fifo/wr_gray_sync1[*]}] 20.000 -datapath_only
set_max_delay -from [get_regs -hier {u_write_cdc/u_fifo/rd_gray[*]}] -to [get_regs -hier {u_write_cdc/u_fifo/rd_gray_sync1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {u_write_cdc/src_block_gray[*]}] -to [get_regs -hier {u_write_cdc/src_block_gray_sync1[*]}] 20.000 -datapath_only
# PCM_BEGIN: build.py/prepare_media.py generate these optional constraints.
# PCM disabled: no hardware pointers remain after constant optimization.
# PCM_END
set_max_delay -from [get_clocks {pixel_clk_5x}] -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] 8.000 -datapath_only
