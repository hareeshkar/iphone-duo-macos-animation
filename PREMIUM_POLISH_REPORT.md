# PREMIUM_POLISH_REPORT — macTilt `feat/clamshell-truthful-close-motion`

Branch: `feat/clamshell-truthful-close-motion` (fork) — all commits pushed, no PR per owner.
Verification: `swiftc -typecheck Sources/*.swift` exit 0, zero warnings, on working
tree AND on pristine pushed HEAD (detached worktree). Metal shaders are code-only
(no Metal Toolchain download per owner constraint — on-device build still required).

## 1. Fold feel — physics-first premium

**Operating point (validated against hinge hardware + perception literature):**
- Friction hinges are overdamped free-stop devices — the fold is critically-damped
  tracking only. No bounce, no unfold geometry, no overshoot. Ever.
- Follow τ = 62.5ms (followSpeed 16) + α-β predictor lead 60ms → net phase ≈ 2.5ms
  at 300°/s. The lead is load-bearing, not polish (uncompensated lag = 18.8°).
- Velocity-weighted, depth-weighted, turn-gated blur with rest deadzone; hinge
  specular highlight gated by bend angle; 90ms fade-only open (no fake unfold).

**Customization surface (all coupled so users can't decouple into fake):**
- Feel presets Gentle / Balanced / Sharp (+ auto Custom) set follow + blur + shine
  jointly. Prediction lead DERIVES from follow speed in code — exposing lead alone
  was rejected: it lets τ and anticipation split into floaty-fake territory.
- Gentle sits at follow 13, inside the lead formula's exact band (12.9–23.5);
  outside it the clamp degrades gracefully (laggy, never overshooting).
- Every slider carries a qualitative suffix (floaty/smooth/snappy/glued,
  crisp/subtle/dreamy/foggy, Off/glossy) so non-technical users feel numbers.
- Deliberately NOT built: bounce, unfold, overshoot, time-based close duration,
  persistent rest effects, close sounds, instant-snap bypass, custom haptics.

## 2. Engine quality (correctness > cleverness, every round)

- HID stays on a dedicated queue (Feature Reports are poll-only — verified across
  all community implementations); main thread keeps easing/consumption only.
- Epoch-guarded sample slot, lock-disciplined device lifecycle, async open/close,
  timestamped dt-normalized velocity, time-based stillness, immediate 120Hz kick.
- Single-queue GPU uploads (copy + 3 mips, one buffer), BGRA-unified zero-copy
  warm SCStream fast path with one-shot fallback + kill switch, generation-
  guarded newest-wins publishing, true 0fps park (orderOut + drawable release).
- Capture diet: half-res Retina (full floor on 1x), cursor-free, cached
  content/filter keyed by displayID + geometry, hot-path probe removed.
- Overlay: hysteresis show/hide, time-based open fade, external/clamshell
  suppression via built-in-panel sleep + registry-first lid signal, cold-texture
  gate with pixel provenance (mode is not pixels — first-run wallpaper can never
  pose as desktop).

## 3. Interface — human words, full help, accessible

- Plain-language rewrite of every label/tooltip across settings, menu bar, and
  onboarding ("Animation when you close your MacBook", "Sticks to your lid",
  "Try the close-and-open preview"). Technical precision kept in the numbers.
- Tooltips + VoiceOver labels on every control including icon-only buttons,
  labelsHidden toggles/sliders/pickers, and the live angle badge.
- Test slider: endpoint captions, settings-aware readout, capture-once scrubbing
  (no per-tick capture storms), 0.6s ease-back release, Reduce Motion respected.
- Unified panel widths (500 settings / 520 onboarding), last-checked timestamp,
  dynamic preview menu title, permission-path copy that doesn't terrify.
- Rejected on evidence: custom slider haptics, reopen countdown sheet,
  predicted show, anticipation solo slider.

## 4. Process notes (for the next loop)

- One concern per commit — 20 revert-safe commits on the branch.
- Review loop ran R1–R5 with rising strictness (correctness, efficiency, premium,
  creativity hawks, all with full internet + hardware docs). Reviewers were wrong
  4+ times against the tree — verify every claim in-tree before implementing.
- Incident: one pushed hash didn't compile (stranded working-tree edit). Rule now:
  verify pushed HEAD via detached-worktree typecheck before calling anything done.
- On-device debt (needs the MacBook): SCK/sharingType feedback check, suppression
  matrix, feel blind test, cold-slam latency histogram, permission-flip refresh,
  reversal/jiggle dogfood counters, queueDepth=3 reliability across OS versions.
- Open infra questions: Metal Toolchain ~700MB download (still declined), PR timing.
