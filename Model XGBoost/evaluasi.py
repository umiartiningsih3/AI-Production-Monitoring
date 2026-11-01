"""Evaluasi model XGBoost vs baseline rata-rata bergerak 7 hari (Sprint 1, EN-01).
Pakai: python evaluasi.py <daily.csv dari build_dataset.py> [nama lini] [YYYY-MM bulan laporan]
Mencetak MAE, RMSE, R2 untuk data uji kronologis 15% terakhir dan walk-forward 1 langkah.
"""
import sys, numpy as np, pandas as pd, json
import os; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
import mini_xgb as xgb
FEATS=['plan_output','output_lag1','output_ma3','yield_lag1','yield_ma7','defect_lag1','wip','progres_po','hari_ke']
params=dict(n_estimators=60,max_depth=2,learning_rate=0.1,min_child_weight=2,subsample=1.0,reg_lambda=1.0,objective='reg:squarederror',random_state=42)
def siapkan(f):
    d=pd.read_csv(f,index_col=0,parse_dates=True)
    awal=pd.Timestamp(BLN+'-01'); d=d[(d.index>=awal)&(d.index<awal+pd.offsets.MonthBegin(1))]
    fw,fp=d['WIP'],d['ProgresPO']
    a=d[d.Output>0].copy()
    a['Yield_']=a.Output/(a.Output+a.Scrap); a['Defect_']=a.Scrap/(a.Output+a.Scrap)
    a['plan_output']=a.Plan; a['output_lag1']=a.Output.shift(1)
    a['output_ma3']=a.Output.shift(1).rolling(3,min_periods=1).mean()
    a['yield_lag1']=a.Yield_.shift(1); a['yield_ma7']=a.Yield_.shift(1).rolling(7,min_periods=1).mean()
    a['defect_lag1']=a.Defect_.shift(1)
    prev=a.index-pd.Timedelta(days=1)
    a['wip']=[fw.get(p,np.nan) for p in prev]; a['progres_po']=[fp.get(p,np.nan) for p in prev]
    a['hari_ke']=[(x-pd.Timestamp('1900-01-01')).days%7+1 for x in a.index]
    for c in ['Output','Yield_','Defect_']:
        a['ma7_'+c]=a[c].shift(1).rolling(7,min_periods=1).mean()   # baseline naif
    return a.dropna(subset=['output_lag1'])
def met(y,p):
    y,p=np.array(y),np.array(p); e=p-y
    mae=np.mean(np.abs(e)); rmse=np.sqrt(np.mean(e**2))
    ss=np.sum((y-y.mean())**2); r2=1-np.sum(e**2)/ss if ss>0 else float('nan')
    return mae,rmse,r2
hasil={}
BLN=sys.argv[3] if len(sys.argv)>3 else '2026-03'
for nama,f in [(sys.argv[2] if len(sys.argv)>2 else 'Lini',sys.argv[1])]:
    a=siapkan(f); n=len(a)
    ntr=int(round(n*0.70)); nva=int(round(n*0.15)); nte=n-ntr-nva
    hasil[nama]={'hari':n,'periode':f"{a.index.min().date()} s/d {a.index.max().date()}",'split':[ntr,nva,nte]}
    for t in ['Output','Yield_','Defect_']:
        y=a[t].values; X=a[FEATS]
        # (1) kronologis 70/15/15: latih 70%, uji 15% terakhir
        m=xgb.XGBRegressor(**params,base_score=float(np.mean(y[:ntr]))); m.fit(X.iloc[:ntr],y[:ntr])
        pt=m.predict(X.iloc[ntr+nva:]); bt=a['ma7_'+t].values[ntr+nva:]
        # (2) walk-forward 1 langkah: mulai hari ke-6
        wf,wb,wy=[],[],[]
        for i in range(5,n):
            mm=xgb.XGBRegressor(**params,base_score=float(np.mean(y[:i]))); mm.fit(X.iloc[:i],y[:i])
            wf.append(float(mm.predict(X.iloc[[i]])[0])); wb.append(a['ma7_'+t].values[i]); wy.append(y[i])
        r={'uji':{'n':nte,'xgb':met(y[ntr+nva:],pt),'base':met(y[ntr+nva:],bt)},
           'wf':{'n':len(wy),'xgb':met(wy,wf),'base':met(wy,wb)}}
        for k in ('uji','wf'):
            r[k]['turun_rmse']=1-r[k]['xgb'][1]/r[k]['base'][1] if r[k]['base'][1] else float('nan')
        hasil[nama][t]=r
for nama,h in hasil.items():
    print(nama,h['hari'],h['periode'],h['split'])
    for t in ['Output','Yield_','Defect_']:
        for k in ('uji','wf'):
            r=h[t][k]; print(f"  {t:8}{k:4} n={r['n']:2} XGB MAE={r['xgb'][0]:.5g} RMSE={r['xgb'][1]:.5g} R2={r['xgb'][2]:.3f} | MA7 MAE={r['base'][0]:.5g} RMSE={r['base'][1]:.5g} R2={r['base'][2]:.3f} | turun RMSE {r['turun_rmse']*100:.1f}%")
