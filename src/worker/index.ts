// Background process: funnel steps, broadcasts, payment reconciliation (pg-boss, from M5).
// At M0 it only proves it is alive: the container healthcheck reads the heartbeat file.
import { writeFile } from "node:fs/promises";

const HEARTBEAT_FILE = "/tmp/worker-heartbeat";
const HEARTBEAT_MS = 30_000;

async function beat() {
  try {
    await writeFile(HEARTBEAT_FILE, new Date().toISOString());
  } catch (err) {
    console.error("worker: heartbeat write failed", err);
  }
}

await beat();
const timer = setInterval(beat, HEARTBEAT_MS);
console.log("worker: started");

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    clearInterval(timer);
    console.log(`worker: ${signal}, stopping`);
    process.exit(0);
  });
}
