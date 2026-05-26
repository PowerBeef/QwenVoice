import React, { useState } from "react";
import { TryCanvas } from "../components/TryCanvas.jsx";
import { DELIVERIES } from "../data/samples.js";

export const TryIt = () => {
  const [brief, setBrief] = useState("A warm, deep narrator with a subtle British accent.");
  const [delivery, setDelivery] = useState("Calm");

  return (
    <section className="section try-section" id="try" aria-labelledby="try-title">
      <div className="container try-inner">
        <div className="try-copy">
          <p className="section-note">Interactive voice brief</p>
          <h2 id="try-title" className="section-title try-title">
            Describe a voice.<br />Watch it take shape.
          </h2>
          <p className="section-sub try-sub">
            A demo of the Voice Design surface. Type a brief, pick a delivery preset,
            and the waveform shifts with your choices. In Vocello, the same brief
            generates real audio locally on your Mac.
          </p>

          <label className="vc-label" htmlFor="voice-brief-demo">Voice brief</label>
          <textarea
            id="voice-brief-demo"
            className="try-input"
            value={brief}
            onChange={(e) => setBrief(e.target.value)}
            placeholder="A warm, deep narrator with a subtle British accent."
            maxLength={140}
          />

          <div className="vc-label" id="delivery-label">Delivery</div>
          <div className="try-chips" role="group" aria-labelledby="delivery-label">
            {DELIVERIES.map((d) => (
              <button
                key={d.label}
                type="button"
                className="chip"
                data-active={delivery === d.label}
                aria-pressed={delivery === d.label}
                style={{ "--chip-color": d.color }}
                onClick={() => setDelivery(d.label)}
              >
                <span className="swatch" aria-hidden="true" />
                {d.label}
              </button>
            ))}
          </div>
        </div>

        <div className="try-viz">
          <TryCanvas brief={brief} delivery={delivery} />
          <div className="try-label">
            <span className="dot" aria-hidden="true" />
            Visualization only.
          </div>
        </div>
      </div>
    </section>
  );
};
