import { execFileSync, spawn } from "node:child_process";
import path from "node:path";
import { LIGHTROOM_PROCESS_NAME } from "./paths.mjs";

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function osascript(script) {
  return execFileSync("osascript", ["-e", script], { encoding: "utf8" }).trim();
}

export function frontmostProcessName() {
  return osascript('tell application "System Events" to get name of first process whose frontmost is true');
}

function frontmostOrNull() {
  try {
    return frontmostProcessName();
  } catch {
    return null;
  }
}

export async function ensureLightroomFrontmost({ attempts = 10 } = {}) {
  let front = frontmostOrNull();
  for (let attempt = 0; front !== LIGHTROOM_PROCESS_NAME && attempt < attempts; attempt++) {
    try {
      osascript(`tell application "${LIGHTROOM_PROCESS_NAME}" to activate`);
    } catch {
      front = null;
    }
    await sleep(1000);
    front = frontmostOrNull();
  }
  if (front !== LIGHTROOM_PROCESS_NAME) {
    throw new Error(`refusing to send input: frontmost process is "${front}", not ${LIGHTROOM_PROCESS_NAME}`);
  }
}

function quote(text) {
  return `"${text.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

export async function clickMenuItem(menuName, itemNamePrefix) {
  await ensureLightroomFrontmost();
  return osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  set theMenu to menu ${quote(menuName)} of menu bar 1
  repeat with theItem in menu items of theMenu
    set itemName to ""
    try
      set itemName to name of theItem
    end try
    if itemName is not missing value and itemName starts with ${quote(itemNamePrefix)} then
      click theItem
      return itemName
    end if
  end repeat
  error "menu item not found: ${menuName} > ${itemNamePrefix}"
end tell`);
}

const FIELD_SEPARATOR = "\u001f";
const RECORD_SEPARATOR = "\u001e";
const IGNORED_WINDOW_FRAGMENTS = ["Adobe Photoshop Lightroom Classic", "Lightroom Plug-in Manager"];

export function listModalWindows() {
  const raw = osascript(`
set fieldSep to character id 31
set recordSep to character id 30
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  set found to {}
  repeat with w in windows
    set wTitle to ""
    set wSubrole to ""
    try
      set wTitle to name of w as text
    end try
    try
      set wSubrole to subrole of w as text
    end try
    if wTitle does not contain "Adobe Photoshop Lightroom Classic" and wTitle does not contain "Lightroom Plug-in Manager" then
      set directButtons to {}
      try
        repeat with b in (buttons of w)
          set end of directButtons to (name of b as text)
        end repeat
      end try
      set looksLikeDialog to wSubrole is "AXDialog" or wSubrole is "AXSystemDialog" or directButtons contains "OK" or directButtons contains "Relaunch"
      if looksLikeDialog then
        set buttonNames to {}
        set labels to {}
        set els to {}
        try
          set els to entire contents of w
        end try
        repeat with e in els
          try
            if role of e is "AXButton" then set end of buttonNames to (name of e as text)
          end try
          try
            if role of e is "AXStaticText" then set end of labels to (value of e as text)
          end try
        end repeat
        set AppleScript's text item delimiters to "|"
        set end of found to wTitle & fieldSep & (buttonNames as text) & fieldSep & (labels as text)
        set AppleScript's text item delimiters to ""
      end if
    end if
  end repeat
  set AppleScript's text item delimiters to recordSep
  return found as text
end tell`);
  return parseModalWindows(raw);
}

export function parseModalWindows(raw) {
  return raw
    .split(RECORD_SEPARATOR)
    .filter(Boolean)
    .map((record) => {
      const [title, buttons, labels] = record.split(FIELD_SEPARATOR);
      return {
        title,
        buttons: buttons ? buttons.split("|").filter(Boolean) : [],
        text: labels ?? "",
      };
    })
    .filter((window) => window.buttons.length > 0)
    .filter((window) => !IGNORED_WINDOW_FRAGMENTS.some((fragment) => window.title.includes(fragment)));
}

const NO_DETECTED_PATTERN = /detected/i;
const ADDRESS_LOOKUP_PATTERN = /address lookup/i;
const DECLINE_BUTTONS = ["Not Now", "No", "Don't Enable", "Disable", "Cancel"];

export function chooseModalButton(window) {
  const haystack = `${window.title} ${window.text}`;
  if (NO_DETECTED_PATTERN.test(haystack) && window.buttons.includes("OK")) return "OK";
  if (ADDRESS_LOOKUP_PATTERN.test(haystack)) {
    return DECLINE_BUTTONS.find((name) => window.buttons.includes(name)) ?? null;
  }
  return null;
}

function onElement(windowTitle, role, name, statements) {
  return osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  set els to entire contents of window ${quote(windowTitle)}
  repeat with e in els
    set r to ""
    set n to ""
    try
      set r to role of e
    end try
    try
      set n to name of e as text
    end try
    if r is ${quote(role)} and n is ${quote(name)} then
      ${statements}
    end if
  end repeat
  error "element not found: ${role} ${name}"
end tell`);
}

export async function clickWindowButton(windowTitle, buttonName) {
  onElement(windowTitle, "AXButton", buttonName, 'perform action "AXPress" of e\n      return "pressed"');
}

export async function watchModalsWhile(
  call,
  isTarget,
  {
    holdMs,
    pollMs,
    list = listModalWindows,
    press = (window) => clickWindowButton(window.title, "OK"),
    now = Date.now,
  },
) {
  const started = now();
  const seconds = () => (now() - started) / 1000;
  const sameWindow = (entry, window) => entry.title === window.title && entry.text === window.text;
  const modals = [];
  let settledAt = null;
  const outcome = call.then((result) => {
    settledAt = seconds();
    return result;
  });
  while (settledAt === null) {
    for (const window of list()) {
      let entry = modals.find((known) => sameWindow(known, window));
      if (entry === undefined) {
        entry = {
          at_seconds: seconds(),
          title: window.title,
          text: window.text,
          buttons: window.buttons,
          held: isTarget(window),
          pressed_at_seconds: null,
        };
        modals.push(entry);
      }
      if (
        entry.held &&
        entry.pressed_at_seconds === null &&
        settledAt === null &&
        seconds() - entry.at_seconds >= holdMs / 1000
      ) {
        entry.pressed_at_seconds = seconds();
        await press(window);
      }
    }
    await Promise.race([outcome, sleep(pollMs)]);
  }
  const openAtSettle = list();
  for (const entry of modals.filter((known) => known.held)) {
    entry.settled_while_open = openAtSettle.some((window) => sameWindow(entry, window));
  }
  return { result: await outcome, settled_at_seconds: settledAt, modals };
}

export async function dismissBlockingModals({ rounds = 6, pauseMs = 1500 } = {}) {
  const dismissed = [];
  for (let round = 0; round < rounds; round++) {
    const target = listModalWindows()
      .map((window) => ({ window, button: chooseModalButton(window) }))
      .find((candidate) => candidate.button !== null);
    if (!target) break;
    await clickWindowButton(target.window.title, target.button);
    dismissed.push({ title: target.window.title, text: target.window.text, button: target.button });
    await sleep(pauseMs);
  }
  return dismissed;
}

export async function closePluginManager() {
  const state = osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  if exists window "Lightroom Plug-in Manager" then return "open"
  return "closed"
end tell`);
  if (state === "closed") return false;
  await clickWindowButton("Lightroom Plug-in Manager", "Done");
  return true;
}

const NEW_CATALOG_DIALOG = "Create Folder with New Catalog";

export async function waitForWindow(title, { timeoutMs = 20_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  if exists window ${quote(title)} then return "yes"
  return "no"
end tell`);
    if (found === "yes") return;
    await sleep(500);
  }
  throw new Error(`window "${title}" did not appear within ${timeoutMs / 1000}s`);
}

export async function submitNewCatalogDialog(folderName, expectedParentName) {
  await ensureLightroomFrontmost();
  const parentName = onElement(NEW_CATALOG_DIALOG, "AXPopUpButton", "Where:", "return value of e");
  if (parentName !== expectedParentName) {
    await clickWindowButton(NEW_CATALOG_DIALOG, "Cancel");
    throw new Error(
      `New Catalog dialog proposes the folder "${parentName}", expected "${expectedParentName}"; create the catalog by hand and use --adopt-open-catalog`,
    );
  }
  onElement(
    NEW_CATALOG_DIALOG,
    "AXTextField",
    "Save As:",
    `set focused of e to true\n      set value of e to ${quote(folderName)}\n      return "set"`,
  );
  await sleep(500);
  await clickWindowButton(NEW_CATALOG_DIALOG, "Create");
}

export async function openNewCatalogDialog() {
  await clickMenuItem("File", "New Catalog");
  await waitForWindow(NEW_CATALOG_DIALOG);
}

export function lightroomIsRunning() {
  try {
    execFileSync("pgrep", ["-x", LIGHTROOM_PROCESS_NAME]);
    return true;
  } catch {
    return false;
  }
}

function confirmQuitIfAsked() {
  return osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  repeat with w in windows
    try
      if exists button "Yes" of w then
        set asksToQuit to false
        repeat with e in (static texts of w)
          if (value of e as text) contains "really want to quit" then set asksToQuit to true
        end repeat
        if asksToQuit then
          click button "Yes" of w
          return "confirmed"
        end if
      end if
    end try
  end repeat
  return ""
end tell`);
}

export async function quitLightroom({ timeoutMs = 120_000 } = {}) {
  await ensureLightroomFrontmost();
  spawn("osascript", ["-e", `tell application "${LIGHTROOM_PROCESS_NAME}" to quit`], {
    stdio: "ignore",
    detached: true,
  }).unref();
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(1000);
    if (!lightroomIsRunning()) return;
    try {
      confirmQuitIfAsked();
    } catch {
      continue;
    }
  }
  throw new Error(`Lightroom did not quit within ${timeoutMs / 1000}s`);
}

const MAIN_WINDOW_TITLE = /^.+\.lrcat - .*Lightroom Classic/;

export function activeModule(windowNames) {
  const main = windowNames.find((name) => MAIN_WINDOW_TITLE.test(name));
  return main ? main.slice(main.lastIndexOf(" - ") + 3) : null;
}

function lightroomWindowNames() {
  return osascript(
    `tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}" to get name of every window`,
  ).split(", ");
}

export function lightroomModule() {
  return activeModule(lightroomWindowNames());
}

export function catalogWindowState(windowNames, catalogPath) {
  const windowPrefix = `${path.basename(catalogPath)} - `;
  if (windowNames.some((name) => name.startsWith(windowPrefix))) return "requested";
  return windowNames.some((name) => MAIN_WINDOW_TITLE.test(name)) ? "other" : "waiting";
}

async function launchWithCatalog(catalogPath, deadline) {
  if (lightroomIsRunning()) await quitLightroom();
  execFileSync("open", ["-a", LIGHTROOM_PROCESS_NAME, catalogPath]);
  while (Date.now() < deadline) {
    await sleep(2000);
    let names;
    try {
      names = lightroomWindowNames();
    } catch {
      continue;
    }
    const state = catalogWindowState(names, catalogPath);
    if (state !== "waiting") return state;
  }
  return "waiting";
}

export async function reopenWithCatalog(catalogPath, { timeoutMs = 180_000, launches = 3 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (let launch = 1; launch <= launches && Date.now() < deadline; launch++) {
    const state = await launchWithCatalog(catalogPath, deadline);
    if (state === "requested") {
      await ensureLightroomFrontmost();
      return { launches: launch };
    }
    if (state === "waiting") break;
  }
  throw new Error(`Lightroom did not open ${catalogPath} within ${timeoutMs / 1000}s and ${launches} launches`);
}
