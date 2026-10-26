import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BoardApp } from "./components/Board";
import { PetApp } from "./components/Pet";
import "./styles.css";

const params = new URLSearchParams(window.location.search);
const view = params.get("view") === "board" ? "board" : "pet";

const root = createRoot(document.getElementById("root")!);
root.render(
  <StrictMode>{view === "board" ? <BoardApp /> : <PetApp />}</StrictMode>,
);
