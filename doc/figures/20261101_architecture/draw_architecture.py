"""Deterministic architecture drawings; read-only with respect to FPGA sources."""
from pathlib import Path
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle
from matplotlib.path import Path as MPath
from matplotlib.font_manager import FontProperties
import matplotlib.patheffects as pe

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'python_final'
OUT.mkdir(exist_ok=True)
FONT = FontProperties(fname='C:/Windows/Fonts/msyh.ttc')
BOLD = FontProperties(fname='C:/Windows/Fonts/msyhbd.ttc')
plt.rcParams.update({'svg.fonttype': 'none', 'pdf.fonttype': 42, 'savefig.facecolor': 'white'})
C = {'ink':'#16334E','blue':'#2879B7','blue_bg':'#EDF6FD',
     'teal':'#12897E','teal_bg':'#EDF9F6','purple':'#8051A5',
     'purple_bg':'#F5F0FA','orange':'#C87513','orange_bg':'#FFF5E7',
     'muted':'#577084','line':'#CFDDE7','gray_bg':'#F6F8FA'}
manifest = {'method':'Python / Matplotlib; deterministic text and routing',
            'model_originals':'gpt-image-2.5-sunburst; preserved separately', 'figures': []}

class Drawing:
    def __init__(self, title, subtitle, height=1100):
        self.height = height
        self.fig, self.ax = plt.subplots(figsize=(16,height/100), dpi=240)
        self.fig.subplots_adjust(0,0,1,1)
        self.ax.set(xlim=(0,1600),ylim=(height,0))
        self.ax.axis('off')
        self.nodes = {}
        self.edges = []
        self.text(800,40,title,21,bold=True)
        self.text(800,80,subtitle,10,color=C['muted'])

    def text(self,x,y,s,size=11,color=None,bold=False,ha='center',va='center'):
        return self.ax.text(x,y,s,fontproperties=BOLD if bold else FONT,fontsize=size,
                            color=color or C['ink'],ha=ha,va=va,linespacing=1.5,zorder=5)

    def panel(self,x,y,w,h,title,color='blue',dashed=False):
        p=FancyBboxPatch((x,y),w,h,boxstyle='round,pad=0,rounding_size=12',
                         linewidth=1.2,edgecolor=C[color],facecolor='white',
                         linestyle=(0,(6,4)) if dashed else '-',zorder=0)
        self.ax.add_patch(p)
        self.text(x+w/2,y+27,title,13,C[color],True)

    def node(self,name,x,y,w,h,title,body='',color='blue',fs=12,bs=10):
        assert name not in self.nodes, name
        self.nodes[name]=(x,y,w,h)
        p=FancyBboxPatch((x,y),w,h,boxstyle='round,pad=0,rounding_size=8',
                         linewidth=1.2,edgecolor=C[color],facecolor=C[color+'_bg'],zorder=3)
        self.ax.add_patch(p)
        if body:
            self.text(x+w/2,y+h*.30,title,fs,bold=True)
            self.text(x+w/2,y+h*.69,body,bs)
        else:
            self.text(x+w/2,y+h/2,title,fs,bold=True)

    def port(self,name,side='right',f=.5):
        x,y,w,h=self.nodes[name]
        return {'left':(x,y+h*f),'right':(x+w,y+h*f),
                'top':(x+w*f,y),'bottom':(x+w*f,y+h)}[side]

    def line(self,pts,color='blue',both=False,dash=False,arrow=True,lw=1.7):
        path=MPath(pts,[MPath.MOVETO]+[MPath.LINETO]*(len(pts)-1))
        p=FancyArrowPatch(path=path,arrowstyle='<|-|>' if both else '-|>' if arrow else '-',
                          mutation_scale=13,linewidth=lw,color=C[color],
                          linestyle=(0,(5,4)) if dash else '-',zorder=2,
                          capstyle='round',joinstyle='round')
        p.set_path_effects([pe.Stroke(linewidth=lw+2.6,foreground='white'),pe.Normal()])
        self.ax.add_patch(p)

    def edge(self,a,b,sa='right',sb='left',via=(),color='blue',both=False,dash=False,fa=.5,fb=.5):
        assert a in self.nodes and b in self.nodes
        pts=[self.port(a,sa,fa),*via,self.port(b,sb,fb)]
        self.line(pts,color,both,dash)
        self.edges.append({'from':a,'to':b,'bidirectional':both,'kind':color,'route':pts})

    def save(self,stem):
        self.fig.savefig(OUT/(stem+'.png'),dpi=240)
        self.fig.savefig(OUT/(stem+'.svg'))
        self.fig.savefig(OUT/(stem+'.pdf'))
        manifest['figures'].append({'stem':stem,'nodes':list(self.nodes),'edges':self.edges})
        plt.close(self.fig)

def hardware():
    d=Drawing('图 2-1  “梯间守望”系统整体硬件拓扑与数据流 / 控制流框图',
              '日常信息发布与应急提示原型｜主数据通路、辅助图层和控制关系分层呈现')
    d.panel(205,115,1195,835,'安路 EG4S20BG256  ·  FPGA 硬件逻辑',dashed=True)
    d.text(225,165,'① 素材装载与图像缓存',11,C['muted'],True,ha='left')
    d.node('tf',25,205,145,115,'TF 卡','FAT32\nPIC1～PIC5',fs=13)
    d.node('read',235,205,190,115,'SPI 读卡','FAT32 扫描\n文件数据流')
    d.node('decode',475,195,235,135,'BMP24 解码与缩小','640×480 直通\n1280×960 → 2×2 均值缩小',bs=9.4)
    d.node('cdc',760,205,155,115,'写入 CDC','50 → 40 MHz\n跨时钟传输',bs=9.7)
    d.node('memory',960,185,400,155,'SDRAM 访问与图像缓存',
           '控制器与图像存储双向访问\n三路：图像写入 / 视频读取 / 缩略图构建\n视频低水位优先，完整突发事务',bs=9.4)
    for a,b in [('tf','read'),('read','decode'),('decode','cdc'),('cdc','memory')]: d.edge(a,b)
    d.node('thumb',750,360,260,65,'缩略图构建与缓存',fs=11)
    d.edge('memory','thumb','bottom','right',via=[(1160,392)],fb=.5)
    d.text(225,445,'② 视频、音频与图层处理',11,C['muted'],True,ha='left')
    d.node('reader',235,485,190,105,'帧读取与预取','SDRAM 读出\n预取 FIFO')
    d.node('video',475,485,235,105,'图像处理与播放','亮度 / 对比度\n图像转场、自动 / 手动')
    d.node('osd',760,475,255,125,'多图层合成','中文 OSD / 字幕 / 菜单\n缩略图 / PCM 时域波形',bs=9.8)
    d.node('hdmi',1065,485,295,105,'HDMI 输出链','音视频桥 → TMDS PHY',bs=10.5)
    d.node('display',1430,485,145,105,'显示器','640×480\nHDMI 音视频',color='teal',fs=13)
    d.edge('memory','reader','bottom','top',via=[(1300,455),(330,455)],fa=.85)
    for a,b in [('reader','video'),('video','osd'),('osd','hdmi'),('hdmi','display')]: d.edge(a,b)
    d.edge('thumb','osd','bottom','top',via=[(880,449),(887.5,449)])
    d.node('tone',1065,675,295,85,'48 kHz 合成音频','日常音调 / 应急提示音',color='purple',fs=12)
    d.node('wave',760,675,255,85,'PCM 时域波形绘制','从音视频桥最终输出抽头',color='purple',fs=11,bs=9.2)
    d.edge('tone','hdmi','top','bottom',color='purple',fa=.72,fb=.72)
    d.edge('hdmi','wave','bottom','top',via=[(1118.1,635),(938.5,635)],color='purple',fa=.18,fb=.7)
    d.text(1010,619,'最终输出 PCM',9,C['purple'])
    d.edge('wave','osd','top','bottom',color='purple',fa=.15,fb=.15)
    d.text(845,635,'波形图层',8.5,C['purple'])
    d.text(225,817,'③ 本地交互与应急控制',11,C['muted'],True,ha='left')
    d.node('keys',25,825,145,85,'按键 / 拨码','SW1～SW3',color='orange',fs=11)
    d.node('flash',25,650,145,90,'用户参数 Flash','参数读写与保存',color='orange',fs=11,bs=9)
    d.node('param',235,835,255,85,'消抖与播放参数控制','播放 / 显示 / 声音参数',color='orange',fs=11,bs=9.5)
    d.node('alarm',550,835,310,85,'双源告警与事件状态机','本地来源 OR 串口来源',color='orange',fs=11)
    d.node('uart',1090,835,270,85,'UART 接入与事件上报','控制解析 / 查询 / 事件 / ACK',color='teal',fs=11,bs=9.1)
    d.node('pc',1430,825,145,105,'PC 上位机','演示输入\n事件查看与确认',color='teal',fs=12,bs=9)
    d.node('sw4',25,940,145,65,'SW4 本地告警',color='orange',fs=10.5)
    d.edge('keys','param',color='orange',dash=True)
    d.edge('flash','param',sa='right',sb='left',via=[(190,695),(190,877.5)],color='orange',both=True)
    d.edge('sw4','alarm',sa='right',sb='bottom',via=[(190,972.5),(190,990),(705,990)],color='orange',dash=True)
    d.edge('pc','uart',sa='left',sb='right',color='teal',both=True)
    d.edge('uart','alarm',sa='left',sb='right',color='teal',both=True)
    d.text(975,859,'命令 / 状态 / 事件',9,C['teal'])
    # The shared dashed bus denotes functional control, not a fabricated RTL bus.
    d.line([(362.5,835),(362.5,792),(1380,792)],'orange',arrow=False,dash=True)
    d.line([(705,835),(705,792)],'orange',arrow=False,dash=True)
    d.line([(600,792),(600,590)],'orange',dash=True)
    d.line([(730,792),(730,555),(760,555)],'orange',dash=True)
    d.line([(1380,792),(1380,717.5),(1360,717.5)],'orange',dash=True)
    d.text(1100,780,'参数与应急控制（功能关系）',9,C['orange'])
    d.text(815,967,'告警优先 PIC5；ACK 仅表示接收确认；全部有效来源解除后恢复日常显示',10,C['orange'])
    d.ax.add_patch(FancyBboxPatch((205,1000),1195,48,boxstyle='round,pad=0,rounding_size=7',
                                 facecolor=C['gray_bg'],edgecolor=C['line']))
    d.text(802.5,1024,'时钟与复位：50 MHz 系统域｜40 MHz 内存域｜25 MHz 像素域｜125 MHz 串化域；CDC 与帧边界配置提交',10)
    for x,col,txt,dash in [(300,'blue','图像数据',False),(590,'purple','音频 / PCM',False),
                           (900,'orange','功能控制',True),(1190,'teal','UART 双向交互',False)]:
        d.line([(x,1070),(x+50,1070)],col,both=col=='teal',dash=dash)
        d.text(x+65,1070,txt,10,ha='left')
    d.save('图2-1_系统硬件拓扑与数据控制流')

def cooperation():
    d=Drawing('图 2-3  FPGA 硬件逻辑与 PC 监控上位机软件协同架构图',
              '协议接入、双源告警、事件回传与人工接收确认｜UART 115200 bit/s，8N1',height=1160)
    d.panel(25,115,605,755,'FPGA 硬件终端')
    d.panel(990,115,585,755,'PC 监控上位机 · Python / Tkinter',color='teal')
    d.node('rx',450,185,145,90,'UART RX',fs=13)
    d.node('gate',230,175,190,110,'接入校验与分流','写帧：会话 / 序号 / CRC\n只读查询：单独分流',fs=10.5,bs=8.8)
    d.node('parse',65,185,135,90,'命令解析\n与分发',fs=11)
    d.edge('rx','gate',sa='left',sb='right')
    d.edge('gate','parse',sa='left',sb='right')
    d.node('demo',65,325,230,85,'FLOOR / SUB','楼层、方向、门状态演示\n字幕内容更新',fs=11,bs=9)
    d.node('command',350,325,245,85,'ALERT / ACK','串口告警源 / 事件 ID 确认',fs=11,bs=9)
    d.edge('parse','demo',sa='bottom',sb='top',via=[(132.5,300),(180,300)])
    d.edge('parse','command',sa='bottom',sb='top',via=[(132.5,300),(472.5,300)])
    d.node('sw4',65,455,230,100,'SW4 本地告警','本地输入，独立于串口来源',color='orange',fs=11,bs=9)
    d.node('state',350,440,245,130,'告警与事件状态机','双源有效状态合成\n事件 ID 匹配 / 确认状态',color='orange',fs=11,bs=9.4)
    d.edge('sw4','state',color='orange')
    d.edge('command','state',sa='bottom',sb='top',color='orange')
    d.node('av',65,610,230,95,'画面与声音控制','日常 PIC1～4 / 应急 PIC5\n中文状态 / 提示音',fs=10.5,bs=9)
    d.node('report',350,610,245,80,'事件与状态上报','编号 / 有限重发 / 查询响应',fs=10.5,bs=9)
    d.edge('state','av',sa='bottom',sb='top',via=[(411.25,590),(180,590)],fa=.25)
    d.edge('state','report',sa='bottom',sb='top')
    d.node('crc',350,715,245,50,'RESCUE 事件 CRC 封装',fs=10.3)
    d.node('tx',450,795,145,50,'UART TX',fs=12)
    d.edge('report','crc',sa='bottom',sb='top')
    d.edge('crc','tx',sa='bottom',sb='top',via=[(472.5,780),(522.5,780)])
    d.node('query',65,750,230,95,'只读查询 / 状态回读','BOOT? / RESCUE?\nELEV? / SUB?',fs=10.5,bs=9.2)
    d.edge('gate','query',sa='bottom',sb='left',via=[(325,310),(45,310),(45,797.5)])
    d.edge('query','tx',via=[(320,797.5),(320,820)])
    # Demonstration and subtitle changes feed rendering independently of alarm.
    d.edge('demo','av',sa='left',sb='left',via=[(53,367.5),(53,657.5)])
    d.node('ui',1030,185,285,125,'ui.py · 操作与展示','状态看板 / 楼层演示\n事件时间线 / 人工 ACK',color='teal',fs=12,bs=10)
    d.node('journal',1350,185,185,125,'journal.py','事件日志\n历史回放',color='teal',fs=11,bs=10)
    d.node('core',1030,435,505,110,'core.py · 业务状态与调度','会话管理 / 命令调度 / 设备状态 / 告警事件',color='teal',fs=13,bs=10)
    d.node('protocol',1030,605,505,95,'protocol.py · 协议编解码','控制帧封装 / 消息解析 / CRC16 校验',color='teal',fs=12,bs=10)
    d.node('transport',1030,760,505,85,'transport.py · 串口收发','真实串口设备连接',color='teal',fs=12,bs=10)
    d.edge('ui','core',sa='bottom',sb='top',fa=.5,fb=.282,via=[(1172.5,375)],color='teal',both=True)
    d.edge('journal','core',sa='bottom',sb='top',fb=.817,color='teal',both=True)
    d.edge('core','protocol',sa='bottom',sb='top',color='teal',both=True)
    d.edge('protocol','transport',sa='bottom',sb='top',color='teal',both=True)
    d.text(1172.5,350,'操作者在界面发送人工 ACK',9.5,C['teal'])
    # Explicit transport endpoints: no arrows connected merely to panel borders.
    d.edge('transport','rx',sa='left',sb='right',fa=.2,via=[(950,777),(950,230)],color='orange')
    d.edge('tx','transport',sa='right',sb='left',fb=.8,via=[(800,820),(800,828)],color='blue')
    d.text(795,185,'PC → FPGA',12,C['orange'],True)
    d.text(795,285,'HELLO / FLOOR\nALERT / ACK / SUB\n只读查询',10.5,C['orange'])
    d.text(790,435,'UART',17,C['ink'],True)
    d.text(790,480,'115200 bit/s · 8N1',11)
    d.text(790,560,'控制写帧\n会话号 + 序号\n负载 + CRC16',10.5)
    d.text(790,645,'CRC 用于完整性校验\n不等于加密认证',9.5,C['muted'])
    d.text(790,715,'FPGA → PC',12,C['blue'],True)
    d.text(790,765,'RESCUE + CRC\n状态回读 / 启动里程碑',9.8,C['blue'])
    d.text(1282.5,893,'PC 不参与 FPGA 像素渲染；SIM / 历史回放与真实串口证据区分',9.5,C['teal'])
    d.text(325,893,'ACKED 仍属告警有效期间，只有全部有效来源解除才恢复',9.5,C['orange'])
    d.text(800,935,'典型人工确认顺序（解除条件独立于是否收到 ACK）',12,bold=True)
    labels=['1  告警触发','2  应急提示\n与事件上报','3  PC 校验\n并展示','4  人工发送\n匹配 ID 的 ACK',
            '5  FPGA 接受\n并回读 ACKED','6  全部有效\n告警来源解除','7  恢复\n日常显示']
    for i,t in enumerate(labels):
        d.node('step'+str(i+1),40+i*220,965,200,85,t,fs=10.5,color='orange' if i in (3,4,5) else 'blue')
        if i:d.edge('step'+str(i),'step'+str(i+1))
    d.text(800,1082,'未确认：每次发送后约等 1 秒，首次后最多重发 2 次 → TIMEOUT；有效事件的匹配迟到 ACK 仍可接受',10)
    d.text(800,1123,'楼层为演示输入；ACK 仅表示接收确认，不表示故障解除或救援到场。',11,C['orange'],True)
    d.save('图2-3_FPGA与PC上位机协同架构')

if __name__=='__main__':
    hardware()
    cooperation()
    (OUT/'绘图清单.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'output':str(OUT),'files':[p.name for p in OUT.iterdir()]},ensure_ascii=False))
