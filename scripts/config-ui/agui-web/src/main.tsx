import { createRoot } from "react-dom/client";
import { App } from "./App";
import { sourceFromLocation } from "./stream";

createRoot(document.getElementById("root")!).render(<App source={sourceFromLocation(location.hash)} />);
