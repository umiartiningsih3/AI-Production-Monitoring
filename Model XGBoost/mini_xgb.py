"""Implementasi ringkas algoritma XGBoost (exact greedy) untuk regresi squared error.

Mengikuti rumus XGBoost (Chen & Guestrin, 2016):
  g = pred - y, h = 1
  gain  = 1/2 [GL^2/(HL+lambda) + GR^2/(HR+lambda) - G^2/(H+lambda)] - gamma
  bobot daun w = -G/(H+lambda), dikali learning_rate
  nilai kosong (NaN): arah default dipilih yang memberi gain terbesar
API dibuat mirip xgboost.XGBRegressor supaya skrip latih bisa memakai keduanya.
"""
import json
import numpy as np


class _Booster:
    def __init__(self, trees, feats, gains):
        self.trees, self.feats, self.gains = trees, feats, gains

    def get_dump(self, dump_format='json'):
        return [json.dumps(t) for t in self.trees]

    def get_score(self, importance_type='gain'):
        return dict(self.gains)


class XGBRegressor:
    def __init__(self, n_estimators=100, max_depth=3, learning_rate=0.3, min_child_weight=1.0,
                 reg_lambda=1.0, gamma=0.0, base_score=None, **_):
        self.n_estimators, self.max_depth, self.eta = n_estimators, max_depth, learning_rate
        self.mcw, self.lam, self.gamma, self.base_score = min_child_weight, reg_lambda, gamma, base_score

    def get_params(self):
        return {'base_score': self.base_score}

    def fit(self, X, y):
        self.feats = list(X.columns)
        Xv = X.values.astype(float)
        y = np.asarray(y, float)
        if self.base_score is None:
            self.base_score = float(y.mean())
        pred = np.full(len(y), self.base_score)
        self.trees, self.gains = [], {}
        for _ in range(self.n_estimators):
            g, h = pred - y, np.ones_like(y)
            self._nid = 0
            tree = self._build(Xv, g, h, np.arange(len(y)), 0)
            self.trees.append(tree)
            pred = pred + np.array([self._eval(tree, row) for row in Xv])
        return self

    def _leaf(self, G, H):
        return -G / (H + self.lam) * self.eta

    def _score(self, G, H):
        return G * G / (H + self.lam)

    def _build(self, X, g, h, idx, depth):
        nid = self._nid; self._nid += 1
        G, H = g[idx].sum(), h[idx].sum()
        if depth >= self.max_depth or len(idx) < 2:
            return {'nodeid': nid, 'leaf': float(self._leaf(G, H))}
        best = None
        for j in range(X.shape[1]):
            col = X[idx, j]
            ok = ~np.isnan(col)
            if ok.sum() < 2:
                continue
            ii, vals = idx[ok], col[ok]
            order = np.argsort(vals)
            ii, vals = ii[order], vals[order]
            gm, hm = g[idx[~ok]].sum(), h[idx[~ok]].sum()
            gl = np.cumsum(g[ii]); hl = np.cumsum(h[ii])
            for k in range(len(vals) - 1):
                if vals[k] == vals[k + 1]:
                    continue
                thr = (vals[k] + vals[k + 1]) / 2.0
                for miss_left in (True, False):
                    GL = gl[k] + (gm if miss_left else 0); HL = hl[k] + (hm if miss_left else 0)
                    GR, HR = G - GL, H - HL
                    if HL < self.mcw or HR < self.mcw:
                        continue
                    gain = 0.5 * (self._score(GL, HL) + self._score(GR, HR) - self._score(G, H)) - self.gamma
                    if gain > 1e-12 and (best is None or gain > best[0]):
                        best = (gain, j, thr, miss_left)
        if best is None:
            return {'nodeid': nid, 'leaf': float(self._leaf(G, H))}
        gain, j, thr, miss_left = best
        col = X[idx, j]
        left_mask = np.where(np.isnan(col), miss_left, col < thr)
        left = self._build(X, g, h, idx[left_mask], depth + 1)
        right = self._build(X, g, h, idx[~left_mask], depth + 1)
        f = self.feats[j]
        self.gains[f] = self.gains.get(f, 0.0) + float(gain)
        return {'nodeid': nid, 'depth': depth, 'split': f, 'split_condition': float(thr),
                'yes': left['nodeid'], 'no': right['nodeid'],
                'missing': left['nodeid'] if miss_left else right['nodeid'],
                'children': [left, right]}

    def _eval(self, n, row):
        while 'leaf' not in n:
            v = row[self.feats.index(n['split'])]
            go = n['missing'] if np.isnan(v) else (n['yes'] if v < n['split_condition'] else n['no'])
            n = next(c for c in n['children'] if c['nodeid'] == go)
        return n['leaf']

    def predict(self, X):
        Xv = X.values.astype(float)
        return np.array([self.base_score + sum(self._eval(t, r) for t in self.trees) for r in Xv])

    def get_booster(self):
        return _Booster(self.trees, self.feats, self.gains)
