#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { clickWindowButton, listModalWindows, watchModalsWhile } from "./lib/ax.mjs";
import { developHistory, lastExportTimestamp, pollCatalog } from "./lib/catalog-db.mjs";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";
import { createReport } from "./lib/proof.mjs";

const EXPORT_BUDGET_MS = 300_000;
const CALL_TIMEOUT_MS = EXPORT_BUDGET_MS + 30_000;
const MODAL_POLL_MS = 1_000;
const MODAL_HOLD_MS = 10_000;
const EXPORT_FAILURE_PATTERN = /export/i;

const report = createReport("what a failed export session leaves on the photo (proof z, round 4 D15)");
const { session, marker, catalogPath } = await openLiveSession();
const chart = String(requireFixtureId(marker, "chart80"));

const traces = () => ({
  history: developHistory(catalogPath, chart),
  last_export_timestamp: lastExportTimestamp(catalogPath, chart),
});
const added = (before, after) => after.history.filter((step) => !before.history.some((known) => known.id === step.id));
const replyOf = (answer) => ({
  outcome: answer.outcome,
  isError: answer.isError,
  error: answer.envelope.error ?? null,
  failed: answer.envelope.failed ?? [],
  unknown: answer.envelope.unknown ?? [],
  warnings: answer.envelope.warnings ?? [],
  data: answer.data ?? null,
  ms: answer.ms,
});
const isExportFailure = (window) =>
  EXPORT_FAILURE_PATTERN.test(`${window.title} ${window.text}`) && window.buttons.includes("OK");
async function exportFailureModals() {
  const modals = listModalWindows();
  const pressed = [];
  for (const window of modals) {
    if (isExportFailure(window)) {
      await clickWindowButton(window.title, "OK");
      pressed.push(window.title);
    }
  }
  return { modals, pressed, left_open: listModalWindows() };
}
async function exportWatchingModals(destination) {
  const call = session.tool("export_photos", { photo_ids: [chart], destination }, { timeoutMs: CALL_TIMEOUT_MS }).then(
    (answer) => ({ answer }),
    (error) => ({ error: error.message }),
  );
  const watched = await watchModalsWhile(call, isExportFailure, { holdMs: MODAL_HOLD_MS, pollMs: MODAL_POLL_MS });
  const { answer, error } = watched.result;
  return {
    answer,
    error,
    call_seconds: watched.settled_at_seconds,
    modals_during_call: watched.modals,
    modals_after_call: await exportFailureModals(),
  };
}

let output = null;
try {
  output = fs.mkdtempSync(path.join(os.tmpdir(), "lragent-live-failed-export-"));
  const readOnly = path.join(output, "read-only");
  const writable = path.join(output, "writable");
  fs.mkdirSync(readOnly, { mode: 0o555 });
  fs.mkdirSync(writable);
  const before = traces();
  const denied = await exportWatchingModals(readOnly);
  const afterDenied = await pollCatalog(traces, () => false);
  const failedSession = {
    reply: denied.answer ? replyOf(denied.answer) : null,
    rpc_error: denied.error ?? null,
    call_seconds: denied.call_seconds,
    blocked_until_dismissed: denied.modals_during_call.some(
      (window) => window.pressed_at_seconds !== null && !window.settled_while_open,
    ),
    settled_while_open: denied.modals_during_call.some((window) => window.settled_while_open),
    modals_during_call: denied.modals_during_call,
    modals_after_call: denied.modals_after_call,
    files_written: fs.readdirSync(readOnly),
    history_steps_added: added(before, afterDenied),
    last_export_timestamp: { before: before.last_export_timestamp, after: afterDenied.last_export_timestamp },
  };
  failedSession.left_a_trace =
    failedSession.history_steps_added.length > 0 ||
    failedSession.last_export_timestamp.after !== failedSession.last_export_timestamp.before;
  const deniedAnswer = denied.answer
    ? `answered ${denied.answer.outcome}`
    : `gave no answer within ${CALL_TIMEOUT_MS / 1000} s (${denied.error})`;
  report.check(
    `recorded: export_photos into a read-only folder ${deniedAnswer} after ${denied.call_seconds} s${failedSession.blocked_until_dismissed ? `, blocked until its export modal was dismissed after ${MODAL_HOLD_MS / 1000} s open,` : ""}${failedSession.settled_while_open ? " with its export modal still open," : ""} wrote no file and left ${failedSession.left_a_trace ? "a trace" : "no trace"} (history steps ${JSON.stringify(failedSession.history_steps_added.map((step) => step.name))}, lastExportTimestamp ${failedSession.last_export_timestamp.before} -> ${failedSession.last_export_timestamp.after})`,
    (denied.answer === undefined || denied.answer.isError) &&
      failedSession.files_written.length === 0 &&
      denied.modals_after_call.left_open.length === 0,
    failedSession,
  );

  const exportedRun = await exportWatchingModals(writable);
  const exported = exportedRun.answer;
  const afterExported = await pollCatalog(traces, () => false);
  const control = {
    reply: exported ? replyOf(exported) : null,
    rpc_error: exportedRun.error ?? null,
    modals_during_call: exportedRun.modals_during_call,
    files_written: fs.readdirSync(writable),
    history_steps_added: added(afterDenied, afterExported),
    last_export_timestamp: { before: afterDenied.last_export_timestamp, after: afterExported.last_export_timestamp },
  };
  report.check(
    "control: a successful export of the same photo adds one Export history step and moves lastExportTimestamp",
    exported?.outcome === "done" &&
      control.files_written.length === 1 &&
      control.history_steps_added.length === 1 &&
      /^Export/.test(control.history_steps_added[0].name) &&
      control.last_export_timestamp.after !== control.last_export_timestamp.before,
    control,
  );
  report.finish({ photo_id: chart });
} finally {
  if (output !== null) {
    const readOnly = path.join(output, "read-only");
    if (fs.existsSync(readOnly)) fs.chmodSync(readOnly, 0o755);
    fs.rmSync(output, { recursive: true, force: true });
  }
  await session.stop();
}
