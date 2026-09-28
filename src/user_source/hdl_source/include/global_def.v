


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				(1000000000 / 40000000)
`define   SELF_REFRESH_INTERVAL			((64000000 / `SDR_CLK_PERIOD / (2**`ROW_WIDTH)) - 1)


// 宏必须整体加括号；计数器从0计到阈值，减1后每1250拍请求刷新一次。
