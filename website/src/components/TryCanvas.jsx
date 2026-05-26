import React, { useEffect, useRef } from "react";
import { DELIVERY_COLORS } from "../data/samples.js";

const DELIVERY_SHAPES = {
  Neutral:  { amp: 0.70, density: 1.00, noise: 0.15, env: 1.00, rate: 0.040 },
  Happy:    { amp: 0.78, density: 1.10, noise: 0.14, env: 1.00, rate: 0.045 },
  Sad:      { amp: 0.50, density: 0.80, noise: 0.10, env: 1.40, rate: 0.025 },
  Angry:    { amp: 0.95, density: 1.20, noise: 0.22, env: 0.90, rate: 0.060 },
  Fearful:  { amp: 0.62, density: 1.18, noise: 0.28, env: 1.10, rate: 0.055 },
  Whisper:  { amp: 0.35, density: 0.70, noise: 0.30, env: 1.25, rate: 0.025 },
  Dramatic: { amp: 1.00, density: 1.15, noise: 0.20, env: 0.85, rate: 0.050 },
  Calm:     { amp: 0.55, density: 0.85, noise: 0.08, env: 1.20, rate: 0.030 },
  Excited:  { amp: 0.90, density: 1.30, noise: 0.25, env: 0.95, rate: 0.070 },
};

const DEFAULT_SHAPE = DELIVERY_SHAPES.Neutral;

const hashBrief = (s) => {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
};

export const TryCanvas = ({ brief, delivery }) => {
  const canvasRef = useRef(null);

  useEffect(() => {
    const c = canvasRef.current;
    if (!c) return;
    const ctx = c.getContext("2d");
    let rafId;
    const dpr = window.devicePixelRatio || 1;
    const resize = () => {
      const w = c.clientWidth;
      const h = c.clientHeight;
      c.width = w * dpr;
      c.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    window.addEventListener("resize", resize);

    const seed = hashBrief(brief);
    const shape = DELIVERY_SHAPES[delivery] || DEFAULT_SHAPE;
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let t = 0;

    const draw = () => {
      const w = c.clientWidth;
      const h = c.clientHeight;
      ctx.clearRect(0, 0, w, h);

      const color = DELIVERY_COLORS[delivery] || "#EDCC8A";

      const grad = ctx.createRadialGradient(w / 2, h / 2, 10, w / 2, h / 2, w / 2);
      grad.addColorStop(0, `${color}40`);
      grad.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = grad;
      ctx.fillRect(0, 0, w, h);

      const cy = h / 2;
      const bars = Math.max(20, Math.round(80 * shape.density));
      const step = w / (bars + 4);

      ctx.lineCap = "round";
      ctx.shadowColor = color;
      ctx.shadowBlur = 7;
      for (let i = 0; i < bars; i++) {
        const phase = (i / bars) * Math.PI * 4 + t * shape.rate;
        const drive =
          (Math.sin(phase + seed * 0.0001) * 0.5 +
           Math.sin(phase * 1.7 + seed * 0.00031) * 0.4 +
           Math.sin(phase * 0.5 + seed * 0.00007) * 0.3) / 1.2;
        const jitter = Math.sin(i * 4.371 + seed * 0.0017) * shape.noise;
        const envBase = Math.max(0, Math.sin((i / bars) * Math.PI));
        const env = Math.pow(envBase, shape.env);
        const ampPx = Math.max(2, (Math.abs(drive) + jitter) * env * (h * 0.36) * shape.amp + 2);
        const x = (i + 2) * step + step / 2;

        ctx.strokeStyle = color;
        ctx.globalAlpha = 0.48 + env * 0.44;
        ctx.lineWidth = 2.4;
        ctx.beginPath();
        ctx.moveTo(x, cy - ampPx);
        ctx.lineTo(x, cy + ampPx);
        ctx.stroke();
      }

      ctx.shadowBlur = 0;
      ctx.globalAlpha = 0.18;
      ctx.strokeStyle = color;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, cy);
      ctx.lineTo(w, cy);
      ctx.stroke();
      ctx.globalAlpha = 1;

      t += 1;
      if (!reduceMotion) {
        rafId = requestAnimationFrame(draw);
      }
    };
    draw();
    return () => {
      cancelAnimationFrame(rafId);
      window.removeEventListener("resize", resize);
    };
  }, [brief, delivery]);

  return (
    <canvas
      ref={canvasRef}
      className="try-waveform"
      role="img"
      aria-label={`${delivery} delivery waveform preview`}
    />
  );
};
