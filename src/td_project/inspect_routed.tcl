import_device eagle_s20.db -package EG4S20BG256
open_project lab_ex5_i2s_v1.0.al -noanalyze
import_db lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0_pr.db
write_verilog ../../tests/results/gui_routed.v
exit
