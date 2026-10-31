"""Bangun dataset harian dari workbook (sama seperti yang nanti dihitung view SQL)."""
import sys, datetime as dt
import openpyxl, pandas as pd, numpy as np

src = sys.argv[1]
wb = openpyxl.load_workbook(src, data_only=True, read_only=True)
ws = wb['Data Process Prod ']
rows = list(ws.iter_rows(min_row=3, values_only=True))
hdr = [(' '.join(str(h).split()) if h else '') for h in rows[0]]
ix = {h: i for i, h in enumerate(hdr) if h}
rj = [i for i, h in enumerate(hdr) if h.startswith('(') and h[1:5].isdigit()]
po, rej = [], []
for r in rows[1:]:
    pro = r[ix['*Process']]
    if not pro or str(pro).lower() == 'total':
        continue
    d, rep = r[ix['*Date Process by DHR']], r[ix['Date for Daily Report']]
    if not isinstance(d, dt.datetime) or not isinstance(rep, dt.datetime):
        continue
    pon = str(r[ix['*PO Number']])
    po.append(dict(DateOperation=d.date(), DateReport=rep.date(), Process=pro, PON=pon,
                   Material=str(r[ix['Material Number']]), Qty_Start=float(r[ix['Start Output (EA)']] or 0),
                   Qty_Output=float(r[ix['Good Output (EA)']] or 0)))
    for i in rj:
        q = r[i]
        if isinstance(q, (int, float)) and q:
            rej.append(dict(DateReport=rep.date(), PON=pon, RejectType=hdr[i], Qty=float(q)))
po, rej = pd.DataFrame(po), pd.DataFrame(rej)

# plan harian (Daily Output Summary): baris 7 tanggal, baris 12 target, kolom E..AI
o = wb['Daily Output Summary']
orow = list(o.iter_rows(min_row=7, max_row=13, values_only=True))
plan = {}
for k in range(4, 35):
    d = orow[0][k]
    if isinstance(d, dt.datetime):
        plan[d.date()] = float(orow[5][k] or 0)
plan = pd.Series(plan, name='Plan')

out = po[po.Process == 'Sheating'].groupby('DateReport').Qty_Output.sum().rename('Output')
scr = rej.groupby('DateReport').Qty.sum().rename('Scrap')
d = pd.concat([plan, out, scr], axis=1).fillna(0)
d.index = pd.to_datetime(d.index)
d = d.sort_index()

# WIP & progres PO per akhir hari (berdasarkan DateOperation)
po['DateOperation'] = pd.to_datetime(po.DateOperation)
wip, prog = {}, {}
for day in d.index:
    upto = po[po.DateOperation <= day]
    bend = upto[upto.Process == 'Bending'].groupby('PON').Qty_Start.sum()
    cart = upto[upto.Process == 'Cartoning'].groupby('PON').Qty_Output.sum()
    started = bend.index
    done = cart.index.intersection(started)
    wip[day] = float((bend - cart.reindex(bend.index).fillna(0)).clip(lower=0).sum())
    prog[day] = float(len(done) / len(started)) if len(started) else np.nan
d['WIP'] = pd.Series(wip)
d['ProgresPO'] = pd.Series(prog)
d.to_csv(sys.argv[2])
print(d.to_string())
