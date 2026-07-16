# Design QA — remove idle status card

- Source visual truth: `/var/folders/t0/ldj7myg512z44g5b_d4xc3d40000gn/T/codex-clipboard-8b6a37f6-f7d0-4d71-b7bf-eab25b8b6fb7.png`
- Implementation screenshot: `/tmp/usaige-remove-idle-section.png`
- Viewport: 1280-pixel desktop viewport; focused status-section capture
- State: agent-status section, default animation state

## Full-view comparison evidence

The source annotation marks the fifth “Idle / No light” card for removal. The revised section contains only the four active status priorities: Error, Recent completion, Needs input, and Running.

## Focused region comparison evidence

The focused implementation capture shows four equal status columns after the priority label. There is no empty fifth column, and the click-behavior explanation below retains its original width and alignment.

## Findings

- No remaining P0, P1, or P2 mismatch for the requested removal.
- Fonts and typography: unchanged.
- Spacing and layout rhythm: four status cards distribute evenly; compact layouts use a balanced 2 × 2 grid.
- Colors and visual tokens: unchanged.
- Image quality and asset fidelity: no image assets changed.
- Copy and content: “Idle” and “No light” were removed; the separate no-active-task click behavior remains because it describes a real interaction.
- Accessibility and browser state: the DOM contains four status cards, zero exact “Idle” labels, and no console errors.

## Comparison history

1. Earlier finding: P1 — the annotated idle status card remained visible as a fifth priority.
2. Fix: removed the idle card and changed desktop/tablet grids from five to four columns; removed the compact last-card spanning rule.
3. Post-fix evidence: `/tmp/usaige-remove-idle-section.png` shows four evenly distributed active priorities.

## Implementation checklist

- [x] Remove the idle card.
- [x] Rebalance desktop and tablet grids.
- [x] Preserve the compact 2 × 2 status layout.
- [x] Preserve the no-active-task click explanation.
- [x] Check DOM count and console errors.

## Follow-up polish

None for this scoped removal.

final result: passed
