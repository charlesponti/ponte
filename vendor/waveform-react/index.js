import { jsx as o, jsxs as f, Fragment as rt } from "react/jsx-runtime";
import { useSyncExternalStore as it, useRef as se, useEffect as lt, Fragment as Ve, useId as ht, useState as O, useMemo as Ge } from "react";
const R = 16e3, V = 125, ct = R / V, D = 1024, Y = 24, ue = 80, Le = 7e3, me = 8, H = Math.PI * 2, le = -60, Je = -66, Ke = D / 2 / R * V - 0.5;
function fe(e, t, n = 0.025, a = 0.15) {
  const r = Math.floor(e.length * t / R), i = new Float32Array(r), s = new Float32Array(r), l = new Float32Array(r), u = new Float32Array(r), p = Math.max(1, Math.round(n * t)), h = new Float64Array(p), g = new Int32Array(p), x = Math.exp(-1 / (t * Math.max(a, 1e-6)));
  let d = 0, w = 0;
  for (let m = 0; m < r; m++) {
    const c = Math.round((m + 1) * R / t);
    let y = 1 / 0, b = -1 / 0, k = 0;
    for (let M = d; M < c; M++) {
      const z = e[M];
      z < y && (y = z), z > b && (b = z), k += z * z;
    }
    h[m % p] = k, g[m % p] = c - d;
    let F = 0, N = 0;
    for (let M = 0; M < p; M++)
      F += h[M], N += g[M];
    const v = Math.sqrt(F / Math.max(1, N));
    w = Math.max(v, w * x), i[m] = y, s[m] = b, l[m] = v, u[m] = w, d = c;
  }
  return { n: r, lo: i, hi: s, rms: l, level: u };
}
function dt(e) {
  const t = new Float64Array(e / 2), n = new Float64Array(e / 2), a = new Uint32Array(e), r = Math.log2(e) | 0;
  for (let i = 0; i < e / 2; i++)
    t[i] = Math.cos(H * i / e), n[i] = Math.sin(H * i / e);
  for (let i = 0; i < e; i++) {
    let s = 0;
    for (let l = 0; l < r; l++) i & 1 << l && (s |= 1 << r - 1 - l);
    a[i] = s;
  }
  return (i, s) => {
    for (let l = 0; l < e; l++) {
      const u = a[l];
      if (u > l) {
        let p = i[l];
        i[l] = i[u], i[u] = p, p = s[l], s[l] = s[u], s[u] = p;
      }
    }
    for (let l = 2; l <= e; l <<= 1) {
      const u = l >> 1, p = e / l;
      for (let h = 0; h < e; h += l)
        for (let g = h, x = 0; g < h + u; g++, x += p) {
          const d = g + u, w = i[d] * t[x] + s[d] * n[x], m = s[d] * t[x] - i[d] * n[x];
          i[d] = i[g] - w, s[d] = s[g] - m, i[g] += w, s[g] += m;
        }
    }
  };
}
const Qe = (e, t, n) => e < t ? t : e > n ? n : e, _ = (e, t, n) => e + (t - e) * n, B = (e, t) => (e % t + t) % t, ne = (e, t) => Qe((20 * Math.log10(Math.max(e, 1e-9)) - t) / -t, 0, 1);
function qe(e) {
  let t = e >>> 0;
  return () => {
    t = t + 1831565813 | 0;
    let n = Math.imul(t ^ t >>> 15, 1 | t);
    return n = n + Math.imul(n ^ n >>> 7, 61 | n) ^ n, ((n ^ n >>> 14) >>> 0) / 4294967296;
  };
}
function ut(e, t, n, a, r) {
  const i = r * r, s = i * r;
  return 0.5 * (2 * t + (-e + n) * r + (2 * e - 5 * t + 4 * n - a) * i + (-e + 3 * t - 3 * n + a) * s);
}
function ge(e, t, n, a = 1, r = 0) {
  const i = Math.floor(t), s = t - i, l = ut(
    e[B(i - 1, n) * a + r],
    e[B(i, n) * a + r],
    e[B(i + 1, n) * a + r],
    e[B(i + 2, n) * a + r],
    s
  );
  return l > 0 ? l : 0;
}
const mt = dt(D), Be = Float64Array.from({ length: D }, (e, t) => 0.5 - 0.5 * Math.cos(H * t / D)), pt = Be.reduce((e, t) => e + t * t, 0), ve = new Float64Array(D), ke = new Float64Array(D), Me = new Float64Array(D / 2), xe = new Float64Array(D / 2 + 1), _e = /* @__PURE__ */ new Map();
function ft(e) {
  const t = _e.get(e);
  if (t) return t;
  const n = Array.from({ length: e + 1 }, (r, i) => ue * Math.pow(Le / ue, i / e)), a = {
    edgesHz: n,
    bin: n.map((r) => r * D / R),
    centre: Array.from({ length: e }, (r, i) => Math.sqrt(n[i] * n[i + 1]))
  };
  return _e.set(e, a), a;
}
function We(e, t, n, a) {
  const r = e.length, i = D / 2;
  for (let h = 0; h < D; h++) {
    const g = e[B(t - D + h, r)];
    ve[h] = n.hann ? g * Be[h] : g, ke[h] = 0;
  }
  mt(ve, ke);
  const s = 2 / (D * (n.hann ? pt : D));
  Me[0] = 0;
  for (let h = 1; h < i; h++) Me[h] = (ve[h] * ve[h] + ke[h] * ke[h]) * s;
  xe[0] = 0;
  for (let h = 0; h < i; h++) xe[h + 1] = xe[h] + Me[h];
  const l = (h) => {
    const g = Math.max(0, h + 0.5), x = Math.min(i - 1, Math.floor(g));
    return xe[x] + Me[x] * Math.min(1, g - x);
  }, { bin: u, centre: p } = ft(n.nb);
  for (let h = 0; h < n.nb; h++) {
    const g = Math.max(0, l(u[h + 1]) - l(u[h]));
    a[h] = Math.sqrt(g * Math.pow(10, n.tilt * Math.log2(p[h] / 1e3) / 10));
  }
  return a;
}
const gt = (e) => {
  const t = Math.round(R * 8e-3);
  for (let n = 0; n < t; n++) {
    const a = n / t;
    e[n] *= a, e[e.length - 1 - n] *= a;
  }
  return e;
};
function ce(e, t = 0.8) {
  let n = 1e-9;
  for (let r = 0; r < e.length; r++) n = Math.max(n, Math.abs(e[r]));
  const a = t / n;
  for (let r = 0; r < e.length; r++) e[r] *= a;
  return gt(e);
}
const de = () => new Float32Array(R * me), De = {
  hum: {
    label: "Hum",
    look: { lead: "A low hum", text: "glows on one side of the orb only: a fundamental near 110 Hz and two harmonics, stacked on the left of the map. Its slow swell breathes in and out, and its vibrato makes the glow wobble sideways a little." },
    make() {
      const e = de();
      let t = 0;
      for (let n = 0; n < e.length; n++) {
        const a = n / R, r = 110 + 4 * Math.sin(H * 5 * a) + 6 * Math.sin(H * 0.25 * a);
        t += H * r / R;
        const i = 0.62 + 0.38 * Math.sin(H * 0.5 * a - 1);
        e[n] = i * (Math.sin(t) + 0.5 * Math.sin(2 * t) + 0.25 * Math.sin(3 * t));
      }
      return ce(e);
    }
  },
  whistle: {
    label: "Whistle",
    look: { lead: "A whistle", text: "is one thin line, far round on the other side. Its pitch glides up and down, so the line slides across the sphere, and because older sound sits nearer the poles it leaves a curved trail behind it." },
    make() {
      const e = de();
      let t = 0;
      for (let n = 0; n < e.length; n++) {
        const a = n / R, r = 2300 + 900 * Math.sin(H * 0.25 * a);
        t += H * r / R, e[n] = (0.65 + 0.35 * Math.sin(H * 0.5 * a)) * Math.sin(t);
      }
      return ce(e);
    }
  },
  arpeggio: {
    label: "Arpeggio",
    look: { lead: "A plucked arpeggio", text: "climbs the pitch axis one note at a time. Each note lights a new spot and then fades from the equator outwards, so on the map the notes make a diagonal staircase, and on the orb a spiral of rings." },
    make() {
      const e = de(), t = [196, 392, 784, 1568];
      for (let n = 0; n < me / 2; n++)
        t.forEach((a, r) => {
          const i = Math.round((n * 2 + r * 0.5) * R), s = Math.round(0.9 * R);
          for (let l = 0; l < s && i + l < e.length; l++) {
            const u = l / R, p = Math.min(1, u / 5e-3) * Math.exp(-u / 0.28);
            e[i + l] += p * (Math.sin(H * a * u) + 0.35 * Math.sin(H * 2 * a * u));
          }
        });
      return ce(e);
    }
  },
  hiss: {
    label: "Hiss",
    look: { lead: 'An "sss"', text: "is noise, and noise has every pitch at once, mostly high. The whole high side of the orb lights together, as a wide band round the sphere, and then it all goes dark in the gap before the next one." },
    make() {
      const e = de(), t = qe(7);
      let n = 0;
      for (let a = 0; a < e.length; a++) {
        const r = t() * 2 - 1, i = r - n;
        n = r;
        const s = a / R, l = s % 1 / 0.45;
        e[a] = i * (l < 1 ? Math.pow(Math.sin(Math.PI * l), 2) : 0);
      }
      return ce(e);
    }
  },
  drums: {
    label: "Drums",
    look: { lead: "A drum loop", text: "uses all three zones. The kick is a low blob, the snare is a short burst across the middle that the hat tops with a bright ring high up, and each hit is a ring at the equator that spreads out to the poles as it ages." },
    make() {
      const e = de(), t = qe(3), n = (r, i, s) => {
        const l = Math.round(r * R);
        for (let u = 0; u < Math.round(i * R) && l + u < e.length; u++) e[l + u] += s(u / R);
      };
      for (let r = 0; r < me / 2; r++) {
        const i = r * 2;
        [0, 1].forEach((s) => n(i + s, 0.35, (l) => Math.exp(-l / 0.11) * Math.sin(H * (45 + 90 * Math.exp(-l / 0.04)) * l) * 1.1)), [0.5, 1.5].forEach((s) => n(i + s, 0.25, (l) => Math.exp(-l / 0.07) * ((t() * 2 - 1) * 0.7 + 0.5 * Math.sin(H * 190 * l))));
        for (let s = 0; s < 8; s++) n(i + s * 0.25 + 0.125, 0.06, (l) => Math.exp(-l / 0.014) * (t() * 2 - 1) * 0.35);
      }
      let a = 0;
      for (let r = 0; r < e.length; r++) {
        const i = e[r] - 0.995 * a;
        a = e[r], e[r] = e[r] * 0.85 + i * 0.15;
      }
      return ce(e);
    }
  },
  vowels: {
    label: "Vowels",
    look: { lead: "A voice", text: `is a buzz at a steady pitch, shaped by two resonances that move as the mouth changes shape, "ah" to "ee" to "oo". They show as two bright bumps that slide along the pitch axis, with the buzz's harmonics as fine ridges under them.` },
    make() {
      const e = de(), t = e.length, n = 160, a = [[700, 1200], [300, 2300], [320, 800], [700, 1200]], r = (l, u, p) => 1 / (1 + Math.pow((l - u) / p, 2)), i = new Float64Array(60), s = new Float64Array(60);
      for (let l = 0; l < t; l += n) {
        const u = l / R, p = u * 0.55 % 3, h = Math.floor(p), g = p - h, x = _(a[h][0], a[h + 1][0], g), d = _(a[h][1], a[h + 1][1], g), w = 118 + 22 * Math.sin(H * 0.6 * u) + 8 * Math.sin(H * 3.1 * u), m = Math.min(59, Math.floor(7e3 / w));
        for (let c = 1; c <= m; c++) s[c] = (r(w * c, x, 110) + 0.7 * r(w * c, d, 180)) / Math.sqrt(c);
        for (let c = l; c < Math.min(t, l + n); c++) {
          const y = c / R, b = 118 + 22 * Math.sin(H * 0.6 * y) + 8 * Math.sin(H * 3.1 * y);
          let k = 0;
          for (let v = 1; v <= m; v++)
            i[v] += H * b * v / R, k += s[v] * Math.sin(i[v]);
          const F = Math.pow(Math.max(0, Math.sin(H * 3.2 * y)), 1.2), N = 0.5 + 0.5 * Math.sin(H * 0.45 * y - 0.5);
          e[c] = k * F * (N > 0.3 ? 1 : 0) * (0.5 + 0.5 * N);
        }
      }
      return ce(e);
    }
  }
}, bt = ["vowels", "hum", "whistle", "arpeggio", "hiss", "drums"];
function wt(e, t = "custom") {
  const n = fe(e, V, 0.025, 0.15), a = new Float32Array(n.n * Y), r = new Float64Array(Y), i = { hann: !0, tilt: 3, nb: Y };
  for (let s = 0; s < n.n; s++) {
    We(e, Math.round((s + 1) * ct), i, r);
    for (let l = 0; l < Y; l++) a[s * Y + l] = ne(r[l], Je);
  }
  return {
    name: t,
    sig: e,
    n: n.n,
    rms: n.rms,
    level: n.level,
    lvl: Float32Array.from(n.level, (s) => ne(s, le)),
    pk: Float32Array.from(n.lo, (s, l) => ne(Math.max(Math.abs(s), Math.abs(n.hi[l])), le)),
    spec: a
  };
}
const je = /* @__PURE__ */ new Map();
function Oe(e) {
  let t = je.get(e);
  return t || (t = wt(De[e].make(), e), je.set(e, t)), t;
}
const Ae = /* @__PURE__ */ new Set(), ze = /* @__PURE__ */ new WeakMap();
let Ee = 0, $e = null;
function Ze() {
  for (const e of Ae)
    if (e.visible)
      try {
        e.draw(e.canvas, e.transport.t());
      } catch (t) {
        console.error(t);
      }
  Ee = Ae.size ? requestAnimationFrame(Ze) : 0;
}
function yt(e, t, n) {
  $e ??= new IntersectionObserver(
    (r) => r.forEach((i) => {
      const s = ze.get(i.target);
      s && (s.visible = i.isIntersecting);
    }),
    { rootMargin: "120px" }
  );
  const a = { canvas: e, draw: t, transport: n, visible: !1 };
  return Ae.add(a), ze.set(e, a), $e.observe(e), Ee || (Ee = requestAnimationFrame(Ze)), () => {
    Ae.delete(a), ze.delete(e), $e?.unobserve(e);
  };
}
class vt {
  t0 = typeof performance > "u" ? 0 : performance.now() / 1e3;
  frozen = null;
  ctx = null;
  src = null;
  gain = null;
  bufs = /* @__PURE__ */ new Map();
  listeners = /* @__PURE__ */ new Set();
  snapshot = { signal: "vowels", audio: !1, paused: !1, unavailable: !1 };
  getState = () => this.snapshot;
  getServerState = () => this.snapshot;
  subscribe = (t) => (this.listeners.add(t), () => {
    this.listeners.delete(t);
  });
  set(t) {
    this.snapshot = { ...this.snapshot, ...t }, this.listeners.forEach((n) => n());
  }
  latency() {
    return this.ctx && this.ctx.outputLatency || 0.02;
  }
  clockNow() {
    return this.snapshot.audio && this.ctx ? this.ctx.currentTime - this.latency() : performance.now() / 1e3;
  }
  /** Seconds since the start, on the clock in use. Unwrapped; the signals loop every 8 s. */
  t() {
    return this.frozen !== null ? this.frozen : this.clockNow() - this.t0;
  }
  setSignal(t) {
    t !== this.snapshot.signal && (this.set({ signal: t }), this.snapshot.audio && this.startSource());
  }
  setPaused(t) {
    t !== this.snapshot.paused && (t ? (this.frozen = this.t(), this.snapshot.audio && this.setSound(!1), this.set({ paused: !0 })) : (this.t0 = this.clockNow() - this.frozen, this.frozen = null, this.set({ paused: !1 })));
  }
  /** Starts or stops playback. Call it from a user gesture. Returns false when the browser has no audio. */
  setSound(t) {
    const n = this.t();
    if (t) {
      try {
        const a = window.AudioContext || window.webkitAudioContext;
        this.ctx = this.ctx ?? new a(), this.gain || (this.gain = this.ctx.createGain(), this.gain.gain.value = 0.5, this.gain.connect(this.ctx.destination)), this.ctx.resume();
      } catch {
        return this.set({ unavailable: !0 }), !1;
      }
      this.frozen = null, this.snapshot = { ...this.snapshot, audio: !0, paused: !1, unavailable: !1 }, this.t0 = this.ctx.currentTime - this.latency() - n, this.startSource(), this.set({});
    } else
      this.stopSource(), this.snapshot = { ...this.snapshot, audio: !1 }, this.t0 = performance.now() / 1e3 - n, this.set({});
    return !0;
  }
  startSource() {
    this.stopSource();
    const t = this.ctx, n = this.gain, a = this.snapshot.signal;
    let r = this.bufs.get(a);
    r || (r = t.createBuffer(1, R * me, R), r.copyToChannel(Oe(a).sig, 0), this.bufs.set(a, r));
    const i = t.createBufferSource();
    i.buffer = r, i.loop = !0, i.connect(n), i.start(0, B(this.t(), me)), this.src = i;
  }
  stopSource() {
    if (this.src) {
      try {
        this.src.stop();
      } catch {
      }
      this.src.disconnect(), this.src = null;
    }
  }
}
const pe = new vt();
function Se(e = pe) {
  return it(e.subscribe, e.getState, e.getServerState);
}
const oe = (e) => Oe(e.getState().signal);
function K(e) {
  const t = se(e);
  return t.current = e, t;
}
function U(e, t = pe) {
  const n = se(null), a = K(e);
  return lt(() => {
    const r = n.current;
    if (r)
      return yt(r, (i, s) => a.current(i, s), t);
  }, [t, a]), n;
}
function et(e, t) {
  e.current && e.current.innerHTML !== t && (e.current.innerHTML = t);
}
const Ue = /* @__PURE__ */ new Map();
function Pe(e) {
  const t = Ue.get(e);
  if (t) return t;
  const n = {
    n: e,
    ux: new Float32Array(e),
    uy: new Float32Array(e),
    uz: new Float32Array(e),
    age: new Float32Array(e),
    pitch: new Float32Array(e),
    fx: new Float32Array(e),
    fy: new Float32Array(e)
  }, a = Math.PI * (3 - Math.sqrt(5));
  for (let r = 0; r < e; r++) {
    const i = 1 - 2 * (r + 0.5) / e, s = Math.sqrt(1 - i * i), l = a * r;
    n.ux[r] = Math.cos(l) * s, n.uy[r] = i, n.uz[r] = Math.sin(l) * s;
    const u = Math.asin(i), p = Math.atan2(Math.sin(l), Math.cos(l));
    n.age[r] = Math.abs(u) / (Math.PI / 2), n.pitch[r] = Math.abs(p) / Math.PI, n.fx[r] = p / Math.PI * 1.35, n.fy[r] = u / (Math.PI / 2) * 0.95;
  }
  return Ue.set(e, n), n;
}
const A = { mint: "#5eead4", amber: "#ffb454", dim: "#7f9a93", fg: "#d6e5e0", faint: "#2a4a44" };
function kt(e) {
  let t = e.trim().replace(/^#/, "");
  if (t.length === 3 && (t = t.split("").map((a) => a + a).join("")), t.length !== 6) return [94, 234, 212];
  const n = parseInt(t, 16);
  return Number.isNaN(n) ? [94, 234, 212] : [n >> 16 & 255, n >> 8 & 255, n & 255];
}
function ae(e) {
  const t = Math.min(window.devicePixelRatio || 1, 2), n = e.clientWidth, a = e.clientHeight;
  (e.width !== Math.round(n * t) || e.height !== Math.round(a * t)) && (e.width = Math.round(n * t), e.height = Math.round(a * t));
  const r = e.getContext("2d");
  return r.setTransform(t, 0, 0, t, 0, 0), { ctx: r, w: n, h: a };
}
function L(e, t, n, a, r, i = 11, s = "left") {
  e.font = `400 ${i}px "IBM Plex Mono", ui-monospace, monospace`, e.fillStyle = r, e.textAlign = s, e.textBaseline = "alphabetic", e.fillText(t, n, a);
}
function tt(e, t, n) {
  const a = Math.min(Y - 1, Math.floor(n)), r = Math.min(Y - 1, a + 1), i = n - a, s = ge(e.spec, t, e.n, Y, a);
  return i === 0 ? s : _(s, ge(e.spec, t, e.n, Y, r), i);
}
function Fe(e, t, n) {
  const { ctx: a, w: r, h: i } = ae(e);
  a.clearRect(0, 0, r, i);
  const s = n.wrap ?? 1, l = n.gain ?? 0.5, u = n.analysis, p = (n.history ?? 0.8) * V, h = n.t * V - 0.5 + (n.mode === "spectrum" ? Ke : 0), g = (n.spin ?? 0.12) * n.t * s, x = _(0.55, 0.32, s), d = Math.sin(g), w = Math.cos(g), m = Math.sin(x), c = Math.cos(x), y = _(1.45, 1 + l, s) * 1.04, b = Math.min(r, i) / 2 / y, k = Math.min(r, i) / 360, F = r / 2, N = i / 2, v = [new Path2D(), new Path2D(), new Path2D(), new Path2D()];
  for (let M = 0; M < t.n; M++) {
    let z;
    n.mode === "spectrum" ? z = tt(u, h - t.age[M] * p, t.pitch[M] * (Y - 1)) : n.mode === "loudness" ? z = ge(u.lvl, h - t.age[M] * p, u.n) : z = n.value ?? 0;
    const T = l * z, W = t.ux[M], $ = t.uy[M], C = t.uz[M], I = _(t.fx[M], W, s) + _(0, W, s) * T, P = _(t.fy[M], $, s) + _(0, $, s) * T, E = _(0, C, s) + _(1, C, s) * T, S = I * w + E * d, q = -I * d + E * w, j = P * c - q * m, X = P * m + q * c, G = Qe((X / (s > 0.5 ? 1 : 1.2) + 1) / 2, 0, 1), Ce = (n.mode === "naive" ? 1.3 : 1 + 2.8 * z) * (0.75 + 0.25 * G) * k * (n.dotScale ?? 1), Re = F + S * b, He = N - j * b;
    if (n.colorBy) {
      const ye = n.colorBy === "age" ? _(172, 275, t.age[M]) : _(28, 285, t.pitch[M]);
      a.fillStyle = `hsla(${ye},85%,${n.colorBy === "age" ? _(66, 60, t.age[M]) : 62}%,${0.25 + 0.75 * G})`, a.beginPath(), a.arc(Re, He, Ce, 0, H), a.fill();
    } else {
      const ye = v[Math.min(3, Math.floor(G * 4))];
      ye.moveTo(Re + Ce, He), ye.arc(Re, He, Ce, 0, H);
    }
  }
  if (!n.colorBy) {
    const M = [0.18, 0.4, 0.7, 1], [z, T, W] = kt(n.tint ?? A.mint);
    v.forEach(($, C) => {
      a.fillStyle = `rgba(${z},${T},${W},${M[C]})`, a.fill($);
    });
  }
}
let ie = null, Xe = null;
const Mt = (e, t) => Math.log(e / ue) / Math.log(Le / ue) * t;
function nt(e, t, n, a) {
  ie || (ie = document.createElement("canvas"), ie.width = 120, ie.height = 72, Xe = ie.getContext("2d").createImageData(120, 72));
  const r = Xe, i = r.data, { ctx: s, w: l, h: u } = ae(e), p = n * V - 0.5 + Ke, h = a * V;
  for (let y = 0; y < 72; y++) {
    const b = 1 - y / 71;
    for (let k = 0; k < 120; k++) {
      const F = Math.pow(tt(t, p - b * h, k / 119 * (Y - 1)), 1.15), N = (y * 120 + k) * 4;
      i[N] = 6 + 88 * F, i[N + 1] = 11 + 223 * F, i[N + 2] = 11 + 201 * F, i[N + 3] = 255;
    }
  }
  ie.getContext("2d").putImageData(r, 0, 0), s.imageSmoothingEnabled = !0, s.imageSmoothingQuality = "high";
  const g = 8, x = l - 8, d = 8, w = u - 24, m = x - g, c = w - d;
  s.drawImage(ie, g, d, m, c), s.strokeStyle = "rgba(255,255,255,0.12)", s.lineWidth = 1, [100, 300, 1e3, 3e3].forEach((y) => {
    const b = g + Mt(y, m);
    s.beginPath(), s.moveTo(b, d), s.lineTo(b, w), s.stroke(), L(s, y >= 1e3 ? `${y / 1e3}k` : `${y}`, b, u - 8, A.dim, 10, "center");
  }), L(s, "Hz", g + m - 2, u - 8, A.dim, 10, "right"), s.strokeStyle = "rgba(255,180,84,0.6)", s.beginPath(), s.moveTo(g, w - 0.5), s.lineTo(x, w - 0.5), s.stroke(), L(s, "now", g + 6, w - 6, A.amber, 10), L(s, `${a.toFixed(1)} s ago`, g + 6, d + 13, A.dim, 10);
}
function st(e, t) {
  const n = Se(t);
  return e && typeof e == "object" ? e : Oe(e ?? n.signal);
}
function xt({
  signal: e,
  mode: t = "spectrum",
  dots: n = 1800,
  gain: a = 0.5,
  history: r = 0.8,
  wrap: i = 1,
  spin: s = 0.12,
  colorBy: l = null,
  tint: u,
  dotScale: p,
  transport: h = pe,
  className: g,
  style: x,
  "aria-label": d = "An orb of dots that moves with the sound"
}) {
  const w = st(e, h), m = K({ analysis: w, mode: t, dots: n, gain: a, history: r, wrap: i, spin: s, colorBy: l, tint: u, dotScale: p }), c = U((y, b) => {
    const k = m.current;
    Fe(y, Pe(k.dots), { analysis: k.analysis, t: b, mode: k.mode, gain: k.gain, history: k.history, wrap: k.wrap, spin: k.spin, colorBy: k.colorBy, tint: k.tint, dotScale: k.dotScale });
  }, h);
  return /* @__PURE__ */ o("canvas", { ref: c, className: g, role: "img", "aria-label": d, style: { display: "block", width: "100%", aspectRatio: "1 / 1", ...x } });
}
function Ot({ signal: e, history: t = 0.8, transport: n = pe, className: a, style: r }) {
  const i = st(e, n), s = K({ analysis: i, history: t }), l = U((u, p) => nt(u, s.current.analysis, p, s.current.history), n);
  return /* @__PURE__ */ o("canvas", { ref: l, className: a, role: "img", "aria-label": "A spectrogram: pitch across, time up", style: { display: "block", width: "100%", aspectRatio: "2.1 / 1", ...r } });
}
function Tt({ transport: e = pe, className: t }) {
  const n = Se(e);
  return /* @__PURE__ */ f("div", { className: t ? `rvo-bar ${t}` : "rvo-bar", children: [
    /* @__PURE__ */ o("span", { className: "rvo-brand", children: "Signal" }),
    /* @__PURE__ */ o("div", { className: "rvo-chips", role: "group", "aria-label": "Choose a sound", children: bt.map((a) => /* @__PURE__ */ o("button", { "aria-pressed": n.signal === a, onClick: () => e.setSignal(a), children: De[a].label }, a)) }),
    /* @__PURE__ */ o("span", { className: "rvo-spacer" }),
    /* @__PURE__ */ o(
      "button",
      {
        "aria-pressed": n.audio,
        title: "Play the signal through your speakers, and let the audio clock drive the pictures",
        onClick: () => e.setSound(!n.audio),
        children: n.unavailable ? "No audio here" : n.audio ? "Sound on" : "Sound off"
      }
    ),
    /* @__PURE__ */ o("button", { "aria-pressed": n.paused, onClick: () => e.setPaused(!n.paused), children: n.paused ? "Resume" : "Pause" })
  ] });
}
function Z({ id: e, eyebrow: t, lead: n, title: a, first: r, children: i }) {
  return /* @__PURE__ */ f("section", { className: r ? "rvo-part rvo-first" : "rvo-part", id: e, children: [
    /* @__PURE__ */ f("span", { className: "rvo-eyebrow", children: [
      n ? /* @__PURE__ */ o("b", { children: n }) : null,
      n && t ? " / " : "",
      t
    ] }),
    /* @__PURE__ */ o("h2", { children: a }),
    i
  ] });
}
const ee = ({ even: e, children: t }) => /* @__PURE__ */ o("div", { className: e ? "rvo-cols rvo-even" : "rvo-cols", children: t }), re = ({ children: e }) => /* @__PURE__ */ o("div", { className: "rvo-demo", children: e }), Q = ({ children: e, role: t, label: n }) => /* @__PURE__ */ o("div", { className: "rvo-controls", role: t, "aria-label": n, children: e }), Ne = ({ items: e }) => /* @__PURE__ */ o("div", { className: "rvo-legend", children: e.map(([t, n]) => /* @__PURE__ */ f("span", { children: [
  /* @__PURE__ */ o("i", { style: { background: t } }),
  n
] }, n)) });
function he({ label: e, value: t, onChange: n, min: a, max: r, step: i, format: s }) {
  const l = ht();
  return /* @__PURE__ */ f("label", { htmlFor: l, children: [
    e,
    " ",
    /* @__PURE__ */ o("input", { id: l, type: "range", min: a, max: r, step: i, value: t, onChange: (u) => n(+u.target.value) }),
    /* @__PURE__ */ o("output", { children: s ? s(t) : t })
  ] });
}
function be({ label: e, checked: t, onChange: n }) {
  return /* @__PURE__ */ f("label", { children: [
    /* @__PURE__ */ o("input", { type: "checkbox", checked: t, onChange: (a) => n(a.target.checked) }),
    " ",
    e
  ] });
}
function J({ children: e }) {
  const t = e.split(/«|»/);
  return /* @__PURE__ */ o("div", { className: "rvo-eq", children: t.map((n, a) => a % 2 ? /* @__PURE__ */ o("small", { children: n }, a) : /* @__PURE__ */ o(Ve, { children: n }, a)) });
}
const At = /\b(let|var|func|static|for|in|while|true|return|if)\b/g;
function we({ children: e }) {
  const t = e.split(`
`);
  return /* @__PURE__ */ o("pre", { className: "rvo-code", children: /* @__PURE__ */ o("code", { children: t.map((n, a) => {
    const r = n.indexOf("//"), s = (r >= 0 ? n.slice(0, r) : n).split(At).map((l, u) => u % 2 ? /* @__PURE__ */ o("span", { className: "k", children: l }, u) : l);
    return /* @__PURE__ */ f(Ve, { children: [
      s,
      r >= 0 ? /* @__PURE__ */ o("span", { className: "c", children: n.slice(r) }) : null,
      a < t.length - 1 ? `
` : ""
    ] }, a);
  }) }) });
}
const ot = ({ r: e }) => /* @__PURE__ */ o("div", { className: "rvo-readout", ref: e });
function St({ transport: e }) {
  const [t, n] = O(125), [a, r] = O(44100), i = K({ cps: t }), s = U((u, p) => {
    const { ctx: h, w: g, h: x } = ae(u);
    h.clearRect(0, 0, g, x);
    const d = oe(e), w = i.current.cps, m = 800, c = Math.floor(B(p * R * 0.3, d.sig.length - m - 4e3)) + 2e3, y = (F) => (F - c) / m * g, b = x / 2, k = x * 0.42;
    h.strokeStyle = "rgba(255,255,255,0.08)", h.beginPath(), h.moveTo(0, b), h.lineTo(g, b), h.stroke();
    for (let F = Math.floor(c / (R / w)); ; F++) {
      const N = Math.round(F * R / w), v = Math.round((F + 1) * R / w);
      if (N > c + m) break;
      let M = 1 / 0, z = -1 / 0, T = 0;
      for (let I = N; I < v; I++) {
        const P = d.sig[B(I, d.sig.length)];
        P < M && (M = P), P > z && (z = P), T += P * P;
      }
      const W = Math.sqrt(T / (v - N)), $ = y(N), C = y(v);
      h.fillStyle = "rgba(94,234,212,0.16)", h.fillRect($ + 1, b - z * k, C - $ - 2, (z - M) * k), h.strokeStyle = A.amber, h.lineWidth = 1.5, h.beginPath(), h.moveTo($ + 1, b - W * k), h.lineTo(C - 1, b - W * k), h.moveTo($ + 1, b + W * k), h.lineTo(C - 1, b + W * k), h.stroke(), h.strokeStyle = "rgba(94,234,212,0.5)", h.lineWidth = 1, h.beginPath(), h.moveTo($, 0), h.lineTo($, x), h.stroke(), $ > 0 && $ < g - 50 && L(h, `${N}`, $ + 3, x - 6, A.dim, 10);
    }
    h.strokeStyle = A.fg, h.lineWidth = 1.2, h.beginPath();
    for (let F = 0; F < m; F++) {
      const N = F / m * g, v = b - d.sig[c + F] * k;
      F ? h.lineTo(N, v) : h.moveTo(N, v);
    }
    h.stroke(), L(h, `edges at round(k · 16000 / ${w})`, 8, 14, A.dim, 10);
  }, e), l = Ge(() => {
    const u = a / t, p = Math.floor(u);
    return { spc: u, naive: p, drift: 60 - 60 * t * p / a, edges: [1, 2, 3, 4].map((h) => Math.round(h * a / t)) };
  }, [t, a]);
  return /* @__PURE__ */ o(Z, { id: "columns", lead: "Part 2", eyebrow: "maths and engineering", title: "Cut time into exact columns", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "Everything after this works on columns: fixed slices of time, each summarised by the lowest sample, the highest sample and the root mean square. The orb never touches raw samples again." }),
      /* @__PURE__ */ o("p", { children: "The edges have to be exact. A phone records at 44.1 or 48 kHz, and 120 columns a second does not divide 44,100. A column is 367.5 samples long. Truncate it to 367 and every column is a little short, so after a minute the picture has run ahead of the sound." }),
      /* @__PURE__ */ o(we, { children: `// the edge of column k is placed from the running sample count
static func edge(_ k: Int, _ sampleRate: Double, _ rate: Double) -> Int {
  Int((Double(k) * sampleRate / rate).rounded())
}` }),
      /* @__PURE__ */ o(J, { children: `edge(k) = round( k · sampleRate / columnsPerSecond )
«no running sum of rounded lengths, so errors cannot add up»` }),
      /* @__PURE__ */ o("p", { children: "Buffers from the microphone do not line up with columns either. The builder takes whatever it is given (512 samples, 441, 1) and finishes a column wherever an edge falls inside the buffer. The three summaries come from single vDSP calls, so this is cheap enough for the audio thread." })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: s, style: { aspectRatio: "2.2/1" } }),
      /* @__PURE__ */ f(Q, { children: [
        /* @__PURE__ */ o(he, { label: "columns per second", value: t, onChange: n, min: 40, max: 400, step: 5 }),
        /* @__PURE__ */ f("label", { children: [
          "recorded at ",
          /* @__PURE__ */ f("select", { value: a, onChange: (u) => r(+u.target.value), children: [
            /* @__PURE__ */ o("option", { value: 44100, children: "44.1 kHz" }),
            /* @__PURE__ */ o("option", { value: 48e3, children: "48 kHz" })
          ] })
        ] })
      ] }),
      /* @__PURE__ */ o(Ne, { items: [[A.mint, "lowest to highest sample"], [A.amber, "rms"]] }),
      /* @__PURE__ */ f("div", { className: "rvo-readout", children: [
        "At ",
        /* @__PURE__ */ f("b", { children: [
          (a / 1e3).toFixed(1),
          " kHz"
        ] }),
        " a column is ",
        /* @__PURE__ */ o("b", { children: l.spc.toFixed(2) }),
        " samples. Exact edges: ",
        l.edges.join(", "),
        " …",
        /* @__PURE__ */ o("br", {}),
        "Truncating to ",
        l.naive,
        " samples makes the picture finish a minute ",
        /* @__PURE__ */ f("b", { className: "rvo-amber", children: [
          (l.drift * 1e3).toFixed(0),
          " ms"
        ] }),
        " early."
      ] })
    ] })
  ] }) });
}
function Pt({ transport: e }) {
  const { signal: t } = Se(e), [n, a] = O(1), [r, i] = O(!1), s = K({ wrap: n, byPitch: r }), l = U((h, g) => Fe(h, Pe(1800), { analysis: oe(e), t: g, mode: "spectrum", wrap: s.current.wrap, colorBy: s.current.byPitch ? "pitch" : null }), e), u = U((h, g) => nt(h, oe(e), g, 0.8), e), p = De[t].look;
  return /* @__PURE__ */ o(Z, { id: "finished", lead: "The result", eyebrow: "what the finished orb does", title: "A spectrogram wrapped round a sphere", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "Where a dot sits down the sphere is time: the equator is the newest sound, and each moment ripples toward both poles as it ages. Where a dot sits round the sphere is pitch: low on one meridian, high on the opposite one. How far a dot is pushed out, and how large it is drawn, is how loud that pitch was at that moment." }),
      /* @__PURE__ */ o("p", { children: "The map on the right is the same data laid flat. Drag the slider to wrap it up." }),
      /* @__PURE__ */ f("div", { className: "rvo-look", children: [
        /* @__PURE__ */ o("b", { children: p.lead }),
        " ",
        p.text
      ] }),
      /* @__PURE__ */ f(Q, { children: [
        /* @__PURE__ */ f("label", { children: [
          "Flat ",
          /* @__PURE__ */ o("input", { type: "range", min: 0, max: 1, step: 0.01, value: n, "aria-label": "Wrap the map into a sphere", onChange: (h) => a(+h.target.value) }),
          " Orb"
        ] }),
        /* @__PURE__ */ o(be, { label: "colour by pitch", checked: r, onChange: i })
      ] })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: l, style: { aspectRatio: "1.25/1" } }),
      /* @__PURE__ */ o("canvas", { ref: u, style: { aspectRatio: "2.1/1" } }),
      /* @__PURE__ */ o("div", { className: "rvo-readout", children: "Bottom of the map: the newest sound. Top: 0.8 seconds ago. Left to right: 80 Hz to 7 kHz on a log scale, which is also front to back round the orb." })
    ] })
  ] }) });
}
let Ft = null;
const Ye = () => Ft ??= Float32Array.from({ length: R * me }, (e, t) => (0.5 + 0.3 * Math.sin(H * 0.6 * (t / R))) * Math.sin(H * 120 * (t / R)));
function Nt({ transport: e }) {
  const [t, n] = O(2), [a, r] = O(0.15), i = Ge(() => {
    const g = 1e3 / t;
    return { cps: g, a: fe(Ye(), g, 0, 1e-4), b: fe(Ye(), g, 0.025, 1e-4) };
  }, [t]), s = K(i), l = K(a), u = se({ key: "", c: null }), p = U((g, x) => {
    const { ctx: d, w, h: m } = ae(g);
    d.clearRect(0, 0, w, m);
    const c = 1.6, y = (v) => m - 18 - v / 0.8 * (m - 30), { cps: b, a: k, b: F } = s.current;
    d.strokeStyle = "rgba(255,255,255,0.07)", d.lineWidth = 1, [0, 0.2, 0.4, 0.6].forEach((v) => {
      d.beginPath(), d.moveTo(0, y(v)), d.lineTo(w, y(v)), d.stroke(), L(d, v.toFixed(1), 4, y(v) - 3, A.dim, 9);
    });
    const N = (v, M, z) => {
      d.strokeStyle = M, d.lineWidth = z, d.beginPath();
      for (let T = 0; T <= w; T++) {
        const W = y(v(x - c + T / w * c));
        T ? d.lineTo(T, W) : d.moveTo(T, W);
      }
      d.stroke();
    };
    N((v) => (0.5 + 0.3 * Math.sin(H * 0.6 * v)) / Math.SQRT2, A.faint, 2), N((v) => k.rms[B(Math.floor(v * b), k.n)], A.amber, 1.5), N((v) => F.rms[B(Math.floor(v * b), F.n)], A.mint, 2), L(d, "a 120 Hz hum, one pitch period = 8.3 ms", 8, 12, A.dim, 10);
  }, e), h = U((g, x) => {
    const d = oe(e), w = `${d.name}:${l.current}`;
    u.current.key !== w && (u.current = { key: w, c: fe(d.sig, V, 0.025, l.current) });
    const m = u.current.c, { ctx: c, w: y, h: b } = ae(g);
    c.clearRect(0, 0, y, b);
    const k = y * 0.34, F = 10, N = b - 28, v = (C) => F + C * (k - 2 * F), M = (C) => b - 18 - C * N;
    c.strokeStyle = "rgba(255,255,255,0.15)", c.lineWidth = 1, c.strokeRect(F, M(1), k - 2 * F, N), c.lineWidth = 2, c.strokeStyle = A.amber, c.beginPath(), c.moveTo(v(0), M(0)), c.lineTo(v(1), M(1)), c.stroke(), c.strokeStyle = A.mint, c.beginPath();
    for (let C = 0; C <= 100; C++) {
      const I = C / 100, P = v(I), E = M(ne(I, le));
      C ? c.lineTo(P, E) : c.moveTo(P, E);
    }
    c.stroke(), [0.01, 0.1].forEach((C) => {
      const I = M(ne(C, le));
      c.fillStyle = A.mint, c.beginPath(), c.arc(v(C), I, 3.5, 0, H), c.fill(), L(c, `${C} → ${Math.round(ne(C, le) * 100)}%`, v(C) + 6, I - 6, A.fg, 10);
    }), L(c, "amplitude", F, b - 4, A.dim, 10), L(c, "height", F + 2, 12, A.dim, 10);
    const z = 1.6, T = k + 12, W = y - T - 6;
    c.strokeStyle = "rgba(255,255,255,0.15)", c.lineWidth = 1, c.strokeRect(T, M(1), W, N);
    const $ = (C, I, P) => {
      c.strokeStyle = I, c.lineWidth = P, c.beginPath();
      for (let E = 0; E <= W; E++) {
        const S = M(ne(C[B(Math.floor((x - z + E / W * z) * V), m.n)], le));
        E ? c.lineTo(T + E, S) : c.moveTo(T + E, S);
      }
      c.stroke();
    };
    $(m.rms, "#4d6a64", 1.2), $(m.level, A.mint, 2.2), L(c, "time", T, b - 4, A.dim, 10);
  }, e);
  return /* @__PURE__ */ o(Z, { id: "loudness", lead: "Part 3", eyebrow: "maths", title: "Loudness without flicker", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "Root mean square is the sound's energy rather than its biggest swing:" }),
      /* @__PURE__ */ o(J, { children: "rms = √( (x₁² + x₂² + … + xₙ²) / n )" }),
      /* @__PURE__ */ o("p", { children: "A voice at 120 Hz repeats every 8.3 ms. If a column is shorter than that, its rms depends on which part of the wave it landed on: near a crest it is high, near a zero crossing it is low. Neighbouring columns disagree and the orb shimmers, even though the voice is steady." }),
      /* @__PURE__ */ o("p", { children: "The fix is to measure over a window of a few pitch periods. The builder keeps the last 25 ms of column sums and reports the rms of all of them. Drag the column length down and watch the amber line start to shake while the mint one holds still." }),
      /* @__PURE__ */ o("p", { children: "Then the shape of the response. Instant attack, so a hit shows at once. A release with a time constant (150 ms by default), so a sound fades the way a meter needle does, not as a flash." }),
      /* @__PURE__ */ o(J, { children: "level[k] = max( rms[k], level[k−1] · e^(−1 / (rate · release)) )" }),
      /* @__PURE__ */ o("p", { children: "Last, the scale. Speech spans 60 dB or more, so linear height makes a quiet word invisible next to a loud one. Heights are decibels:" }),
      /* @__PURE__ */ o(J, { children: `dB = 20 · log₁₀(amplitude)
height = clamp( (dB − floor) / −floor, 0, 1 )   «floor = −60 dB»` })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: p, style: { aspectRatio: "2.3/1" } }),
      /* @__PURE__ */ o(Q, { children: /* @__PURE__ */ o(he, { label: "column length", value: t, onChange: n, min: 2, max: 40, step: 1, format: (g) => `${g} ms` }) }),
      /* @__PURE__ */ o(Ne, { items: [[A.amber, "rms of one column"], [A.mint, "rms of the last 25 ms"], [A.faint, "true envelope"]] }),
      /* @__PURE__ */ o("canvas", { ref: h, style: { aspectRatio: "2.3/1" } }),
      /* @__PURE__ */ o(Q, { children: /* @__PURE__ */ o(he, { label: "release", value: a, onChange: r, min: 0.02, max: 0.6, step: 0.01, format: (g) => `${Math.round(g * 1e3)} ms` }) }),
      /* @__PURE__ */ o("div", { className: "rvo-readout", children: "Left: how amplitude becomes height. Right: the current sound, windowed rms (grey) and the level the orb uses (mint)." })
    ] })
  ] }) });
}
const Te = 640;
function Ct({ transport: e }) {
  const t = se({ hist: [], chunk: -1, value: 0, signal: "" }), n = U((r, i) => {
    const s = t.current, l = oe(e);
    s.signal !== l.name && (s.signal = l.name, s.hist.length = 0);
    const u = Math.floor(i * R / Te);
    if (u !== s.chunk) {
      s.chunk = u;
      let p = 0;
      for (let h = u * Te - Te; h < u * Te; h++) p = Math.max(p, Math.abs(l.sig[B(h, l.sig.length)]));
      s.value = p;
    }
    for (s.hist.push({ t: i, v: s.value }); s.hist.length && s.hist[0].t < i - 1.6; ) s.hist.shift();
    Fe(r, Pe(900), { analysis: l, t: i, mode: "naive", value: s.value });
  }, e), a = U((r, i) => {
    const { ctx: s, w: l, h: u } = ae(r);
    s.clearRect(0, 0, l, u);
    const p = oe(e), h = 1.6, g = (d) => (d - (i - h)) / h * l, x = (d) => u - 6 - d * (u - 12);
    s.strokeStyle = A.faint, s.lineWidth = 1.2, s.beginPath();
    for (let d = 0; d <= l; d += 2) {
      const w = i - h + d / l * h, m = Math.min(1, p.rms[Math.floor(B(w * V - 0.5, p.n))] * 1.4);
      d ? s.lineTo(d, x(m)) : s.moveTo(d, x(m));
    }
    s.stroke(), s.strokeStyle = A.amber, s.lineWidth = 2, s.beginPath(), t.current.hist.forEach((d, w) => {
      w ? s.lineTo(g(d.t), x(d.v)) : s.moveTo(g(d.t), x(d.v));
    }), s.stroke();
  }, e);
  return /* @__PURE__ */ f(Z, { id: "naive", first: !0, lead: "Start here", eyebrow: "the obvious version", title: "One number, one sphere", children: [
    /* @__PURE__ */ f(ee, { children: [
      /* @__PURE__ */ f("div", { children: [
        /* @__PURE__ */ o("p", { children: "A sphere of dots. Measure how loud the sound is right now. Push every dot out by that amount. It takes about ten lines and it does react to sound." }),
        /* @__PURE__ */ o(we, { children: `// every audio buffer
let loudness = buffer.map(abs).max()   // 0...1

// every screen frame
for dot in dots {
  dot.radius = 1 + 0.5 * loudness
}` }),
        /* @__PURE__ */ o("p", { children: "Try the Arpeggio, then the Hiss, then the Vowels. They are very different sounds and the orb does the same thing for all of them: it breathes. It cannot say which pitch, it has no memory of what came before, and the amber line on the right moves in steps." })
      ] }),
      /* @__PURE__ */ f(re, { children: [
        /* @__PURE__ */ o("canvas", { ref: n, style: { aspectRatio: "1.35/1" } }),
        /* @__PURE__ */ o("canvas", { ref: a, style: { aspectRatio: "4.2/1" } }),
        /* @__PURE__ */ o(Ne, { items: [[A.amber, "the one number the orb uses"], [A.faint, "what the sound really did"]] }),
        /* @__PURE__ */ o("div", { className: "rvo-readout", children: "The steps are audio buffers arriving (40 ms here, 10 to 20 ms on a phone) while the screen draws at 60 or 120 Hz." })
      ] })
    ] }),
    /* @__PURE__ */ f("div", { className: "rvo-problems", children: [
      /* @__PURE__ */ f("a", { className: "rvo-problem", href: "#columns", children: [
        /* @__PURE__ */ o("b", { children: "Drift" }),
        /* @__PURE__ */ o("span", { children: "Which samples belong to which frame? Round the wrong way and the picture slowly slides off the sound." }),
        /* @__PURE__ */ o("em", { children: "Part 2, exact columns" })
      ] }),
      /* @__PURE__ */ f("a", { className: "rvo-problem", href: "#loudness", children: [
        /* @__PURE__ */ o("b", { children: "Flicker" }),
        /* @__PURE__ */ o("span", { children: "The peak of a few milliseconds depends on where in a pitch wave you happened to land." }),
        /* @__PURE__ */ o("em", { children: "Part 3, loudness" })
      ] }),
      /* @__PURE__ */ f("a", { className: "rvo-problem", href: "#time", children: [
        /* @__PURE__ */ o("b", { children: "No memory" }),
        /* @__PURE__ */ o("span", { children: 'Only "now" is drawn. A sound that just ended is gone.' }),
        /* @__PURE__ */ o("em", { children: "Part 4, time on a sphere" })
      ] }),
      /* @__PURE__ */ f("a", { className: "rvo-problem", href: "#smooth", children: [
        /* @__PURE__ */ o("b", { children: "Stair-steps" }),
        /* @__PURE__ */ o("span", { children: "Audio arrives on its own schedule and the screen draws on another." }),
        /* @__PURE__ */ o("em", { children: "Part 5, playhead" })
      ] }),
      /* @__PURE__ */ f("a", { className: "rvo-problem", href: "#pitch", children: [
        /* @__PURE__ */ o("b", { children: "One number" }),
        /* @__PURE__ */ o("span", { children: "A hum, a whistle and a hiss can be equally loud. The sphere cannot tell them apart." }),
        /* @__PURE__ */ o("em", { children: "Part 6, pitch" })
      ] }),
      /* @__PURE__ */ f("a", { className: "rvo-problem", href: "#ring", children: [
        /* @__PURE__ */ o("b", { children: "Two threads" }),
        /* @__PURE__ */ o("span", { children: "The audio thread may not wait for the screen, and the screen must not read half-written data." }),
        /* @__PURE__ */ o("em", { children: "Part 7, lock-free ring" })
      ] })
    ] })
  ] });
}
function Rt({ transport: e }) {
  const [t, n] = O(!0), [a, r] = O(3), [i, s] = O(24), [l, u] = O(null), p = K({ hann: t, tilt: a, nb: i }), h = se(new Float64Array(48)), g = U((d, w) => {
    const m = oe(e), { ctx: c, w: y, h: b } = ae(d), k = p.current;
    c.clearRect(0, 0, y, b);
    const F = Math.floor(w * R), N = b * 0.36, v = N / 2 + 4, M = N * 0.42;
    c.strokeStyle = "rgba(255,255,255,0.08)", c.lineWidth = 1, c.beginPath(), c.moveTo(0, v), c.lineTo(y, v), c.stroke();
    const z = (P) => m.sig[B(F - D + P, m.sig.length)], T = (P, E, S) => {
      c.strokeStyle = E, c.lineWidth = S, c.beginPath();
      for (let q = 0; q < y; q++) {
        const j = v - P(Math.floor(q / y * D)) * M;
        q ? c.lineTo(q, j) : c.moveTo(q, j);
      }
      c.stroke();
    };
    T(z, "rgba(214,229,224,0.3)", 1), k.hann && T((P) => z(P) * Be[P], A.mint, 1.4), L(c, `the last 64 ms${k.hann ? ", through a Hann window" : ", cut off square"}`, 8, 13, A.dim, 10);
    const W = We(m.sig, F, k, h.current), $ = b - 22, C = $ - N - 16, I = y / k.nb;
    c.strokeStyle = "rgba(255,255,255,0.07)";
    for (let P = 0; P <= 1; P += 0.25)
      c.beginPath(), c.moveTo(0, $ - P * C), c.lineTo(y, $ - P * C), c.stroke();
    for (let P = 0; P < k.nb; P++) {
      const E = ne(W[P], Je), S = E * C;
      c.fillStyle = `rgba(94,234,212,${0.35 + 0.65 * E})`, c.fillRect(P * I + 1.5, $ - S, I - 3, S);
    }
    [100, 300, 1e3, 3e3].forEach((P) => L(c, P >= 1e3 ? `${P / 1e3}k` : `${P}`, Math.log(P / ue) / Math.log(Le / ue) * k.nb * I, b - 6, A.dim, 10, "center")), L(c, "Hz, log scale: every band the same musical width", y - 6, b - 6, A.dim, 10, "right");
  }, e);
  return /* @__PURE__ */ o(Z, { id: "pitch", lead: "Part 6", eyebrow: "maths", title: "Pitch: a spectrum every column", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ f("p", { children: [
        "For each column the last ",
        /* @__PURE__ */ o("code", { children: "N" }),
        " samples go through a Hann window and a Fourier transform. A window is needed because the transform assumes the slice repeats forever. Cut a tone off sharply and the seam spreads its energy across every frequency. Switch the window off on the right to see the skirts."
      ] }),
      /* @__PURE__ */ o(J, { children: "w[n] = ½ − ½ cos(2πn / N)" }),
      /* @__PURE__ */ o("p", { children: "The numbers are scaled so they mean something. A pure tone of amplitude A should read A/√2, its rms, in whichever band it falls in. With Σw² the window's energy and X the transform:" }),
      /* @__PURE__ */ o(J, { children: `power[k] = 2 · |X[k]|² / (N · Σw²)
band power = Σ power[k] over the bins inside the band
band value = √(band power)         «a sine A gives A / √2»` }),
      /* @__PURE__ */ o("p", { children: "Bands are 24 steps on a log scale from 80 Hz to 8 kHz, so each is the same musical width (a little over three semitones). A band edge rarely falls on a bin, so the bin it cuts through is counted by the fraction inside. The band powers add up to the signal's mean square, which the tests check." }),
      /* @__PURE__ */ f("p", { children: [
        "Speech loses 6 dB or more per octave, so the top bands would sit near silence. A display tilt adds ",
        /* @__PURE__ */ o("code", { children: "tilt" }),
        " dB per octave above 1 kHz. Set it to 0 and the numbers are exact."
      ] }),
      /* @__PURE__ */ f("p", { children: [
        "One more detail: a window of ",
        /* @__PURE__ */ o("code", { children: "N" }),
        " samples describes the moment half a window ago. The orb reads the spectrum ",
        /* @__PURE__ */ o("code", { children: "N/2" }),
        " samples later than the loudness, so a vowel's pitch and its volume line up."
      ] })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: g, style: { aspectRatio: "1.55/1" } }),
      /* @__PURE__ */ f(Q, { children: [
        /* @__PURE__ */ o(be, { label: "Hann window", checked: t, onChange: n }),
        /* @__PURE__ */ o(he, { label: "tilt", value: a, onChange: r, min: 0, max: 6, step: 0.5, format: (d) => `${d} dB/oct` }),
        /* @__PURE__ */ o(he, { label: "bands", value: i, onChange: s, min: 8, max: 48, step: 1 })
      ] }),
      /* @__PURE__ */ o(Q, { children: /* @__PURE__ */ o("button", { onClick: () => {
        const w = Float32Array.from({ length: 4096 }, (b, k) => 0.5 * Math.sin(H * 1e3 * k / R)), m = new Float64Array(24);
        We(w, 2048, { hann: !0, tilt: 0, nb: 24 }, m);
        let c = 0, y = 0;
        m.forEach((b) => {
          c += b * b, y = Math.max(y, b);
        }), u({ max: y, ms: c });
      }, children: "Check the scaling" }) }),
      /* @__PURE__ */ o("div", { className: "rvo-readout", children: l ? /* @__PURE__ */ f(rt, { children: [
        "Sine, amplitude 0.5, 1 kHz, tilt 0.",
        /* @__PURE__ */ o("br", {}),
        "Loudest band: ",
        /* @__PURE__ */ o("b", { children: l.max.toFixed(3) }),
        " (A/√2 = 0.354). Bands' squares add to ",
        /* @__PURE__ */ o("b", { children: l.ms.toFixed(4) }),
        " (mean square = 0.1250)."
      ] }) : "A sine of amplitude 0.5 should read 0.354 and have mean square 0.125." })
    ] })
  ] }) });
}
const te = 16, Ie = (e, t) => (e % t + t) % t;
function Ht({ transport: e }) {
  const t = se(null), n = se({ w: 0, nextW: 0, burst: 0, phase: "idle", end: 0, real: 0, p: 0, since: 0, msg: "idle", clean: 0, retries: 0, last: 0 }), a = U((r, i) => {
    const s = n.current, l = Math.min(0.1, Math.max(0, i - s.last));
    s.last = i;
    const u = () => {
      s.phase = "copy", s.end = s.w, s.real = Math.min(8, s.end), s.p = 0, s.msg = `acquire load: written = ${s.end}`;
    };
    if (!e.getState().paused) {
      for (s.nextW -= l; s.nextW <= 0; )
        s.w++, s.nextW += s.burst > 0 ? 0.05 : 0.32, s.burst > 0 && s.burst--;
      if (s.phase === "idle")
        s.since += l, s.since > 1.6 && u();
      else if (s.phase === "copy")
        s.p += l / 1.5, s.p >= 1 && (s.w - (s.end - s.real) > te ? (s.retries++, s.msg = `written is now ${s.w}: the writer lapped the copy, so copy again`, s.phase = "torn") : (s.clean++, s.msg = `written is ${s.w}: copy is whole, return it`, s.phase = "done"), s.since = 0);
      else if (s.since += l, s.since > 0.9) {
        const b = s.phase === "torn";
        s.phase = "idle", s.since = 0, b && u();
      }
    }
    const { ctx: p, w: h, h: g } = ae(r);
    p.clearRect(0, 0, h, g);
    const x = h / 2, d = g / 2 - 4, w = Math.min(h, g) * 0.36, m = w * 0.62, c = (b) => -Math.PI / 2 + (b + 0.5) / te * H;
    for (let b = 0; b < te; b++) {
      const k = s.w - 1 - Ie(s.w - 1 - b, te), F = c(b) - H / te / 2 + 0.02, N = c(b) + H / te / 2 - 0.02;
      let v = !1;
      if (s.phase !== "idle")
        for (let M = 0; M < s.real; M++) Ie(s.end - s.real + M, te) === b && (s.phase !== "copy" || M < s.p * s.real) && (v = !0);
      if (p.beginPath(), p.arc(x, d, w, F, N), p.arc(x, d, m, N, F, !0), p.closePath(), p.fillStyle = k < 0 ? "#0c1b19" : v ? s.phase === "torn" ? "rgba(251,113,133,0.75)" : "rgba(94,234,212,0.85)" : "rgba(94,234,212,0.18)", p.fill(), k >= 0) {
        const M = (w + m) / 2;
        L(p, `${k}`, x + Math.cos(c(b)) * M, d + Math.sin(c(b)) * M + 3, v ? "#04201c" : A.dim, 10, "center");
      }
    }
    const y = c(Ie(s.w, te));
    p.strokeStyle = A.amber, p.lineWidth = 2, p.beginPath(), p.moveTo(x + Math.cos(y) * (m - 4), d + Math.sin(y) * (m - 4)), p.lineTo(x + Math.cos(y) * (w + 10), d + Math.sin(y) * (w + 10)), p.stroke(), L(p, "next write", x + Math.cos(y) * (w + 14), d + Math.sin(y) * (w + 14), A.amber, 10, Math.cos(y) > 0 ? "left" : "right"), L(p, "audio thread", x, d - 6, A.amber, 11, "center"), L(p, "writes, then publishes", x, d + 9, A.dim, 10, "center"), L(p, "screen thread copies the newest 8", x, d + 24, A.mint, 10, "center"), et(t, `slots: <b>${te}</b> (a power of two) · written: <b>${s.w}</b> · clean copies: <b>${s.clean}</b> · retries: <b class="rvo-amber">${s.retries}</b><br>${s.msg}`);
  }, e);
  return /* @__PURE__ */ o(Z, { id: "ring", lead: "Part 7", eyebrow: "engineering", title: "Two threads, no lock", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "The microphone callback runs on a real-time thread with a deadline of a few milliseconds. It must never wait for the screen, take a lock, allocate memory, or print. The screen thread has to read what it wrote." }),
      /* @__PURE__ */ o("p", { children: "The answer is a ring: a fixed array and one counter. The audio thread writes into the slot, then publishes the new count with a release store. The screen thread loads the count with an acquire load, so it can never see a slot that is still being filled." }),
      /* @__PURE__ */ o(we, { children: `func append(_ column: Column) {            // audio thread only
  let index = written.load(ordering: .relaxed)
  slots[index & mask] = column
  written.store(index + 1, ordering: .releasing)
}

func snapshot(...) {                       // screen thread only
  while true {
    let end = written.load(ordering: .acquiring)
    copy the newest n slots
    // the writer lapped us mid-copy? throw it away and copy again
    if written.load(ordering: .acquiring) - (end - real) <= capacity { return }
  }
}` }),
      /* @__PURE__ */ o("p", { children: "The size is a power of two, so wrapping is a bitwise and instead of a modulo. The retry means what is drawn is never a mixture of old and new. Press the button to force the writer to lap the reader and watch the copy start again." })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: a, style: { aspectRatio: "1.45/1" } }),
      /* @__PURE__ */ o(Q, { children: /* @__PURE__ */ o("button", { onClick: () => {
        n.current.burst = 20;
      }, children: "Lap the reader" }) }),
      /* @__PURE__ */ o(ot, { r: t })
    ] })
  ] }) });
}
const zt = [["latest", "newest column"], ["nearest", "nearest"], ["linear", "linear"], ["cubic", "cubic"]];
function $t({ transport: e }) {
  const [t, n] = O("cubic"), [a, r] = O(40), [i, s] = O(!0), [l, u] = O(!0), p = K({ mode: t, cps: a, jit: i, pll: l }), h = se(null), g = se({ hist: [], phase: NaN, period: 1 / 60, key: "", L: null, rnd: qe(11), signal: "" }), x = U((d, w) => {
    const m = g.current, c = oe(e), { mode: y, cps: b, jit: k, pll: F } = p.current;
    m.signal !== c.name && (m.signal = c.name, m.hist.length = 0);
    const N = `${c.name}:${b}`;
    if (m.key !== N) {
      m.key = N;
      const S = fe(c.sig, b, 0.025, 0.15);
      m.L = { n: S.n, d: Float32Array.from(S.level, (q) => ne(q, le)) };
    }
    const v = m.L, M = 0.06;
    if (!e.getState().paused) {
      const S = w + (k ? (m.rnd() - 0.5) * 8e-3 : 0);
      let q = S;
      if (F) {
        if (Number.isNaN(m.phase) || S - m.phase >= 0.5) m.phase = S;
        else {
          const X = m.phase + m.period, G = Math.max(-m.period, Math.min(2 * m.period, S - X));
          m.period += 0.01 * G, m.phase = X + 0.15 * G;
        }
        q = m.phase;
      }
      let j;
      if (y === "latest") {
        const X = Math.floor((w - 4e-3 * m.rnd()) / 0.0107) * 0.0107;
        j = v.d[B(Math.floor(X * b) - 1, v.n)];
      } else {
        const X = (q - M) * b - 0.5;
        if (y === "nearest") j = v.d[B(Math.round(X), v.n)];
        else if (y === "linear") {
          const G = Math.floor(X);
          j = _(v.d[B(G, v.n)], v.d[B(G + 1, v.n)], X - G);
        } else j = ge(v.d, X, v.n);
      }
      m.hist.push({ t: w, v: j, truth: ge(c.lvl, (w - (y === "latest" ? 0 : M)) * V - 0.5, c.n) });
    }
    const z = 0.7;
    for (; m.hist.length && m.hist[0].t < w - z; ) m.hist.shift();
    const { ctx: T, w: W, h: $ } = ae(d);
    T.clearRect(0, 0, W, $);
    const C = (S) => (S - (w - z)) / z * W, I = (S) => $ - 14 - S * ($ - 28);
    T.strokeStyle = "rgba(255,255,255,0.07)", T.lineWidth = 1;
    for (let S = 0; S <= 1; S += 0.25)
      T.beginPath(), T.moveTo(0, I(S)), T.lineTo(W, I(S)), T.stroke();
    T.strokeStyle = A.faint, T.lineWidth = 3, T.beginPath(), m.hist.forEach((S, q) => {
      q ? T.lineTo(C(S.t), I(S.truth)) : T.moveTo(C(S.t), I(S.truth));
    }), T.stroke(), T.strokeStyle = A.mint, T.lineWidth = 1.6, T.beginPath(), m.hist.forEach((S, q) => {
      q ? T.lineTo(C(S.t), I(S.v)) : T.moveTo(C(S.t), I(S.v));
    }), T.stroke(), T.fillStyle = A.mint, m.hist.forEach((S) => {
      T.beginPath(), T.arc(C(S.t), I(S.v), 1.8, 0, H), T.fill();
    });
    const P = m.hist, E = P.length;
    if (E > 8) {
      let S = 0;
      for (let q = 2; q < E; q++) {
        const j = P[q].v - 2 * P[q - 1].v + P[q - 2].v;
        S += j * j;
      }
      et(h, `roughness <b>${(Math.sqrt(S / (E - 2)) * 100).toFixed(2)}</b> (lower is smoother). Each dot is one screen frame.`);
    }
  }, e);
  return /* @__PURE__ */ o(Z, { id: "smooth", lead: "Part 5", eyebrow: "maths and engineering", title: "A playhead on the audio clock", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: 'A screen frame should not ask "what is the newest column?". Columns appear when the audio thread is scheduled, which jitters, so the newest column is a moving, stepping target. Instead the audio thread tells a shared clock when each buffer started, and the screen asks "where in the stream is now, minus a fixed delay?"' }),
      /* @__PURE__ */ o(we, { children: `// StreamClock: smooth the offset between audio time and host time
smoothed += gain * (raw - smoothed)       // gain = 0.02

// Playhead: draw a fixed moment behind the audio
position = min(newest - 1,
               streamTime(hostNow - latency) * rate - 0.5)` }),
      /* @__PURE__ */ o("p", { children: "The latency (60 ms) covers the audio buffer, the time to finish a column, and the one column of look-ahead the interpolation needs." }),
      /* @__PURE__ */ o("p", { children: "The system also reports frame times with a millisecond or two of noise. Used raw, that noise becomes shake. A phase-locked loop follows the steady beat of the frames:" }),
      /* @__PURE__ */ o(we, { children: `predicted = phase + period
error = clamp(measured - predicted, -period, 2 * period)
period += 0.01 * error
phase  = predicted + 0.15 * error` }),
      /* @__PURE__ */ o("p", { children: "Last, the playhead lands between two columns. Reading the nearest one gives steps. Linear gives a corner at every column. Catmull-Rom runs a cubic through the four neighbours, so the value and its slope are both continuous:" }),
      /* @__PURE__ */ o(J, { children: "p(t) = ½ · [ 2p₁ + (p₂ − p₀)t + (2p₀ − 5p₁ + 4p₂ − p₃)t² + (3p₁ − p₀ − 3p₂ + p₃)t³ ]" })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: x, style: { aspectRatio: "2/1" } }),
      /* @__PURE__ */ o(Q, { role: "radiogroup", label: "How the screen reads the columns", children: zt.map(([d, w]) => /* @__PURE__ */ f("label", { children: [
        /* @__PURE__ */ o("input", { type: "radio", name: "rvo-read", checked: t === d, onChange: () => n(d) }),
        " ",
        w
      ] }, d)) }),
      /* @__PURE__ */ f(Q, { children: [
        /* @__PURE__ */ o(he, { label: "columns per second", value: a, onChange: r, min: 15, max: 125, step: 5 }),
        /* @__PURE__ */ o(be, { label: "noisy frame times", checked: i, onChange: s }),
        /* @__PURE__ */ o(be, { label: "smooth them (PLL)", checked: l, onChange: u })
      ] }),
      /* @__PURE__ */ o(Ne, { items: [[A.mint, "drawn each frame"], [A.faint, "what the sound did"]] }),
      /* @__PURE__ */ o(ot, { r: h })
    ] })
  ] }) });
}
const It = [
  ["Exact columns", "Feed audio in buffers of many sizes; the column count and edges match the sample count every time."],
  ["A / √2", "A pure sine of amplitude A reads A/√2 in its spectrum band."],
  ["Energy", "The squares of the band values add up to the signal's mean square."],
  ["Aligned hops", "Spectrum frame k and column k end on the same sample."],
  ["No flicker", "A windowed loudness varies far less than a single column's on a steady tone."],
  ["Pitch map", "Each dot's pitch equals its longitude from the definition, the same on both sides."],
  ["Torn reads", "A reader that is lapped by the writer retries and returns whole columns."]
], qt = [
  ["sample rate", "the microphone's, typically 48 kHz"],
  ["columns per second", "120"],
  ["loudness window", "25 ms, then 150 ms release"],
  ["spectrum", "2048-point FFT, 24 bands, 80 Hz to 8 kHz"],
  ["display tilt", "+3 dB per octave above 1 kHz"],
  ["decibel floor", "−60 dB loudness, −66 dB spectrum"],
  ["playhead delay", "60 ms"],
  ["history", "0.8 s across the sphere"],
  ["dots", "1,800, four depth layers"],
  ["spin", "0.12 rad/s, tipped 0.32 rad"]
], at = ({ head: e, rows: t }) => /* @__PURE__ */ o("div", { className: "rvo-table", children: /* @__PURE__ */ f("table", { children: [
  /* @__PURE__ */ o("thead", { children: /* @__PURE__ */ f("tr", { children: [
    /* @__PURE__ */ o("th", { children: e[0] }),
    /* @__PURE__ */ o("th", { children: e[1] })
  ] }) }),
  /* @__PURE__ */ o("tbody", { children: t.map(([n, a]) => /* @__PURE__ */ f("tr", { children: [
    /* @__PURE__ */ o("td", { children: n }),
    /* @__PURE__ */ o("td", { children: a })
  ] }, n)) })
] }) });
function Wt() {
  return /* @__PURE__ */ o(Z, { id: "tests", lead: "Part 8", eyebrow: "engineering", title: "Proving the maths", children: /* @__PURE__ */ f(ee, { even: !0, children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "The risk in a picture is that it looks plausible while being wrong. So each piece of maths has a test with a known answer, written from the definition and not from what the code happens to output." }),
      /* @__PURE__ */ o("p", { children: "The tests run on the Mac with synthetic signals and need no microphone. There are 33 across the package." })
    ] }),
    /* @__PURE__ */ o(at, { head: ["Property", "How it is checked"], rows: It })
  ] }) });
}
function Et() {
  return /* @__PURE__ */ o(Z, { id: "perf", lead: "Part 9", eyebrow: "engineering", title: "Does it need Metal?", children: /* @__PURE__ */ f(ee, { even: !0, children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "The orb is 1,800 dots. The work per frame is small: about eight table reads per dot, then a rotation and a circle. Two choices keep it cheap in SwiftUI's Canvas. Dots are sorted into four depth layers and each layer is a single path with a single fill, so there are four draw calls and not 1,800. And nothing allocates inside the frame." }),
      /* @__PURE__ */ o("p", { children: "A readout in the corner of the app shows the average draw time. The rule for going to Metal is written down before measuring:" }),
      /* @__PURE__ */ o(J, { children: `draw time > ~4 ms at 120 Hz, or dropped frames  →  Metal
(a 120 Hz frame is 8.3 ms; leave half of it for the system)` }),
      /* @__PURE__ */ o("p", { children: "What Metal would add: exact frame pacing with CAMetalDisplayLink, twenty to fifty times more dots, and glow. If the Canvas stays under budget, none of that is worth the extra code." })
    ] }),
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o(at, { head: ["Setting", "Value in the app"], rows: qt }),
      /* @__PURE__ */ o("p", { className: "rvo-note", style: { marginTop: 12 }, children: "The demos on this page run the same maths in JavaScript at 16 kHz with a 1024-point FFT, so everything works in a browser." })
    ] })
  ] }) });
}
function Lt({ transport: e }) {
  const [t, n] = O(0.8), [a, r] = O(!0), i = K({ hist: t, byAge: a }), s = U((l, u) => Fe(l, Pe(900), { analysis: oe(e), t: u, mode: "loudness", history: i.current.hist, colorBy: i.current.byAge ? "age" : null }), e);
  return /* @__PURE__ */ o(Z, { id: "time", lead: "Part 4", eyebrow: "maths", title: "Time on a sphere", children: /* @__PURE__ */ f(ee, { children: [
    /* @__PURE__ */ f("div", { children: [
      /* @__PURE__ */ o("p", { children: "Dots need to sit evenly on a sphere, with no clumps at the poles and no visible rows. The Fibonacci lattice does that with one loop. Heights are evenly spaced, and each dot is turned by the golden angle from the one before." }),
      /* @__PURE__ */ o(J, { children: `yᵢ = 1 − 2(i + ½) / N
θᵢ = i · π(3 − √5)       «≈ 137.5°, the golden angle»
(x, z) = √(1 − y²) · (cos θ, sin θ)` }),
      /* @__PURE__ */ o("p", { children: "Height gives age. The equator is the newest column and the poles are the oldest, so each new sound appears as a ring at the equator and spreads toward both poles as it ages:" }),
      /* @__PURE__ */ o(J, { children: `age = |asin y| / (π/2)          «0 at the equator, 1 at a pole»
column shown = playhead − age · history` }),
      /* @__PURE__ */ o("p", { children: "The history slider is how many seconds the sphere spans. The orb in the app uses 0.8." })
    ] }),
    /* @__PURE__ */ f(re, { children: [
      /* @__PURE__ */ o("canvas", { ref: s, style: { aspectRatio: "1.15/1" } }),
      /* @__PURE__ */ f(Q, { children: [
        /* @__PURE__ */ o(he, { label: "history", value: t, onChange: n, min: 0.3, max: 2, step: 0.05, format: (l) => `${l.toFixed(2)} s` }),
        /* @__PURE__ */ o(be, { label: "colour by age", checked: a, onChange: r })
      ] }),
      /* @__PURE__ */ o("div", { className: "rvo-readout", children: "Mint is now. Violet is the oldest sound the sphere still shows. Loudness only here; the next parts add smoothness and pitch." })
    ] })
  ] }) });
}
function _t({ transport: e = pe, hideBar: t, className: n }) {
  return Se(e), /* @__PURE__ */ f("div", { className: n ? `rvo ${n}` : "rvo", children: [
    t ? null : /* @__PURE__ */ o(Tt, { transport: e }),
    /* @__PURE__ */ f("main", { children: [
      /* @__PURE__ */ f("section", { className: "rvo-hero", children: [
        /* @__PURE__ */ f("div", { children: [
          /* @__PURE__ */ f("span", { className: "rvo-eyebrow", children: [
            "Waveform experiment ",
            /* @__PURE__ */ o("b", { children: "/" }),
            " Swift, Accelerate, no Metal"
          ] }),
          /* @__PURE__ */ f("h1", { children: [
            "An orb that ",
            /* @__PURE__ */ o("em", { children: "listens" })
          ] }),
          /* @__PURE__ */ o("p", { className: "rvo-lede", children: "Every dot is one moment of sound at one pitch. Hum, whistle or drum and different parts of the sphere move. This page builds it from the version that does not work to the one that does, with the maths and the engineering at each step." })
        ] }),
        /* @__PURE__ */ o("div", { className: "rvo-hero-orb", children: /* @__PURE__ */ o(xt, { transport: e }) }),
        /* @__PURE__ */ o("p", { className: "rvo-note rvo-center", children: "Synthetic sounds, drawn the way the app draws a live microphone. Pick a different one in the bar above, and press Sound to hear it." })
      ] }),
      /* @__PURE__ */ o(Ct, { transport: e }),
      /* @__PURE__ */ o(Pt, { transport: e }),
      /* @__PURE__ */ o(St, { transport: e }),
      /* @__PURE__ */ o(Nt, { transport: e }),
      /* @__PURE__ */ o(Lt, { transport: e }),
      /* @__PURE__ */ o($t, { transport: e }),
      /* @__PURE__ */ o(Rt, { transport: e }),
      /* @__PURE__ */ o(Ht, { transport: e }),
      /* @__PURE__ */ o(Wt, {}),
      /* @__PURE__ */ o(Et, {}),
      /* @__PURE__ */ o("footer", { children: /* @__PURE__ */ f("p", { children: [
        "The Swift package is ",
        /* @__PURE__ */ o("code", { children: "WaveformCore" }),
        " (columns, rings, clocks, spectrum, orb model) and ",
        /* @__PURE__ */ o("code", { children: "WaveformApp" }),
        " (the SwiftUI views). The plain orb is tagged ",
        /* @__PURE__ */ o("code", { children: "orb-v1" }),
        "; this one lives on the ",
        /* @__PURE__ */ o("code", { children: "spectrum-orb" }),
        " branch. Next to try: a damped wave along the time axis, and Metal if the draw time asks for it."
      ] }) })
    ] })
  ] });
}
export {
  V as CPS,
  me as DUR,
  D as FFT_N,
  Le as HI_HZ,
  ue as LO_HZ,
  Y as NB,
  _t as OrbExplainer,
  De as SIGNALS,
  bt as SIGNAL_ORDER,
  R as SR,
  Tt as SignalPicker,
  Ot as SpectrumMap,
  vt as Transport,
  xt as VoiceOrb,
  wt as analyse,
  We as analyseFrame,
  Oe as analysisFor,
  ft as bandsFor,
  fe as columns,
  pe as defaultTransport,
  Se as useTransport
};
//# sourceMappingURL=index.js.map
