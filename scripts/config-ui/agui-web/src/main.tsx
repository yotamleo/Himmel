import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { FleetPage, useFleet } from "./Fleet";
import { Shell } from "./Shell";
import { fleetToken, sourceFromLocation } from "./stream";

// HIMMEL-4712: a token with no run is the fleet landing; a fleet row changes the fragment to its run, so the
// page re-routes on hashchange (keyed on the hash so a new run gets a fresh stream). HIMMEL-4711: both sit in
// the config console's rail.
function Root() {
  const [hash, setHash] = useState(location.hash);
  useEffect(() => {
    const on = () => setHash(location.hash);
    addEventListener("hashchange", on);
    return () => removeEventListener("hashchange", on);
  }, []);
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const fleet = useFleet(p.get("t"));
  const token = fleetToken(hash);
  return (
    <Shell token={p.get("t")} run={p.get("run")} fleet={fleet}>
      {token ? <FleetPage token={token} state={fleet} /> : <App key={hash} source={sourceFromLocation(hash)} />}
    </Shell>
  );
}

createRoot(document.getElementById("root")!).render(<Root />);
