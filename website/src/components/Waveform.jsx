import React, { useMemo } from "react";
import { makeWaveBars } from "./Icon.jsx";

export const Waveform = ({ bars = 32, playing = false, color = "var(--accent)", seed = 1 }) => {
  const heights = useMemo(() => makeWaveBars(bars, seed), [bars, seed]);
  return (
    <div className="hear-wave">
      {heights.map((h, i) => (
        <div
          key={i}
          className={`bar ${playing ? "animate" : ""}`}
          style={{
            height: `${h * 100}%`,
            background: color,
            animationDelay: `${(i % 8) * 0.08}s`,
          }}
        />
      ))}
    </div>
  );
};
