import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { FleetPage } from "./Fleet";
import { fleetToken, sourceFromLocation } from "./stream";

// HIMMEL-4712: a token with no run is the fleet landing; a fleet row changes the fragment to its run, so the
// page re-routes on hashchange (keyed on the hash so a new run gets a fresh stream).
function Root() {
  const [hash, setHash] = useState(location.hash);
  useEffect(() => {
    const on = () => setHash(location.hash);
    addEventListener("hashchange", on);
    return () => removeEventListener("hashchange", on);
  }, []);
  const token = fleetToken(hash);
  return token ? <FleetPage token={token} /> : <App key={hash} source={sourceFromLocation(hash)} />;
}

createRoot(document.getElementById("root")!).render(<Root />);
