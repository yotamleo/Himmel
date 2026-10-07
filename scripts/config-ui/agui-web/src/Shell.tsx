// HIMMEL-4711: the config console's rail around the fleet and run pages, so / and /agui/ read as one app. The page
// list and its links come from public/nav.js, the same module the console draws its rail from.
import type { ReactNode } from "react";
// @ts-expect-error: plain ES module shared with the console (no types).
import { fleetDot, navLinks } from "../../public/nav.js";
import type { FleetState } from "./Fleet";

export function Shell({ token, run, fleet, children }: { token: string | null; run: string | null; fleet: FleetState; children: ReactNode }) {
  const dot = fleetDot(fleet.fleet, fleet.error);
  const links: { id: string; label: string; href: string; current: boolean }[] = token ? navLinks({ here: "agui", token, current: run ? "run" : "fleet", run }) : [];
  return (
    <div className="shell">
      <aside className="rail" aria-label="Regions">
        <div className="brand">himmelctl ui<small>{location.host}</small></div>
        {links.length > 0 && (
          <nav className="pages" aria-label="Pages">
            {links.map((l) => (
              <a key={l.id} href={l.href} aria-current={l.current ? "page" : undefined}>
                {l.label}
                {l.id === "fleet" && <span className={`st-dot ${dot.cls}`} title={dot.title} />}
              </a>
            ))}
          </nav>
        )}
      </aside>
      <div className="pane">{children}</div>
    </div>
  );
}
