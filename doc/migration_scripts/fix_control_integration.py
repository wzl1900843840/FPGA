from pathlib import Path
p=Path(__file__).resolve().parents[1]/'src/user_source/hdl_source/top_tf_hdmi_audio.v';s=p.read_text(encoding='utf-8')
s=s.replace('    player_config_persistence u_config','''    wire view_sys;
    sync_2ff u_view_sys(.clk(clk),.rst_n(sys_reset_n),.async_in(view_mode),.sync_out(view_sys));
    wire mode_update=auto_sys && !sw_sync2[1] && !view_sys;
    player_config_persistence u_config''')
s=s.replace('.cfg_update_valid(menu_update && !sw_sync2[0]),.cfg_period_ms(menu_period),\n        .cfg_volume(menu_volume),.cfg_mode({7\'d0,auto_status_sys})',".cfg_update_valid((menu_update && !view_sys) || mode_update),.cfg_period_ms(menu_update?menu_period:period_ms),\n        .cfg_volume(menu_update?menu_volume:volume),.cfg_mode(mode_update?{7'd0,~mode[0]}:mode)")
s=s.replace('menu_event && sw_sync2[0]','menu_event && view_sys')
s=s.replace('{sw_sync2,4\'d0,contrast,brightness,volume,period_ms}',"{sw_sync2,3'd0,mode[0],contrast,brightness,volume,period_ms}")
s=s.replace('.key_mode(switches_pix[0]!=mode_seen)', '.key_mode((switches_pix[0] && !mode_seen) || (!switches_pix[0] && mode_seen && view_mode))')
s=s.replace('    // 控制逻辑同像素域运行','''    reg display_view,last_cfg_mode,last_display_view;
    always @(posedge pixel_clk or negedge pix_reset_n)
        if(!pix_reset_n) begin display_view<=0;last_cfg_mode<=0;last_display_view<=0;end
        else begin
            last_cfg_mode<=config_pix[56];last_display_view<=display_view;
            // 快选目标通过控制器握手提交之前保持缩略图，不能闪回旧图。
            if(frame_start) begin
                if(view_mode) display_view<=1;
                else if(active_index==selected_index || !thumb_was_active) display_view<=0;
            end
        end
    // 控制逻辑同像素域运行''')
# Keep selection request separate from display-view handshake.
s=s.replace('.next_event(next_pix && !view_mode)','.next_event(next_pix && !display_view)').replace('.previous_event(previous_pix && !view_mode)','.previous_event(previous_pix && !display_view)')
s=s.replace('.select_index(selected_index),.view_mode(view_mode)', '.select_index(selected_index),.view_mode(display_view)')
s=s.replace('.toggle_auto_event(auto_pix && !view_mode)',".toggle_auto_event(1'b0)")
s=s.replace(".auto_cfg_valid(view_mode),.auto_cfg_enabled(1'b0)",'.auto_cfg_valid(display_view || last_display_view!=display_view || last_cfg_mode!=config_pix[56]),.auto_cfg_enabled(config_pix[56] && !display_view)')
s=s.replace('(view_mode && focus_border)','(display_view && focus_border)')
# A selection is latched until target bank commits (mode-only exit does not wait).
s=s.replace('reg display_view,last_cfg_mode,last_display_view;','reg display_view,last_cfg_mode,last_display_view,selection_wait;')
s=s.replace('last_display_view<=0;end','last_display_view<=0;selection_wait<=0;end')
s=s.replace('            // 快选目标','            if(thumb_transition && !view_mode && thumb_was_active) selection_wait<=1;\n            // 快选目标')
s=s.replace('else if(active_index==selected_index || !thumb_was_active) display_view<=0;', 'else if(!selection_wait || active_index==selected_index) begin display_view<=0;selection_wait<=0;end')
p.write_text(s,encoding='utf-8')
