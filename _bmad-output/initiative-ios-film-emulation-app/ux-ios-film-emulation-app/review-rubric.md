# Spine Pair Review — iOS Film Emulation App

## Overall verdict

Strong. Both spines form a complete, consistent contract a downstream builder can source-extract cleanly. DESIGN.md has full token coverage and detailed component specs. EXPERIENCE.md has three well-structured key flows with named protagonists and climax beats. Minor gaps: no `{token}` cross-references from EXPERIENCE to DESIGN, and one deferred capability (trim) lacks a flow.

## 1. Flow coverage — adequate

Checked 9 capabilities from spec (CAP-2, CAP-3, CAP-5, CAP-6, CAP-7, CAP-9, CAP-11, CAP-12, CAP-13). Three key flows defined.

### Findings
- **medium** CAP-5 (trim) has no key flow. Trim is deferred to v2 per user clarification during Discovery, but the spec still lists it as a v1 capability. Flow gap is correct for v1 UX scope, but spec/UX mismatch should be resolved. *Fix:* Either add a trim flow or note in EXPERIENCE.md that trim is deferred to v2.
- **low** No failure path described in Flow 1 (permissions denied path). Flows 2 and 3 also assume happy path. *Fix:* Add a one-line failure branch to at least Flow 1: "If camera permission is denied, Alex sees the permission-required screen."

## 2. Token completeness — strong

All DESIGN.md YAML frontmatter tokens have values. 10 color tokens (all hex), typography with 4 sub-tokens (all populated), 4 rounded values, 8 spacing values, 6 component tokens with size specs. No `{path.to.token}` references used in EXPERIENCE.md prose — tokens are named in prose instead.

### Findings
- **low** EXPERIENCE.md references colors by semantic name ("blue", "red", "white") rather than DESIGN.md token names (`accent`, `record`, `text-primary`). Downstream could still resolve these, but using token names would make the contract machine-readable. *Fix:* Replace color references in EXPERIENCE.md with `{colors.accent}`, `{colors.record}`, etc.

## 3. Component coverage — strong

8 components in DESIGN.md, 8 behavioral patterns in EXPERIENCE.md. Every component has both a visual spec and a behavioral spec.

| Component | DESIGN.md | EXPERIENCE.md |
|-----------|-----------|---------------|
| Record Button | ✓ (sizes, states, animation) | ✓ (Record Flow) |
| Stock Strip | ✓ (dimensions, states) | ✓ (Stock Selector) |
| Toolbar | ✓ (dimensions, layout) | ✓ (Lens Selection, Flash, Portrait, EV, Gear) |
| EV Slider | ✓ (dimensions, track, thumb) | ✓ (Exposure Controls) |
| Readouts | ✓ (dimensions, locked state) | ✓ (Exposure Controls) |
| Render Pill | ✓ (dimensions, states) | ✓ (Render Queue) |
| Lens Selector | ✓ (layout, states) | ✓ (Lens Selection) |
| Settings Sheet | ✓ (presentation, sections) | ✓ (Settings Sheet) |

No findings.

## 4. State coverage — strong

10 state patterns defined. Every IA surface has states covered:
- Preview: idle, recording, permissions denied ✓
- Record Button: idle, recording, blocked ✓
- Stock Strip: idle, toolbar-open ✓
- Toolbar: hidden, visible ✓
- Readouts: hidden, visible, locked ✓
- Render Pill: hidden, rendering, failed, queue-idle ✓
- Free Space: low warning, no space block ✓
- Settings: presented as sheet (single state) ✓

### Findings
- **low** No "first launch / cold start" state described. The permissions flow (Flow 1) covers the sequence, but the IA doesn't call out the pre-permission screen state explicitly. *Fix:* Add a "Cold start" state to State Patterns: "Camera preview hidden. Permission dialog sequence in progress."

## 5. Visual reference coverage — n/a

No `mockups/`, `wireframes/`, or `imports/` files exist. No visual references to validate. Spines are the sole visual authority.

## 6. Bloat & overspecification — strong

DESIGN.md: Component specs are precise but load-bearing — an implementer needs the 80pt button, 4pt ring, pulse animation parameters. "Do's and Don'ts" is canonical per the design.md spec. No decorative narrative.

EXPERIENCE.md: Key flows are concrete (named protagonists, numbered steps, climax beats). Voice and Tone is 5 lines. No source restatement. No decorative narrative. Both spines are lean.

No findings.

## 7. Inheritance discipline — adequate

Sources resolve: `../spec-ios-film-emulation-app/spec-ios-film-emulation-app.md`, `../architecture-ios-film-emulation-app/architecture-ios-film-emulation-app.md`. Stock names ("250D", "500T") consistent across both spines and sources. Component names consistent across DESIGN and EXPERIENCE.

### Findings
- **low** EXPERIENCE.md doesn't use `{colors.X}` or `{typography.X}` token references to DESIGN.md. Color names are semantic prose ("blue", "red", "white") rather than token identifiers. *Fix:* Add inline token references in EXPERIENCE.md where colors/typography are mentioned, e.g., "Locked = blue (`{colors.accent-locked}`)."

## 8. Shape fit — strong

DESIGN.md sections in canonical order: Brand & Style → Colors → Typography → Layout & Spacing → Elevation & Depth → Shapes → Components → Do's and Don'ts. ✓

EXPERIENCE.md required defaults present: Foundation, IA, Voice and Tone, Component Patterns, State Patterns, Interaction Primitives, Accessibility Floor, Key Flows. ✓

Inspiration section omitted — defensible (mood.camera mentioned in memlog but not as a formal reference with screenshots/imports). Responsive section omitted — defensible (single surface, portrait only). No invented sections.

No findings.

## Mechanical notes

- YAML frontmatter complete in both files. ✓
- No broken cross-references. ✓
- EXPERIENCE.md `design: DESIGN.md` reference correct. ✓
- EXPERIENCE.md `sources` paths resolve. ✓
- No Mermaid diagrams (not needed for UX spines). ✓