"""Run self-checking portable RTL tests; nonzero exit means failure."""
from pathlib import Path
import subprocess,json,time,argparse,os
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--out',type=Path,default=root/'tests/results')
args=parser.parse_args()
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
rtl=root/'src/user_source/rtl'
cases={'keys':['dual_key_chord_router','dual_key_long_hold_guard','param_menu_controller'],'fade':['video_fade_transition'],'uart':['uart_rx_byte','uart_tx_byte','subtitle_uart_controller','uart_status_reporter'],'bmp':['bmp24_decoder'],'pixels':['brightness_contrast_adjust'],'thumbnail':['thumbnail_controller'],
'seg7':['seg7_panel'],'thumbnail_layout':['thumbnail_layout'],'cache':['thumbnail_cache_builder'],'wav':['wav_stream_player'],
'sd_delay':['sd_spi_init','sd_spi_byte_engine','sd_spi_command'],
'fat32':['fat32_volume_scanner'],'streamer':['fat32_file_streamer'],'cdc':['frame_config_cdc'],
'flash':['player_config_persistence','w25q64_preflight_reader','config_flash_journal','config_journal','w25q64_record_store','spi_byte_engine'],
'player':['media_player_control'],
'elevator':['elevator_demo_controller'],
'emergency':['elevator_demo_controller','media_player_control','video_fade_transition'],
'rescue':['uart_rx_byte','uart_tx_byte','subtitle_uart_controller','uart_status_reporter'],
'rescue_ack':['uart_rx_byte','uart_tx_byte','subtitle_uart_controller','uart_status_reporter'],
'rescue_queue':['uart_rx_byte','uart_tx_byte','uart_status_reporter'],
'pic5_address':['media_frame_loader'],
'reader_reset':['media_frame_reader','frame_config_cdc','fifo_prefetch_2','afifo_32_16_256'],
'reset_sync':['reset_sync'],
'emergency_osd':['promax_text_overlay'],
'fix_single_image':['video_fade_transition','media_player_control'],
'fix_burst_abort':['media_frame_reader','media_sdram_arbiter','frame_config_cdc','fifo_prefetch_2','afifo_32_16_256'],
'fix_repeat_save':['dual_key_chord_router','dual_key_long_hold_guard'],
'sd_protocol':['sd_media_service','sd_spi_init','sd_spi_command','sd_spi_byte_engine','sd_spi_sector_reader']}
cases.update({'demo_ui':['demo_ui_controller'],
 'ui_command':['ui_command_cdc'], 'recovery':['media_recovery_manager']})
cases['extended_flash']=cases['flash']
cases['demo_switches']=['demo_switch_filter']
cases['demo_menu']=['promax_text_overlay']
cases['font_pipeline']=['promax_text_overlay']
cases['arbiter_watchdog']=['media_sdram_arbiter']
cases['secure_ingress']=['uart_secure_ingress_bram']
cases['secure_uart_link']=['uart_secure_ingress_bram','subtitle_uart_controller']
cases['arbiter_fair']=['media_sdram_arbiter']
cases['wave_extra']=['promax_audio_waveform']
results=[]
for name,modules in cases.items():
 start=time.time();binary=out/(name+'.vvp')
 extra={'flash':'spi_flash_model.v','extended_flash':'spi_flash_model.v','sd_protocol':'spi_sd_model.v'}
 c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_'+name,'-o',str(binary),str(root/'tests'/('tb_'+name+'.v'))]+[str(rtl/(m+'.v')) for m in modules]+([str(root/'tests'/extra[name])] if name in extra else []),capture_output=True,text=True)
 log=c.stdout+c.stderr
 if c.returncode==0:
  c=subprocess.run(['D:/iverilog/bin/vvp.exe',str(binary)],capture_output=True,text=True,timeout=180);log+=c.stdout+c.stderr
 ok=c.returncode==0 and 'PASS ' in log
 (out/(name+'.log')).write_text(log,encoding='utf-8');print(log,flush=True)
 results.append(dict(test=name,passed=ok,seconds=round(time.time()-start,2)))
(out/'summary.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
