const familyOf = (key) => `${key.stored.replace(/2012$/, "").match(/[A-Z][a-z]*$/)[0]} at 1/${key.scale}`;

export function scaleFamilies(keys) {
  const families = new Map();
  for (const key of keys) {
    const family = familyOf(key);
    if (!families.has(family)) families.set(family, { family, key });
  }
  return [...families.values()];
}

export function probeValue(key, fraction = 0.5) {
  const neutral = key.neutral ?? 0;
  return Math.round(neutral + (key.range[1] - neutral) * fraction);
}

const storedOf = (key, entry) => (typeof entry?.[key.stored] === "number" ? entry[key.stored] : null);

export function storedMismatch(key, written, entry) {
  const expected = written / key.scale;
  const stored = storedOf(key, entry);
  if (stored !== null && Math.abs(stored - expected) * key.scale <= key.tolerance) return null;
  return { key: key.name, stored_field: key.stored, written, expected, stored };
}

export function describeMismatch({ key, stored_field: field, written, expected, stored }) {
  return `${key} written ${written}: expected ${field} ${expected}, stored ${stored}`;
}

export function observedScales(keys, values, entry, unchanged) {
  const mismatches = [];
  const notObserved = [];
  for (const key of keys) {
    if (storedOf(key, entry) === null || unchanged.includes(key.name)) {
      notObserved.push(key.name);
      continue;
    }
    const mismatch = storedMismatch(key, values[key.name], entry);
    if (mismatch) mismatches.push(mismatch);
  }
  return { mismatches, notObserved };
}
