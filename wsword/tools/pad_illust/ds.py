import sys; sys.path.insert(0,'lyt')
from edit import Lyt
DPAD=(-116,-15); FACE=(116,-15); LS=(-80,-60); RS=(80,-60); CREATE=(-66,22); OPT=(66,22)
def build(src,dst):
    L=Lyt(src)
    # Basic
    L.route('P_Line_03','P_Line_06','P_Line_02','P_Line_01','P_Line_00',LS,'cap')
    L.route('P_Line_17','P_Line_15',None,None,'Nt_TipsLineCircle_03',DPAD,'circle')
    L.route('P_Line_63','P_Line_79','P_Line_81','P_Line_82','P_Line_85',CREATE,'cap',stop=7)
    L.route('P_Line_95','P_Line_25','P_Line_26','P_Line_87','P_Line_86',OPT,'cap',stop=7)
    L.move('N_OpenY_00',0,-42)
    L.route('P_Line_40','P_Line_39',None,None,'Nt_TipsLineCircle_00',FACE,'circle')
    L.move('N_OpenRStickPress_00',0,-20)
    L.route('P_Line_10','P_Line_13','P_Line_09','P_Line_08','P_Line_07',RS,'cap')
    # Horse
    for n in ('T_Lstick_02','T_Lstick_03','T_Lstick_06','T_Icon_04','T_Icon_05','T_Icon_06','N_Line_08'): L.move(n,0,LS[1]-27)
    top=max(L.pos(n)[1] for n in ('T_Lstick_02','T_Lstick_03','T_Lstick_06'))
    low=min(L.pos(n)[1] for n in ('T_CrossKey_03','T_CrossKey_04','T_CrossKey_05'))
    UP_X=top+28-low
    L.route('P_Line_56','P_Line_88',None,None,'P_Line_89',LS,'cap')
    L.move('N_CrossKey_01',0,UP_X); print('horse cross-key up',UP_X)
    L.route('P_Line_135','P_Line_134','P_Line_138','P_Line_139','Nt_TipsLineCircle_05',DPAD,'circle')
    L.route('P_Line_112','P_Line_113','P_Line_115','P_Line_116','P_Line_117',CREATE,'cap',stop=7)
    L.route('P_Line_103','P_Line_99','P_Line_100','P_Line_110','P_Line_109',OPT,'cap',stop=7)
    L.move('N_OpenY_02',0,-42)
    L.route('P_Line_131','P_Line_130',None,None,'Nt_TipsLineCircle_04',FACE,'circle')
    L.move('N_OpenRStickPress_01',0,-20)
    L.route('P_Line_92','P_Line_98','P_Line_27','P_Line_21','P_Line_20',RS,'cap')
    # Sand seal
    for n in ('T_Lstick_04','T_Lstick_05','T_Icon_07','T_Icon_08','N_Line_10'): L.move(n,0,LS[1]-27)
    top=max(L.pos(n)[1] for n in ('T_Lstick_04','T_Lstick_05'))
    low=min(L.pos(n)[1] for n in ('T_CrossKey_06','T_CrossKey_07','T_CrossKey_08'))
    UP_X=top+28-low
    L.route('P_Line_54','P_Line_52',None,None,'P_Line_38',LS,'cap')
    L.move('N_CrossKey_02',0,UP_X); print('seal cross-key up',UP_X)
    L.route('P_Line_16','P_Line_14','P_Line_141','P_Line_140','Nt_TipsLineCircle_01',DPAD,'circle')
    L.route('P_Line_157','P_Line_158','P_Line_160','P_Line_161','P_Line_162',CREATE,'cap',stop=7)
    L.route('P_Line_151','P_Line_149','P_Line_150','P_Line_155','P_Line_154',OPT,'cap',stop=7)
    for n in ('T_A_02','T_AX_00','T_B_02','T_BX_02','T_Icon_25','T_Icon_26','T_IconXB_09','T_IconXB_10','N_Line_13'): L.move(n,0,-42)
    L.route('P_Line_59','P_Line_58',None,None,'Nt_TipsLineCircle_02',FACE,'circle')
    L.move('N_OpenRStickPress_02',0,-20)
    L.route('P_Line_166','P_Line_169','P_Line_165','P_Line_164','P_Line_163',RS,'cap')
    open(dst,'wb').write(L.d)
    return L
if __name__=='__main__':
    L=build(sys.argv[1],sys.argv[2]); print(len(L.edits),'panes edited')
