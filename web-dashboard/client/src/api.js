import { useEffect, useRef, useState } from 'react';

export async function getJSON(path, params = {}) {
  const qs = new URLSearchParams();
  Object.entries(params).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== '') qs.set(k, v);
  });
  const res = await fetch(`/api/${path}${qs.toString() ? '?' + qs : ''}`, { cache: 'no-store' });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

// Berlangganan event real-time dari server. Mengembalikan { version, connected, lastEvent }.
export function useLive() {
  const [state, setState] = useState({ version: 0, connected: false, lastEvent: null });
  useEffect(() => {
    let es;
    let retry;
    const connect = () => {
      es = new EventSource('/api/events');
      es.addEventListener('hello', () => setState((s) => ({ ...s, connected: true })));
      es.addEventListener('update', (e) => {
        let at = new Date().toISOString();
        try { at = JSON.parse(e.data).at || at; } catch { /* abaikan */ }
        setState((s) => ({ version: s.version + 1, connected: true, lastEvent: at }));
      });
      es.onerror = () => {
        setState((s) => ({ ...s, connected: false }));
        es.close();
        retry = setTimeout(connect, 3000);
      };
    };
    connect();
    return () => { clearTimeout(retry); if (es) es.close(); };
  }, []);
  return state;
}

// Ambil data API; ulangi otomatis saat params atau version berubah.
// Data lama tetap ditampilkan selama memuat ulang supaya layar tidak berkedip.
export function useApi(path, params, version, enabled = true) {
  const [state, setState] = useState({ data: null, loading: true, error: null });
  const key = JSON.stringify(params);
  const seq = useRef(0);
  useEffect(() => {
    if (!enabled) return;
    const my = ++seq.current;
    setState((s) => ({ ...s, loading: true }));
    getJSON(path, params)
      .then((data) => { if (my === seq.current) setState({ data, loading: false, error: null }); })
      .catch((error) => { if (my === seq.current) setState((s) => ({ ...s, loading: false, error })); });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path, key, version, enabled]);
  return state;
}
