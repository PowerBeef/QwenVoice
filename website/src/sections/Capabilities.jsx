import React from "react";

const ROWS = [
  {
    k: "Responsive native generation",
    v: "Native Swift and MLX keep generation local and responsive on Apple Silicon, including supported 8 GB Macs.",
    tone: "var(--gold-300)",
  },
  {
    k: "Ten languages, detected for you",
    v: "Write in Chinese, English, Japanese, Korean, German, French, Russian, Portuguese, Spanish, or Italian. Vocello reads the language from your script, and the voice and language pickers recommend matches for it.",
    tone: "var(--lavender-300)",
  },
  {
    k: "Takes you can reproduce",
    v: "Every generation records its seed. A variation control sets how much takes differ, and a batch shares one seed, so a multi-line script reads as a single performance.",
    tone: "var(--terracotta-300)",
  },
];

export const Capabilities = () => (
  <section className="section caps-section" id="whats-new" aria-labelledby="caps-title">
    <div className="container caps-layout">
      <div className="caps-copy">
        <p className="section-note">New in 2.1</p>
        <h2 id="caps-title" className="section-title">Built for real scripts.</h2>
        <p className="section-sub">
          Vocello 2.1 is faster, speaks more languages, and gives you takes you can
          repeat. Everything still runs locally on your Mac.
        </p>

        <dl className="caps-list" aria-label="What is new in Vocello 2.1">
          {ROWS.map((r) => (
            <div className="caps-row" key={r.k} style={{ "--row-tone": r.tone }}>
              <dt className="caps-k">{r.k}</dt>
              <dd className="caps-v">{r.v}</dd>
            </div>
          ))}
        </dl>
      </div>

      <figure className="caps-shot">
        <div className="window">
          <img
            src="assets/screens/history.png"
            alt="Vocello Generation History listing past takes across Custom Voice, Voice Design, and Voice Cloning"
          />
        </div>
        <figcaption className="caps-shot-caption">
          Generation History keeps every take on your Mac, ready to replay, save, or export.
        </figcaption>
      </figure>
    </div>
  </section>
);
