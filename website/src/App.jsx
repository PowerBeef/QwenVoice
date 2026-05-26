import React from "react";
import { Nav } from "./sections/Nav.jsx";
import { Hero } from "./sections/Hero.jsx";
import { WorkflowBand } from "./sections/WorkflowBand.jsx";
import { Listen } from "./sections/Listen.jsx";
import { TryIt } from "./sections/TryIt.jsx";
import { HowItRuns } from "./sections/HowItRuns.jsx";
import { FinalCTA } from "./sections/FinalCTA.jsx";
import { Footer } from "./sections/Footer.jsx";
import { WORKFLOWS } from "./data/workflows.js";

const App = () => (
  <>
    <Nav />
    <Hero />
    <div id="workflows" className="workflows-anchor">
      {WORKFLOWS.map((w, i) => (
        <WorkflowBand key={w.id} workflow={w} index={i} />
      ))}
    </div>
    <Listen />
    <TryIt />
    <HowItRuns />
    <FinalCTA />
    <Footer />
  </>
);

export default App;
