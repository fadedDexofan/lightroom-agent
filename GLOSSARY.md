# Glossary

Terms used by lightroom-agent's API, its documentation and the live kit that tests it against a real Lightroom. Photographic terms (technical gate, delivery size, look, preset) are defined in the bundled skill, `skills/lightroom-agent`.

## Language

### Guarded write

A write of the photo's mask array through Lightroom's undocumented mask setting, made only through the one module that writes the whole array in one gate, reads it back and restores it on a mismatch. A guarded write that constructs a mask entry or component also needs admission and is checked against the pinned format; one that only changes values or deletes constructs nothing and needs neither.

- Avoid: raw mask write, direct write

### Pinned format

The exact set of keys and value types a guarded write accepts for each kind of mask component it constructs or changes. Entries a write leaves alone are Lightroom's own data: they are not checked against it, only required to read back exactly.

- Avoid: pinned schema

### Mask-write admission

The decision, taken before a write that constructs a mask changes anything, whether it may be made in the open catalog on the running Lightroom build. It concerns the build, the catalog and the photo's process version, not the content of the write.

- Avoid: version gate, tested versions

### Certification

A passed run of the live kit's mask suite on the throwaway catalog of this machine, on the installed Lightroom build. It is the only thing that admits writes that construct masks outside the throwaway catalog.

- Avoid: live check (too wide: any observation against Lightroom is a live check)

### Certification record

The file a certification leaves on this machine, naming the Lightroom version and build, the process versions exercised and the checks that passed. Admission reads it; nothing else writes it.

### Throwaway catalog

A catalog the live kit creates from its own fixtures and marks with its marker file. Anything may be written to it and it may be deleted at any time. Use only the kit's fixtures in it.

- Avoid: test catalog, disposable catalog, sandbox

### Personal catalog

A user's working Lightroom catalog, as distinct from a throwaway catalog. An agent changes it only with that user's permission, and writes that construct masks also need admission.

### Live kit

The scripts that install a build into Lightroom, create and open the throwaway catalog, run observations and certification against the real application, and put Lightroom back on the personal catalog.

### Live session

A period in which an agent drives the real Lightroom, usually with a restart and a switch to the throwaway catalog. It runs only with the user's explicit permission and while no one else uses Lightroom; one agent writes at a time.

### Result envelope

The one shape every tool call answers in: an outcome, the data confirmed, and lists of the items that failed, are unknown, were not found or were never attempted.

- Avoid: response format, result object

### Outcome

One of four statements about a call. `done`: everything asked for happened and was confirmed. `partial`: some of it happened, and the lists say which items did not. `failed`: nothing changed (the call wrote nothing, or every write was read back as undone). `unknown`: something may have changed, the error names what was written, and the state must be read before any retry.

- `status` is not an alias of `outcome`.

### Write ledger

The record of what one call wrote, kept on the call's request context. A write enters it where it can no longer be taken back, and only a read that shows its effect undone voids it. When a call stops, no live entry means `failed` and any live entry means `unknown`; a successful reply's data and lists decide the rest.

### Refusal

An error a tool raises to say a rule stopped it. It words the problem; it does not decide the class, which comes from the write ledger.

### Mask id

A mask's `CorrectionID` in the photo's saved mask array, and a component's `MaskID` inside it. Mask tools address masks by these, not by what Develop has selected.

### Develop key

The name of one develop setting of a photo, exactly as Lightroom's SDK spells it (for example `Exposure2012`). The same name is used to write and to read.

- Avoid: setting name, slider name (not every key is a slider)

### Local key

The name of one adjustment of a mask, as the SDK spells it with the `local_` prefix (for example `local_Exposure`). Used when a mask is created and when it is adjusted.

- Avoid: creation name, mask slider

### Flag

Lightroom's pick state of a photo: `pick`, `reject` or `none`. One word for reading, writing and filtering.

- Avoid: pick status

### Color label

One of `red`, `yellow`, `green`, `blue`, `purple` or `none`. A photo without a label reads `none`.

- Avoid: gray (what Lightroom's raw read returns for an unlabelled photo)

### Displayed frame

The photo as a preview shows it: after orientation, crop and straighten. It is the frame an agent reads coordinates from.

### Stored frame

The unrotated, uncropped frame in which Lightroom stores mask geometry.

- Avoid: base coordinates, raw frame
