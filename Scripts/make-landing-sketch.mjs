// Draws the pencil sketch used as the landing page's icon (kehai.html in the sibling
// littlebobert.github.io repository) as a flipbook, in the way of Karui's, Umete's and
// Sasu's: windows drop onto the desk askew, the front one changes as if switched to, then
// they straighten and settle into one another, the four behind into the icon's outer
// square and the one found into its inner, and the eight brushstrokes of its 回 are
// written over them, the inner four paler. Each drawing is redrawn with fresh wobble, so
// it boils like pencil on paper. Writes assets/kehai-icon-sketch.mp4, and the finished
// mark as assets/kehai-icon-sketch.jpg. Nothing is committed or pushed.
//
//     node Scripts/make-landing-sketch.mjs
//
// Needs ffmpeg, and Playwright from Karui's AppStoreScreenshots/node_modules, or the
// package.json of another install in PLAYWRIGHT_FROM.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const site = process.env.LANDING_SITE ?? join(root, "../littlebobert.github.io");
const { chromium } = createRequire(process.env.PLAYWRIGHT_FROM ?? join(root, "../karui/AppStoreScreenshots/package.json"))("playwright");

const fps = 12;
// Drawn large for its detail, then brought down to 4 times the page's 56-point icon.
const drawnSize = 560;
const outputSize = 224;
// Fine lines go pale when brought down that far: deepens the pencil and leaves the paper.
const deepen = "curves=all='0/0 0.45/0.2 0.72/0.6 0.86/0.86 1/1'";
const graphite = "#34342f";
const paper = "#f5f1e9";
// All pencil, black and grey as the icon's ink is, with no red.
const shade = "#9c9990";

let seed = 11;
const rand = () => ((seed = (seed * 16807) % 2147483647) - 1) / 2147483646;
const j = (a) => (rand() - 0.5) * 2 * a;
const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
const mix = (a, b, t) => a + (b - a) * t;
const line = (a, b, n = 8) => Array.from({ length: n + 1 }, (_, i) => lerp(a, b, i / n));
const smooth = (t) => t * t * (3 - 2 * t);
const part = (t, from, to) => smooth(Math.min(1, Math.max(0, (t - from) / (to - from))));
const pathOf = (points) => `M${points.map((p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join("L")}Z`;

// A smooth curve through the points, closed or open.
function spline(points, closed, steps = 6) {
  const n = points.length, out = [];
  const get = (i) => (closed ? points[(i + n) % n] : points[Math.max(0, Math.min(n - 1, i))]);
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const p0 = get(i - 1), p1 = get(i), p2 = get(i + 1), p3 = get(i + 2);
    for (let s = 0; s < steps; s++) {
      const t = s / steps, t2 = t * t, t3 = t2 * t;
      out.push([0, 1].map((k) => 0.5 * (2 * p1[k] + (p2[k] - p0[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 + (3 * p1[k] - p0[k] - 3 * p2[k] + p3[k]) * t3)));
    }
  }
  out.push(closed ? out[0] : points[n - 1]);
  return out;
}

// One pressed line as a filled shape: thin where the pencil lands and lifts, fuller in the
// middle, with the pressure drifting along the way. As in Karui's, Umete's and Sasu's.
function brush(points, width, opacity, { color = graphite, wobble = 2.5, shift = 2, overshoot = 6, heavy = 0.6 } = {}) {
  const ox = j(shift), oy = j(shift), phase = rand() * 6.28, freq = 0.012 + rand() * 0.01, drift = rand() * 6.28;
  const dense = [];
  points.forEach((p, i) => {
    dense.push(p);
    if (i < points.length - 1) dense.push(lerp(p, points[i + 1], 1 / 3), lerp(p, points[i + 1], 2 / 3));
  });
  let travelled = 0;
  const pts = dense.map((p, i) => {
    if (i) travelled += Math.hypot(p[0] - dense[i - 1][0], p[1] - dense[i - 1][1]);
    return [p[0] + ox + Math.sin(travelled * freq + phase) * wobble, p[1] + oy + Math.cos(travelled * freq * 1.3 + phase) * wobble];
  });
  const first = pts[0], next = pts[1], last = pts[pts.length - 1], before = pts[pts.length - 2];
  const reach = (p, q, by) => { const d = Math.hypot(p[0] - q[0], p[1] - q[1]) || 1; return [p[0] + ((p[0] - q[0]) / d) * by, p[1] + ((p[1] - q[1]) / d) * by]; };
  pts.unshift(reach(first, next, rand() * overshoot));
  pts.push(reach(last, before, rand() * overshoot));
  const left = [], right = [];
  pts.forEach((p, i) => {
    const q = pts[Math.min(i + 1, pts.length - 1)], o = pts[Math.max(i - 1, 0)];
    const d = Math.hypot(q[0] - o[0], q[1] - o[1]) || 1, nx = -(q[1] - o[1]) / d, ny = (q[0] - o[0]) / d;
    const t = i / (pts.length - 1);
    const pressure = (1 - heavy + heavy * Math.sin(Math.PI * t) ** 0.55) * (0.82 + 0.18 * Math.sin(t * 9 + drift));
    const half = (width * pressure) / 2;
    left.push([p[0] + nx * half, p[1] + ny * half]);
    right.unshift([p[0] - nx * half, p[1] - ny * half]);
  });
  const outline = [...left, ...right];
  let d = `M${outline[0][0].toFixed(1)} ${outline[0][1].toFixed(1)}`;
  for (let i = 1; i < outline.length; i++) {
    const m = lerp(outline[i], outline[(i + 1) % outline.length], 0.5);
    d += `Q${outline[i][0].toFixed(1)} ${outline[i][1].toFixed(1)} ${m[0].toFixed(1)} ${m[1].toFixed(1)}`;
  }
  return `<path d="${d}Z" fill="${color}" opacity="${(opacity * (0.82 + rand() * 0.3)).toFixed(2)}"/>`;
}

// Diagonal strokes across a box, rising to the right (or with a negative slope, to the
// left), to tone what they're clipped to.
function hatch(x0, x1, bottom, top, gap, width, tone, opacity, slope = 0.58) {
  let s = "";
  for (let x = x0; x < x1; x += gap + rand() * gap * 0.35) {
    s += brush(line([x, bottom], [x + (bottom - top) * slope, top], 4), width, opacity, { color: tone, wobble: 1.5, shift: 1, overshoot: 0, heavy: 0.3 });
  }
  return s;
}

// A window, as on a Mac: a rounded box, its title bar with three lights, and a few lines of
// what's in it. Drawn about its middle, then set at its place and tilt. details fades the
// title bar and lines as it settles into a box; light fills the lit dot of the one in front.
function roundedBox(w, h, r) {
  const corners = [[w / 2 - r, -h / 2 + r, -90], [w / 2 - r, h / 2 - r, 0], [-w / 2 + r, h / 2 - r, 90], [-w / 2 + r, -h / 2 + r, 180]];
  return corners.flatMap(([cx, cy, from]) => Array.from({ length: 5 }, (_, k) => {
    const a = ((from + k * 22.5) * Math.PI) / 180;
    return [cx + Math.cos(a) * r, cy + Math.sin(a) * r];
  }));
}

function windowOf(win, { details, light, outline }) {
  const { w, h } = win;
  const box = roundedBox(w, h, 24);
  let s = `<path d="${pathOf(box)}" fill="${paper}"/>`;
  const bar = -h / 2 + 46;
  if (details > 0) {
    s += `<g opacity="${details.toFixed(2)}">`;
    // The title bar, toned lightly, and its edge.
    s += `<clipPath id="bar${win.id}"><rect x="${-w / 2}" y="${-h / 2}" width="${w}" height="46"/></clipPath><g clip-path="url(#bar${win.id})">${hatch(-w / 2 - 60, w / 2, bar, -h / 2, 11, 7, shade, 0.5)}</g>`;
    s += brush(line([-w / 2 + 4, bar], [w / 2 - 4, bar], 6), 7, 0.85, { overshoot: 2 });
    for (let k = 0; k < 3; k++) {
      const c = [-w / 2 + 30 + k * 26, -h / 2 + 23];
      const ring = Array.from({ length: 11 }, (_, n) => [c[0] + Math.cos(n * 0.66) * 8, c[1] + Math.sin(n * 0.66) * 8]);
      if (k === 0 && light > 0) s += `<circle cx="${c[0]}" cy="${c[1]}" r="9" fill="${graphite}" opacity="${(0.85 * light).toFixed(2)}"/>`;
      s += brush(ring, 5, 0.85, { wobble: 0.5, shift: 0.5, overshoot: 0 });
    }
    // What's in it, as lines of writing.
    for (let k = 0; k < win.lines.length; k++) {
      const y = bar + 40 + k * 34;
      if (y > h / 2 - 22) break;
      s += brush(line([-w / 2 + 28, y], [-w / 2 + 28 + (w - 56) * win.lines[k], y], 5), 8, 0.6, { wobble: 1.5, overshoot: 2 });
    }
    s += "</g>";
  }
  s += brush([...box, box[0]], 12, outline, { wobble: 2, heavy: 0.4, overshoot: 4 });
  return `<g transform="translate(${win.c[0].toFixed(1)} ${win.c[1].toFixed(1)}) rotate(${win.a.toFixed(2)})">${s}</g>`;
}

// The icon's eight brushstrokes, traced from it: each a line through its middle, written
// in the order of 回, with how wide the brush pressed at each point. The outer square's
// four, then the inner's.
const strokes = [
  { points: [[135, 255], [200, 300], [235, 380], [225, 500], [210, 640], [200, 800]], widths: [60, 95, 120, 95, 55, 10] },
  { points: [[335, 245], [480, 228], [640, 210], [760, 215], [850, 228]], widths: [10, 35, 45, 90, 95] },
  { points: [[782, 355], [800, 450], [818, 560], [845, 680], [855, 760]], widths: [12, 35, 60, 110, 70] },
  { points: [[285, 828], [400, 812], [520, 790], [620, 806], [685, 822]], widths: [8, 40, 85, 85, 60] },
  { points: [[345, 388], [365, 470], [375, 570], [380, 665]], widths: [15, 45, 55, 30], inner: true },
  { points: [[400, 408], [480, 392], [560, 372], [625, 378]], widths: [8, 25, 50, 40], inner: true },
  { points: [[662, 418], [652, 480], [645, 560], [640, 635]], widths: [18, 40, 50, 25], inner: true },
  { points: [[432, 662], [520, 650], [600, 656], [655, 672]], widths: [45, 65, 45, 10], inner: true },
];

// A stroke, written as far as amount: its shape round at both ends, filled in close
// hatching, crossed for depth, and outlined. The inner ones are paler, as the icon's
// inner strokes are washed grey.
function inkStroke(stroke, amount, id) {
  if (amount <= 0) return "";
  const full = spline(stroke.points, false, 6);
  const widthAt = (i) => {
    const t = (i / (full.length - 1)) * (stroke.widths.length - 1), k = Math.min(Math.floor(t), stroke.widths.length - 2);
    return mix(stroke.widths[k], stroke.widths[k + 1], t - k);
  };
  const path = full.slice(0, Math.max(2, Math.round(full.length * amount)));
  const left = [], right = [];
  path.forEach((p, i) => {
    const q = path[Math.min(i + 1, path.length - 1)], o = path[Math.max(i - 1, 0)];
    const d = Math.hypot(q[0] - o[0], q[1] - o[1]) || 1, nx = -(q[1] - o[1]) / d, ny = (q[0] - o[0]) / d;
    const half = Math.max(5, widthAt(i) / 2);
    left.push([p[0] + nx * half, p[1] + ny * half]);
    right.unshift([p[0] - nx * half, p[1] - ny * half]);
  });
  const cap = (end, toward, half, from) => Array.from({ length: 7 }, (_, k) => {
    const d = Math.hypot(end[0] - toward[0], end[1] - toward[1]) || 1, u = [(end[0] - toward[0]) / d, (end[1] - toward[1]) / d];
    const a = from + (k / 6) * Math.PI;
    return [end[0] + (u[0] * Math.sin(a) - u[1] * Math.cos(a)) * half, end[1] + (u[1] * Math.sin(a) + u[0] * Math.cos(a)) * half];
  });
  const last = path.length - 1;
  const shape = [...left, ...cap(path[last], path[last - 1], Math.max(5, widthAt(last) / 2), 0), ...right, ...cap(path[0], path[1], Math.max(5, widthAt(0) / 2), 0)];
  const xs = shape.map((p) => p[0]), ys = shape.map((p) => p[1]);
  const [x0, x1, top, bottom] = [Math.min(...xs) - 10, Math.max(...xs) + 10, Math.min(...ys) - 10, Math.max(...ys) + 10];
  let s = `<clipPath id="ink${id}"><path d="${pathOf(shape)}"/></clipPath><g clip-path="url(#ink${id})">`;
  s += hatch(x0 - (bottom - top) * 0.58, x1, bottom, top, 9, 10, stroke.inner ? shade : graphite, stroke.inner ? 0.9 : 0.8);
  s += hatch(x0, x1 + (bottom - top) * 0.62, bottom, top, stroke.inner ? 15 : 11, 7, graphite, stroke.inner ? 0.3 : 0.6, -0.62);
  s += "</g>" + brush([...shape, shape[0]], 9, 0.95, { wobble: 1.5, shift: 1, heavy: 0.4, overshoot: 3 });
  return s;
}

// The desk of windows, from where each drops askew to the box it settles into: the first,
// dropped first and buried under the rest, is the one found, and goes in the middle.
const outerBox = { c: [505, 522], w: 712, h: 592, a: 0 };
const innerBox = { c: [508, 528], w: 290, h: 280, a: 0 };
const windows = [
  { id: 0, c: [530, 505], w: 350, h: 262, a: 4, lines: [0.7, 0.45, 0.8, 0.3], to: innerBox, delay: 0.22 },
  { id: 1, c: [300, 320], w: 410, h: 300, a: -8, lines: [0.8, 0.55, 0.65, 0.4], to: outerBox, delay: 0 },
  { id: 2, c: [730, 285], w: 380, h: 290, a: 6, lines: [0.5, 0.75, 0.35, 0.6], to: outerBox, delay: 0.05 },
  { id: 3, c: [295, 725], w: 390, h: 280, a: 5, lines: [0.65, 0.3, 0.8, 0.5], to: outerBox, delay: 0.1 },
  { id: 4, c: [735, 705], w: 400, h: 300, a: -7, lines: [0.4, 0.7, 0.55, 0.75], to: outerBox, delay: 0.15 },
];
const placedAt = (win, t) => ({ ...win, c: lerp(win.c, win.to.c, t), w: mix(win.w, win.to.w, t), h: mix(win.h, win.to.h, t), a: mix(win.a, win.to.a, t) });

// The timing, in drawings at 12 a second: the windows drop in one by one, each in front,
// then the front changes three times, ending on the one found; they straighten and settle;
// the strokes are written over them as they fade; it holds, and fades for the next time.
const timeline = [];
const blank = { shown: 0, order: [], front: -1, move: 0, details: 1, light: 1, outline: 1, ink: strokes.map(() => 0), fade: 1 };
const push = (extra) => timeline.push({ ...blank, ...extra });
push({});
let order = [];
for (const k of [0, 1, 2, 3, 4]) {
  order = [...order, k];
  for (let f = 0; f < 3; f++) push({ shown: k + 1, order, front: k, pop: f === 0 ? k : -1 });
}
for (const k of [1, 3, 0]) {
  order = [...order.filter((n) => n !== k), k];
  for (let f = 0; f < 7; f++) push({ shown: 5, order, front: k });
}
for (let i = 1; i <= 14; i++) {
  const t = i / 14;
  push({ shown: 5, order, front: 0, move: t, details: 1 - part(t, 0, 0.55) });
}
for (let i = 1; i <= 18; i++) {
  push({ shown: 5, order, front: 0, move: 1, details: 0, light: 1 - part(i, 8, 14), outline: 1 - part(i, 2, 18), ink: strokes.map((_, s) => part(i, s * 2, s * 2 + 3)) });
}
const done = { shown: 0, order, front: 0, move: 1, details: 0, light: 0, outline: 0, ink: strokes.map(() => 1) };
for (let i = 0; i < 28; i++) push(done);
for (const fade of [0.7, 0.4, 0.15]) push({ ...done, fade });

const defs = `<filter id="pencil" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB">
<feTurbulence type="fractalNoise" baseFrequency="0.9 0.55" numOctaves="3" seed="4" result="grain"/>
<feColorMatrix in="grain" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -2.6 2.05" result="tooth"/>
<feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="9" result="warp"/>
<feDisplacementMap in="SourceGraphic" in2="warp" scale="5" result="moved"/>
<feComposite in="moved" in2="tooth" operator="in"/>
</filter>
<filter id="paper" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
<feTurbulence type="fractalNoise" baseFrequency="0.7" numOctaves="4" seed="21"/>
<feColorMatrix type="matrix" values="0 0 0 0 0.45  0 0 0 0 0.42  0 0 0 0 0.34  0 0 0 0.09 -0.03"/>
</filter>`;

function page(frame, index, size) {
  // Redrawn every other drawing, so it boils at six a second, as a held pencil drawing does.
  seed = 1000 + Math.floor(index / 2) * 97;
  let desk = "";
  if (frame.outline > 0 || frame.details > 0) {
    for (const k of frame.order) {
      const win = windows[k];
      let at = placedAt(win, part(frame.move, win.delay, win.delay + 0.78));
      // Dropped in a little large, the drawing it appears.
      if (frame.pop === k) at = { ...at, w: at.w * 1.06, h: at.h * 1.06 };
      desk += windowOf(at, { details: frame.details, light: k === frame.front ? frame.light : 0, outline: frame.outline });
    }
  }
  const ink = strokes.map((stroke, s) => inkStroke(stroke, frame.ink[s], s)).join("");
  return `<!doctype html><body style="margin:0;background:${paper}"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="${size}" height="${size}" style="display:block"><defs>${defs}</defs>
<rect width="1024" height="1024" fill="${paper}"/><rect width="1024" height="1024" filter="url(#paper)"/>
<g stroke="none" filter="url(#pencil)" opacity="${frame.fade}">${desk}${ink}</g></svg></body>`;
}

const work = mkdtempSync(join(tmpdir(), "kehai-sketch-"));
const browser = await chromium.launch();
const tab = await browser.newPage({ viewport: { width: drawnSize, height: drawnSize } });
for (const [index, frame] of timeline.entries()) {
  await tab.setContent(page(frame, index, drawnSize));
  await tab.screenshot({ path: join(work, `${String(index).padStart(4, "0")}.png`) });
}
await tab.setContent(page(done, 0, drawnSize));
await tab.screenshot({ path: join(work, "still.png") });
await browser.close();

if (process.env.KEEP_FRAMES) {
  console.log(`Drawings kept in ${work}.`);
}
execFileSync("ffmpeg", ["-v", "error", "-y", "-framerate", String(fps), "-i", join(work, "%04d.png"),
  "-vf", `scale=${outputSize}:${outputSize}:flags=lanczos,${deepen},format=yuv420p`, "-r", "24", "-c:v", "libx264", "-profile:v", "high", "-crf", "22", "-preset", "slow",
  "-an", "-movflags", "+faststart", join(site, "assets/kehai-icon-sketch.mp4")]);
execFileSync("ffmpeg", ["-v", "error", "-y", "-i", join(work, "still.png"), "-vf", `scale=${outputSize}:${outputSize}:flags=lanczos,${deepen}`, "-q:v", "2", "-update", "1",
  join(site, "assets/kehai-icon-sketch.jpg")]);
if (!process.env.KEEP_FRAMES) rmSync(work, { recursive: true, force: true });
console.log(`${timeline.length} drawings, ${(timeline.length / fps).toFixed(1)} s. Installed in ${site}.`);
