"""Latih XGBoost (output, yield, defect) lalu ekspor ke T-SQL.

Fitur dihitung PERSIS seperti view dbo.vw_Fitur di SQL Server:
  plan_output, output_lag1, output_ma3, yield_lag1, yield_ma7,
  defect_lag1, wip, progres_po, hari_ke
Pakai: python train_to_sql.py daily.csv out_dir [HDC|SS]
Catatan: fungsi dbo.fn_Pred_* saat ini dipakai untuk departemen HDC.
"""
import json, sys, datetime as dt
import numpy as np, pandas as pd
try:
    import xgboost as xgb                      # library resmi
    ENGINE = 'xgboost ' + xgb.__version__
except ImportError:                            # cadangan: implementasi algoritma yang sama
    import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import mini_xgb as xgb
    ENGINE = 'mini_xgb (numpy)'

FEATS = ['plan_output', 'output_lag1', 'output_ma3', 'yield_lag1', 'yield_ma7',
         'defect_lag1', 'wip', 'progres_po', 'hari_ke']
VERSION = 'xgb-v1.0'
DEPT = sys.argv[3] if len(sys.argv) > 3 else 'HDC'   # HDC = lini produk A, SS = lini produk B

d = pd.read_csv(sys.argv[1], index_col=0, parse_dates=True)
out_dir = sys.argv[2]

# WIP/progres pada akhir hari sebelumnya (kalender)
full_wip = d['WIP'].copy()
full_prog = d['ProgresPO'].copy()

a = d[d.Output > 0].copy()                       # hari kerja aktual
a['Yield_'] = a.Output / (a.Output + a.Scrap)
a['Defect_'] = a.Scrap / (a.Output + a.Scrap)
a['plan_output'] = a.Plan
a['output_lag1'] = a.Output.shift(1)
a['output_ma3'] = a.Output.shift(1).rolling(3, min_periods=1).mean()
a['yield_lag1'] = a.Yield_.shift(1)
a['yield_ma7'] = a.Yield_.shift(1).rolling(7, min_periods=1).mean()
a['defect_lag1'] = a.Defect_.shift(1)
prev = a.index - pd.Timedelta(days=1)
a['wip'] = [full_wip.get(p, np.nan) for p in prev]
a['progres_po'] = [full_prog.get(p, np.nan) for p in prev]
a['hari_ke'] = [(x - pd.Timestamp('1900-01-01')).days % 7 + 1 for x in a.index]

train = a.dropna(subset=['output_lag1'])
print('engine:', ENGINE)
print('baris latih:', len(train), train.index.min().date(), '->', train.index.max().date())

targets = {'Output': 'Output', 'Yield': 'Yield_', 'Defect': 'Defect_'}
params = dict(n_estimators=60, max_depth=2, learning_rate=0.1, min_child_weight=2,
              subsample=1.0, reg_lambda=1.0, objective='reg:squarederror', random_state=42)

sql_funcs, fi_rows, info_rows = [], [], []
X = train[FEATS]

def node_sql(n, ind):
    if 'leaf' in n:
        return repr(float(n['leaf']))
    f = n['split']; t = float(n['split_condition'])
    yes = next(c for c in n['children'] if c['nodeid'] == n['yes'])
    no = next(c for c in n['children'] if c['nodeid'] == n['no'])
    miss_yes = n['missing'] == n['yes']
    cond = f"@{f} < {t!r}"
    cond = f"({cond} OR @{f} IS NULL)" if miss_yes else f"({cond})"
    pad = '    ' * ind
    return (f"CASE WHEN {cond}\n{pad}    THEN {node_sql(yes, ind + 1)}\n"
            f"{pad}    ELSE {node_sql(no, ind + 1)} END")

for name, col in targets.items():
    y = train[col].values
    m = xgb.XGBRegressor(**params, base_score=float(np.mean(y)))
    m.fit(X, y)
    # validasi walk-forward sederhana (latih s/d t-1, prediksi t) untuk 8 hari terakhir
    errs, apes = [], []
    for i in range(len(train) - 8, len(train)):
        mm = xgb.XGBRegressor(**params, base_score=float(np.mean(y[:i])))
        mm.fit(X.iloc[:i], y[:i])
        p = float(mm.predict(X.iloc[[i]])[0])
        errs.append(abs(p - y[i])); apes.append(abs(p - y[i]) / abs(y[i]) if y[i] else np.nan)
    mae, mape = float(np.mean(errs)), float(np.nanmean(apes))
    print(f'{name}: walk-forward MAE={mae:.5f} MAPE={mape:.4%}')
    info_rows.append((name, len(train), train.index.min().date(), train.index.max().date(), mae, mape))

    booster = m.get_booster()
    base = float(m.get_params()['base_score'])
    trees = [json.loads(t) for t in booster.get_dump(dump_format='json')]
    body = ' +\n        '.join(f"({node_sql(t, 2)})" for t in trees)
    params_sql = ', '.join(f'@{f} float' for f in FEATS)
    sql_funcs.append(
        f"CREATE OR ALTER FUNCTION dbo.fn_Pred_{name} ({params_sql})\nRETURNS float\nAS\nBEGIN\n"
        f"    -- XGBoost {VERSION}: {len(trees)} pohon, max_depth {params['max_depth']}, "
        f"learning_rate {params['learning_rate']}, dilatih {len(train)} hari\n"
        f"    RETURN {base!r} +\n        {body};\nEND;\nGO\n")
    gain = booster.get_score(importance_type='gain')
    tot = sum(gain.values()) or 1
    for f in FEATS:
        fi_rows.append((name, f, gain.get(f, 0.0) / tot))
    # cek: prediksi model == fungsi transpile (diuji di python)
    np.save(f'{out_dir}/pred_{name}.npy', m.predict(X))

with open(f'{out_dir}/03_model.sql', 'w', encoding='utf-8') as fh:
    fh.write('/* ===== Bagian 3: model XGBoost hasil latih (dibuat otomatis) ===== */\n')
    fh.write('USE [PBL_MonitoringProduksi];\nGO\n\n')
    for s in sql_funcs:
        fh.write(s + '\n')
    fh.write(f"DELETE FROM dbo.tblBA204_FeatureImportance WHERE Dept = N'{DEPT}';\n")
    for r in fi_rows:
        fh.write(f"INSERT INTO dbo.tblBA204_FeatureImportance (Dept, Metric, Feature, Importance, ModelVersion) "
                 f"VALUES (N'{DEPT}', N'{r[0]}', N'{r[1]}', {r[2]:.6f}, N'{VERSION}');\n")
    fh.write(f"DELETE FROM dbo.tblBA204_ModelInfo WHERE Dept = N'{DEPT}';\n")
    for r in info_rows:
        fh.write(f"INSERT INTO dbo.tblBA204_ModelInfo (Dept, Metric, ModelVersion, TrainRows, TrainFrom, TrainTo, MAE, MAPE, TrainedOn) "
                 f"VALUES (N'{DEPT}', N'{r[0]}', N'{VERSION}', {r[1]}, '{r[2]}', '{r[3]}', {r[4]:.6f}, {r[5]:.6f}, SYSDATETIME());\n")
    fh.write('GO\n')
train[FEATS + ['Output', 'Yield_', 'Defect_']].to_csv(f'{out_dir}/train_features.csv')
print('OK ->', out_dir)
