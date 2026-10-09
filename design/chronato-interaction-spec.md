# Chronato application interaction specification

Design handoff · 9 October 2026. Chronato's adaptation of the Meetfacts + HoldFn design guide — the shared art direction and the two interaction specifications in the Meetfacts repository's `design/` folder — and of how both apps implement it (`Studio.swift`, `MenuBarController.swift`, their window controllers). Where this document and a concept plate disagree, this document governs.

**Implemented with this spec:** the Studio tokens and the Appearance preference (`Sources/Chronato/Studio.swift`, `Prefs.appearance`). **For the implementers:** everything else below. All measurements are macOS points. Example data is the fictional fixture of `TrackerStore.preview(_:)`.

## 1. Product boundary and intent

**Existing, kept:** start, pause, resume, stop and switch Kimai timers; one note per entry; Recent combinations; idle and sleep auto-pause with the away decision; the 24 h cap; auto-stops that wait while Kimai is unreachable; AI-agent sessions booked through `Chronato mcp`; the Reports window; Settings; Sparkle updates; the global shortcut ⌃⌥⌘T; the quit confirmation while a timer runs. `TrackerStore` stays the single source of truth; its API and behaviour do not change for this work.

**The quiet instrument.** A time tracker is glanced at a hundred times a day and opened for two seconds at a time. The menu bar shows one glyph and, while a timer runs, `h:mm`. Clicking it opens a **native macOS menu** (`NSStatusItem` + `NSMenu`), exactly as HoldFn and Meetfacts do: readable in one look, one click starts the usual thing, the keyboard works as in any Mac menu. Anything that needs typing opens a small native panel; anything that needs room is a native window (Reports, Settings).

**Changes:** the `MenuBarExtra(.window)` panel is replaced by the menu; the inline note field becomes the Note panel (§5); the start form becomes the Start submenu plus the New Timer panel (§6); Reports and Settings adopt the Studio material, native toolbars and the type scale (§8, §9); General gains Appearance.

**Not in scope:** editing past entries, a timesheet list, several parallel timers, goals, streaks, new notifications, the iPhone app.

## 2. Identity and colour

**Mark:** the C-stopwatch (`Branding/brand.md`). The status item uses `Brand.menuBarGlyph(running:)`, an 18 pt template image: idle is ring and crown; running is heavier, with the hand and pivot, so the state reads without colour. The menu-bar glyph is never tinted. About shows the flat mark at 96 pt: ring and crown in `textPrimary`, hand and pivot in `accentFill`.

**Tokens** (`Studio.swift`). Surfaces, text and lines are Meetfacts' and HoldFn's names and values, unchanged. Only the accent is Chronato's.

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F3F5F5` | `#101315` | Surrounding background |
| `sidebar` | `#E9EDEF` | `#151A1D` | Quiet structure |
| `surface` | `#F7F8F7` | `#1D2326` | Reports content, panel backgrounds |
| `raised` | `#FFFFFF` | `#293237` | KPI tiles, fields |
| `textPrimary` | `#1C2427` | `#F4F6F5` | Body, strong labels |
| `textSecondary` | `#53636B` | `#B5BEC2` | Metadata, helper text, axis labels |
| `lineSubtle` | `#CFD7DA` | `#3C484E` | Decorative separators |
| `controlBorder` | `#687A84` | `#80929B` | Essential boundaries, focus, neutral bars |
| `accentInk` | `#AE3520` | `#FF8F7A` | Tomato as text and focus |
| `accentFill` | `#E5533D` | `#E5533D` | Brand tomato: marks, dots, fills |
| `onAccentFill` | `#171A1B` | `#171A1B` | Text over `accentFill` |
| `errorInk` | `#9A2D25` | `#FFB3AA` | Error symbol and explanation |

`accentInk` is the tomato hue (OKLCH h 31–32°, from `#E5533D` at h 31.2°) with lightness moved and chroma lowered (0.185 → 0.161 light, 0.140 dark) for a quieter ink, until it clears 5.3:1 on the least contrasting surface of its appearance (`sidebar` in light, `raised` in dark) — the floor of the shared text tokens.

**Contrast, computed** (WCAG 2.x relative luminance, sRGB; canvas / sidebar / surface / raised):

| Pair | Light | Dark | Target |
|---|---|---|---|
| `textPrimary` | 14.42 / 13.39 / 14.82 / 15.78 | 17.18 / 16.16 / 14.65 / 12.05 | 4.5 |
| `textSecondary` | 5.70 / 5.30 / 5.86 / 6.24 | 9.87 / 9.28 / 8.41 / 6.92 | 4.5 |
| `accentInk` | 5.76 / 5.35 / 5.92 / 6.31 | 8.40 / 7.90 / 7.16 / 5.89 | 4.5 |
| `errorInk` | 6.91 / 6.42 / 7.11 / 7.56 | 10.91 / 10.26 / 9.30 / 7.65 | 4.5 |
| `controlBorder` (non-text) | 4.08 / 3.79 / 4.19 / 4.46 | 5.78 / 5.43 / 4.92 / 4.05 | 3.0 |
| `accentFill` (non-text) | 3.40 / 3.16 / 3.50 / 3.73 | 5.01 / 4.71 / 4.27 / 3.51 | 3.0 |
| `onAccentFill` on `accentFill` | 4.70 | 4.70 | 4.5 |
| white on `accentFill` | 3.73 — **not allowed for text** | | |

These are arithmetic checks of token pairs, not of rendered, composited pixels; verify the rendered states (§12).

**The accent is allowed for:** the primary action of a panel or window (§5, §6, Settings → Connect); the windows' `.tint(Studio.accentInk)` (focus, toggles, selection emphasis); "now" markers in windows (the current period's axis label in Reports, an 8 pt `accentFill` dot beside the word *Running*); the hand of the mark in About.

**Not allowed:** anything in the menu or the menu bar (system-drawn and template); large fills and backgrounds; chart bars; warnings; errors; decoration.

**Primary buttons** are native: `.buttonStyle(.borderedProminent)`, `.keyboardShortcut(.defaultAction)`, `.tint(Studio.accentFill)`, label in `onAccentFill`. White on tomato (3.73:1) is never used for text: if macOS draws the prominent label white regardless, drop the tomato tint for that button and let the system accent draw it. No custom-drawn button chrome.

**Errors** use `errorInk` with `exclamationmark.triangle.fill` **and** words. Tomato and this red are only 0.047 (light) and 0.086 (dark) apart in OKLab, so colour can never tell them apart; the symbol and the wording do. **Warnings** (not errors) use the system orange symbol only; their text stays `textPrimary`/`textSecondary` (orange text fails contrast).

**Customer colours** are Kimai data. They appear as an 8–10 pt dot beside the customer name, never as text colour and never as the only identification; in charts they are muted (§8).

**Typography:** system font everywhere; `Studio.Typography`.

| Role | Size / line | Weight | Token |
|---|---|---|---|
| Reports title | 24 / 30; 28 / 34 at window width ≥ 1280 | Semibold | `title`, `titleWide` |
| KPI value | 20 / 24, monospaced digits | Semibold | `figure` |
| Section heading | 17 / 23 | Semibold | `heading` |
| Controls, table rows, panel fields | 13 / 18 | Regular; customer rows Medium | `body` |
| Metadata, helper text, legend | 12 / 17 | Regular | `secondary` |
| Axis labels, small figures | 11 / 16, monospaced digits | Regular | `numeral` |
| Menu and status item | system menu font | — | not styled |

No uppercase microtext for information. Times that tick or line up use monospaced digits.

**Spacing:** `Studio.Space` (4 / 8 / 12 / 16 / 24 / 32). Radii: 8 for tiles and rows, 12 for control groups. Native control metrics win. One quiet shadow at most, and only on floating panels (the system's).

## 3. Status item

`NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)`. `button.image` = the glyph (template), `button.imagePosition = .imageLeading`, `button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)`, `button.title` = the time or empty. The system draws image and title in the menu bar's own colour and material; nothing is composed into one image except the pause badge. The title is updated when `store.elapsedMinutes` or the state changes — once a minute, never every second. No animation, ever: a timer runs for hours, and a perpetual drawing loop is not allowed.

| State | Image | Title | VoiceOver label (`button.setAccessibilityLabel`) |
|---|---|---|---|
| Unconfigured | idle glyph | — | "Chronato, not connected" |
| Idle | idle glyph | — | "Chronato" |
| Running | running glyph | `1:18`; with *Show customer name in the menu bar*: `1:18  Northwind Trade…` (customer ≤ 16 characters, else 15 + "…") | "Chronato, running, 1 hour 18 minutes, Northwind Traders" |
| Pending auto-stop | running glyph | frozen at the stop (`elapsedSeconds` already stops there) | "…, ends at 14:20 once Kimai is reachable" |
| Paused | idle glyph + `pause.fill` 7 pt heavy, 2 pt right of it, one template image (today's `MenuBarLabel.compose` without the title) | — | "Chronato, paused" |
| Away | as Paused | — | "Chronato, paused, you were away" |
| Offline | as the timer state | as the timer state | the timer state's label + ", Kimai not reachable" |

The VoiceOver duration is spelled out (`Duration.formatted(.units(width: .wide))`), not read as "one eighteen". Monospaced digits keep the width stable within an hour.

## 4. The menu

### 4.1 Construction

- One `NSMenu`, `autoenablesItems = false`, assigned to `statusItem.menu`, built by a `MenuBarController` (`NSObject`, `NSMenuDelegate`) as in HoldFn and Meetfacts. `menuWillOpen` starts `store.refresh()` and builds the menu from the store's current state.
- While open, the menu follows the store: when an observed value changes (`withObservationTracking`), rebuild it. The clock (`now`, `elapsedSeconds`, the totals) is read outside that observation: a `Timer` added in `RunLoop.Mode.common` retitles the running line and the totals line every second (a default-mode timer stops while a menu tracks — Meetfacts' lesson). The timer stops in `menuDidClose`.
- **Informative lines** are disabled items with an `attributedTitle` in `NSColor.labelColor` (or `secondaryLabelColor` where marked *secondary*), system menu font, monospaced digits for times, sentence case. They are never left in the dimmed disabled colour (it fails 4.5:1) and carry no `subtitle`. One line per item.
- **Commands** are enabled items: Title Case, verb first, an ellipsis only when more input follows. Each command carries an SF Symbol image (template), the macOS 26 menu convention. A `subtitle` (macOS 14+) is used only on commands, for a second line that differs between rows.
- Section headers: `NSMenuItem.sectionHeader(title:)`.
- Length: titles at most 44 characters, subtitles and informative lines at most 48, longer names truncated in the middle (`…`), so the menu stays near 320–360 pt wide. The full text goes into `toolTip`.
- Blocks are separated by one separator. An empty block is omitted together with its separator; never a leading, trailing or double separator.
- Submenus (Start, AI sessions) are filled in `menuNeedsUpdate(_:)` of their own `NSMenu`, so a large catalog does not slow the main menu.

### 4.2 Skeleton

Every block, in order, as it reads with a timer running. Optional parts are in brackets; the right-hand column is the item's image or kind, never part of the title.

```
    Title                                         Keys    Image / kind
[A  The request timed out.                                exclamationmark.triangle.fill, errorInk]
[A  Kimai is not reachable                                informative]
[A  The Internet connection appears to be offline.        informative, secondary]
[A  Try Again                                             arrow.clockwise]
────────
B   Automation · Ops Dashboard                            informative, semibold
B   Northwind Traders — Call tagging automation           informative, secondary
B   Running since 13:02 · 1:18:42                         informative, ticks each second
[B  Ends at 14:20 once Kimai is reachable                 informative, clock.badge.exclamationmark]
B   Today 3:05 · This week 12:40                          informative, secondary
────────
C   Pause                                         ⌘P      pause
C   Stop                                          ⌘S      stop
C   Edit Note…                                    ⌘E      pencil ("Add Note…" when there is none)
────────
D   Recent                                                section header
D   Automation · Ops Dashboard                            customer dot
      subtitle: Northwind Traders — Lead routing webhook
D   Weekly sync · Ops Dashboard                           customer dot
      subtitle: Northwind Traders
    … at most 5
────────
E   Switch To                                     ▸       play.circle
E   New Timer…                                    ⌘N      plus
────────
[F  AI Agents                                             section header]
[F  claude-code · Internal work                   ▸       sparkles
      subtitle: 21 min · Refactor billing export]
────────
G   Show Reports                                  ⌘R      chart.bar.xaxis
G   Open Kimai                                            arrow.up.forward.app
────────
H   Check for Updates…                                    arrow.triangle.2.circlepath
      or, when Sparkle found one: Update to 1.2.0 — Install…   arrow.down.circle
H   Settings…                                     ⌘,      gearshape
────────
I   Quit Chronato                                 ⌘Q      power
```

### 4.3 State contract

Blocks not named for a state are as in the skeleton. Times are examples.

| State | Status item | Blocks A–B (notices, header) | Block C (timer actions) | Other blocks |
|---|---|---|---|---|
| **Unconfigured** | idle glyph | B: "Not connected to Kimai"; *secondary* "Add your Kimai address and an API token to start." | **Connect to Kimai…** (`link`) → Settings, Connection tab | D, E, F, G hidden; H, I |
| **Connecting** (launch) | last known | A: "Connecting to Kimai…" (*secondary*). B: the persisted paused session if any, else nothing | as the timer state, disabled | D, E disabled |
| **Offline / unreachable** | last known; VoiceOver adds "Kimai not reachable" | A: "Kimai is not reachable", *secondary* the store's message, then **Try Again** (`store.refresh()`). With no saved connection (Keychain refused): **Connect to Kimai…** instead of Try Again. B: the last known state, unchanged | disabled | D, E disabled; F, G enabled |
| **Idle** | idle glyph | B: "Not running"; totals | — (block omitted) | E1 titled **Start** |
| **Running** | running glyph + `h:mm` | B as skeleton | **Pause** ⌘P, **Stop** ⌘S, **Add Note…/Edit Note…** ⌘E | D: one click switches. E1 titled **Switch To** |
| **Paused** (manual) | idle glyph + pause badge | B: entry lines; "Paused since 14:20 · 1:13 worked before" (toolTip: "Kimai has no pause: the entry ended at 14:20. Resume starts a new one with the same customer, project, activity and note."); totals | **Resume** ⌘P, **Stop** ⌘S (forgets the paused timer), **Add Note…/Edit Note…** ⌘E (edits the paused session's note) | E1 titled **Start Something Else** (starting replaces the paused timer) |
| **Away** (idle or sleep auto-pause; `store.awayNotice`) | as Paused | B: entry lines; "Away 14:02–14:27 (25 min)" (`AwayNotice.span`, with dates across midnight); totals | **Resume** ⌘P, subtitle "Time away is not tracked" · **Resume and Count Time Away**, subtitle "Starts again from 14:02" (`clock.arrow.circlepath`) · **Stay Paused** (`pause.circle`) · **Stop** ⌘S. No note item | E1 **Start Something Else** |
| Away > 4 h, < 24 h (`countAway == .needsConfirmation`) | as Away | as Away | Count item titled **Resume and Count Time Away…**; choosing it shows the existing alert ("Count 5 hr, 10 min away as work?" / "You were away …", **Count It** / **Cancel**); decided at the click, since the time away grows while the menu is open; confirmed → `resolveAway(.resumeCountingAway, confirmed: true)` | |
| Away ≥ 24 h (`.tooLong`) | as Away | B adds "More than a day away is not counted" | no Count item | |
| **Pending auto-stop while offline** (`store.pendingStopAt`) | running glyph, title frozen | A: offline lines. B: "Running since 13:02 · 1:18:00" (frozen), then "Ends at 14:20 once Kimai is reachable" | as Running, disabled while offline; once online Pause/Stop apply the pending end (store contract) | |
| **AI agent sessions present** | unchanged (AI time is not yours) | — | — | F: section **AI Agents**; one item per session (§4.7) |
| **Update available** | unchanged | — | — | H: **Update to 1.2.0 — Install…** replaces Check for Updates… |
| **Last error** (`store.lastError`) | unchanged | A first: the error (§4.8) | — | — |
| **Busy** (a change in flight) | unchanged | — | disabled | D, E disabled |

The quit confirmation is unchanged: **Quit Chronato** calls `NSApp.terminate(nil)`, and `applicationShouldTerminate` asks while a timer runs.

### 4.4 Key equivalents

Key equivalents of a status-item menu work while the menu is open; they are shown for speed and for learning. Escape closes the menu (system).

| Item | Keys | Convention check |
|---|---|---|
| Pause / Resume | ⌘P | Print elsewhere; Chronato prints nothing. |
| Stop | ⌘S | **⌘. rejected:** Command-period is the system cancel chord (like Escape; `IsUserCancelEventRef`), so an open menu can take it as "close" rather than as the item, and a stray cancel must never end a timer. Save does not exist in Chronato, which has no documents. |
| Add Note… / Edit Note… | ⌘E | "Use Selection for Find" only applies to text views. |
| New Timer… | ⌘N | New. |
| Show Reports | ⌘R | In the Reports window ⌘R reloads: the same intent, fresh reports. |
| Settings… | ⌘, | Standard. |
| Quit Chronato | ⌘Q | Standard; the confirmation stays. |
| Everything else | none | Recent and Start are one click; Count, Stay Paused, Open Kimai and updates are rare. |

⌃⌥⌘T is **not** a menu key equivalent: the Carbon hot key would also fire, pausing and resuming in one press. While it is on and registered, the Pause/Resume item's `toolTip` says "Also ⌃⌥⌘T from anywhere".

### 4.5 Recent

Section header **Recent**, then `store.recent.prefix(5)`; hidden when empty. One click starts that combination (`store.startAgain`); with a timer running it switches (Kimai stops the running entry in the same request). The running combination is never listed (`TrackingPolicy.recentCombinations` excludes it). Title "Activity · Project"; subtitle "Customer", plus " — Note" when the entry has one, because two rows often differ only by customer or note. Image: the customer's Kimai colour as a 10 pt dot in a 12 × 12 image (not template); no colour → `secondaryLabelColor` dot. toolTip: "Start again: Customer › Project › Activity — Note" ("Switch to: …" while running).

### 4.6 Start submenu

Item E1, titled **Start** (idle), **Switch To** (running) or **Start Something Else** (paused, away), `play.circle`, with a submenu:

```
Start ▸   Northwind Traders ▸   Ops Dashboard ▸   Automation
                                                  Consulting
                                                  Development
                                                  Weekly sync
          Acme Studio ▸         [Consulting]           ← one project: a section header, not a level
                                Consulting
                                Development
          Blue Harbor ▸         [Consulting] …
          ────────                                     ← customers from Recent above, the rest below
          In-house ▸            [Internal] Consulting, Development, Internal work
```

(The `preview` fixture, running state.)

- Level 1: customers with a startable project (`store.startableCustomers`): customers seen in Recent first, a separator, the rest by name. Customer dot as in Recent.
- Level 2: the customer's startable projects (`startableProjects(forCustomer:)`), by name.
- Level 3: the project's activities (`activities(forProject:)`), by name. Choosing one starts it at once with no note: `store.start(projectId:activityId:description: nil)`. A note is added afterwards (⌘E) or given up front in New Timer.
- **A level with exactly one choice collapses:** a customer with one startable project lists its activities directly under a section header with the project's name; a Kimai user with one startable customer gets its projects directly under a header with the customer's name. Activities never collapse — choosing one is the action.
- Nothing startable: E1 disabled, toolTip "No project with an activity is visible to this Kimai user."
- Long lists scroll natively and type-select works; New Timer… is the searchable route.

### 4.7 AI agents

Section header **AI Agents**, one item per `store.agentSessions` entry, enabled, `sparkles` image, with a submenu:

- Title "agent · Activity" (or project). Subtitle "21 min · description", the time frozen at `stoppedAt` for a stopped one. A session Kimai refused (`lastError != nil`): image `exclamationmark.triangle.fill` in `errorInk`, subtitle "Not booked — Kimai refused it".
- Submenu: informative "Customer › Project › Activity", informative description; for a refused session also the informative refusal text, a separator and **Discard Session** (`AgentSessions.remove`, then `store.refresh()`).

### 4.8 Last error

The first item of block A: `exclamationmark.triangle.fill` tinted `Studio.NS.errorInk` (non-template image), the message's first sentence as an informative line in `labelColor` (≤ 48 characters, full text in `toolTip`). It is shown once: `menuDidClose` sets `store.lastError = nil` after a menu that displayed it closes, and the store clears it on its next successful change. Background failures keep their existing notifications.

### 4.9 Honest wording

1. *Running*, *Paused* and their times come only from what Kimai answered (`store.active`, `store.paused`); the menu never shows an optimistic state after a click. While a change is in flight the actions are disabled, nothing claims it worked.
2. *Paused* is Chronato's word: Kimai ended the entry. The toolTip says so; Resume starts a new entry.
3. Offline, the header shows the last known state under "Kimai is not reachable"; it is never presented as current without that line.
4. A waiting auto-stop reads "Ends at 14:20 once Kimai is reachable", never "Stopped".
5. A note is never reported "Saved": the Note panel closes on success and stays open with the error on failure.
6. "Not booked" only for AI sessions Kimai refused; "Update to x" only when Sparkle found x.
7. No "synced", "all caught up", "tracked automatically", "saved to Kimai".
8. Formats: `h:mm` in the menu bar and totals; `h:mm:ss` only on the running line; decimal hours in Reports (existing `DurationText`). Times today as "13:02", otherwise "Fri, 9 Oct, 17:30" (existing `sinceText`).

## 5. Note panel

Opened by **Add Note… / Edit Note…** (⌘E) while running or paused (manual). Not offered in the away state.

- **Window:** `NSPanel`, style `[.titled, .closable, .utilityWindow, .nonactivatingPanel]`, title "Note", `isFloatingPanel = true`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = false`, `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]`, `isReleasedWhenClosed = false`. Content 360 pt wide, height to fit, `Studio.surface` background, 16 pt padding.
- **Content:** "Activity · Project" (13 semibold, `textPrimary`); the customer (12, `textSecondary`); a single-line text field (13 pt, placeholder "Add a note", prefilled with the saved note or the store's draft, all text selected); an error line when saving failed (`errorInk` symbol + words); **Cancel** and **Save** (default).
- **Return** saves: `store.setDescription(text, entryId:)` — the running entry's id, or none for the paused session. The panel closes only when it returned `nil`; on an error it stays open with the text and shows the error.
- **Esc**, **Cancel** or the close button discard: the draft goes back to the saved text (`setNoteDraft(saved, for:)`) and the panel closes.
- **Typing** is the store's draft (`setNoteDraft(text, for: id)`, running entry only), so a pause, stop, switch, hot key or auto-pause meanwhile still saves it (store contract).
- **Clicking elsewhere** (the panel resigns key) saves if the text changed, then closes, as the inline field does today; a failure lands in `store.lastError`.
- If the entry ends or is replaced while the panel is open (`store.active?.id` changes), the panel closes; the store has saved the draft.
- **Position:** top edge 6 pt below the status item's button window, centred on the button, kept 8 pt inside the screen's `visibleFrame`. When the button has no window (hidden behind the notch or a full menu bar), centred horizontally on the screen with the mouse, its top at one third of the height.
- **Activation:** the panel becomes key without activating Chronato, so the app the user was in stays frontmost and gets the keyboard back when the panel closes. ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z must work in the field: `NSApp.mainMenu` holds the standard Edit menu (the SwiftUI `App` provides one; an AppKit-only app installs Meetfacts' `installMainMenu` Edit menu at launch).

## 6. New Timer panel

Opened by **New Timer…** (⌘N), also while a timer runs (it then switches). Same panel kind and position rule as §5, title "New Timer", 440 × 400 pt, minimum 400 × 320, resizable, frame autosaved.

- **Content, top to bottom:** a search field, focused, placeholder "Search customers, projects and activities"; the result list; a note field, placeholder "Note (optional)"; the error line when starting failed; **Cancel** and **Start** (default; titled **Switch** while a timer runs).
- **Results:** every startable combination as one row: customer dot, "Activity" (13, `textPrimary`), below it "Customer › Project" (12, `textSecondary`).
- **Order:** the last choice (`Prefs.lastCustomerId`, `lastProjectId`, `lastActivityId`) first, then the combinations of Recent customers in recency order, then the rest by customer, project and activity name.
- **Search:** case- and diacritic-insensitive; every whitespace-separated term must appear in the customer, project or activity name (`localizedStandardContains`); same order. "nor auto" finds Northwind Traders › Ops Dashboard › Automation. No match: "No match for “…”" (12, `textSecondary`) in the list, Start disabled.
- **Keyboard first:** the first row is selected; ↑/↓ in the search field move the selection; Tab goes to the note field; Return in either field starts the selected row; Esc cancels; double-clicking a row starts it.
- **Start** calls `store.start(projectId:activityId:description:)`, which also stores the last choice. Success closes the panel. Failure keeps it open with query, selection and note, and shows the error.
- Offline or busy: Start disabled, with "Kimai is not reachable" or nothing respectively. The query is not remembered between openings; the last choice is.

## 7. Windows and activation

Reports and Settings are ordinary resizable/closable windows with traffic lights and frame autosave. Opening either makes Chronato a regular app for as long as one is open — `NSApp.setActivationPolicy(.regular)`, `NSApp.activate()`, `makeKeyAndOrderFront` — so it has a Dock tile, ⌘-Tab and its own menu bar with the Edit menu; closing the last returns it to `.accessory` (Meetfacts' and HoldFn's `present`/`windowWillClose`). Panels never change the activation policy. ⌘W closes a window.

Opening a SwiftUI `Settings` or `Window` scene from AppKit has no public API (`showSettingsWindow:` is ignored since macOS 14). Recommended: AppKit windows whose content is an `NSHostingController` with `sceneBridgingOptions = [.toolbars, .title]` (macOS 14+), so the SwiftUI `.toolbar` becomes the window's native `NSToolbar`; and an `NSTabViewController` with `tabStyle = .toolbar` for Settings.

## 8. Reports window

- **Size:** default 960 × 680, minimum 760 × 540, frame autosaved. Window title "Chronato Reports" (accessible identity, Window menu) with `titleVisibility = .hidden`: the period title appears once, in the content, as in Meetfacts.
- **Toolbar** (native): navigation — a control group **‹ Today ›** (⌘←, ⌘T, ⌘→; › disabled when the period ends in the future); principal — **Period** segmented Day / Week / Month / Year (⌘1–⌘4, as in Calendar); primary action — **Scope** segmented Me / AI / All (existing help text), **Reload** (`arrow.clockwise`, ⌘R; a small progress indicator in its place while loading), **Copy Summary** (`doc.on.doc`, ⇧⌘C; reads "Copied" with `checkmark` for 1.5 s after the pasteboard write). At the minimum width the toolbar overflows natively.
- **Content:** `Studio.surface`, opaque, 24 pt padding (16 at the minimum width), `.tint(Studio.accentInk)` at the root.
  - Title: the existing period title ("October 2026", "Week 41 · 5–11 Oct 2026") in `Typography.title`, `titleWide` from 1280 pt. Below it one 12 pt `textSecondary` line with the scope ("My hours", "AI agents", "Everyone"); notices (own entries only, reload failed) as further 12 pt lines with their symbol — `info.circle` in `textSecondary`, the failure in `errorInk`.
  - KPI row: tiles in `raised`, radius 8, 0.5 pt `lineSubtle` border (`controlBorder` with Increase Contrast), 12 × 14 padding, 12 pt apart; label 12 `textSecondary`, value `Typography.figure`, caption 12 `textSecondary` with monospaced digits.
  - Chart and AI card, 200 pt high, 16 pt apart.
  - Breakdown: a native outline table (SwiftUI `Table` with `DisclosureTableRow`, macOS 14+). Columns Customer / Project / Activity (flexible), Share (150: bar and percentage), Hours (72, trailing), Revenue (100, trailing; hidden when there is no revenue); numbers in monospaced digits. Customers expanded, projects collapsed by default (as today); customer rows Medium, activity rows `textSecondary`; separators `lineSubtle`; no alternating rows; the system selection colour (macOS ignores tint there — don't fight it). ↑/↓ move, ←/→ collapse and expand.
- **Chart, restrained:** bars in the customer colour at 85 % opacity over the surface (fallback palette the same), corner radius 2, no gradients, shadows or hover effects. Horizontal grid lines `lineSubtle` 0.5 pt, no vertical ones; axis labels `Typography.numeral` in `textSecondary` with an "h" suffix. The bucket containing now gets its axis label in `accentInk`, semibold — the chart's only accent. Legend top leading, 12 pt `textSecondary`, hidden over eight customers (as today). Share bars in the table: track `lineSubtle`, fill the customer colour (children at 55 %, as today).
- **AI card:** a `raised` tile like the KPIs; heading "AI agents" 13 semibold `textSecondary`; share bars in `controlBorder` — neutral, because agents are not customers.
- **States** keep today's wording: loading (indeterminate progress), "No time booked", "Couldn't load the report" with **Try Again**, "Not connected".

## 9. Settings window

- Native toolbar tabs: **General** (`gearshape`), **Connection** (`network`), **AI Agents** (`sparkles`), **About** (`info.circle`). The window title follows the tab; 560 pt wide, height fits the tab (AppKit animates the change); not resizable.
- Panes keep their grouped forms (`.formStyle(.grouped)`) on the system's form backgrounds — this is System Settings' look, not a Studio surface — with `.tint(Studio.accentInk)`. Errors in `errorInk` with symbol; warnings an orange symbol with ordinary text (§2).
- **General**, in this order: *Startup* (Open at login, approval row); *Tracking* (Auto-pause when idle, Global shortcut ⌃⌥⌘T, Show customer name in the menu bar, the 24 h footer); *Appearance* — a pop-up picker labelled "Appearance" with **System**, **Light**, **Dark** (`AppearanceMode.allCases`, `label`), bound to `@AppStorage(Prefs.appearance)`, default `system`. Changing it applies at once to every Chronato window, panel and menu: `AppearanceMode.follow()`, called at launch, observes the pref and sets `NSApp.appearance`. Nothing else to call.
- **Connection** and **AI Agents** unchanged in behaviour.
- **About:** the flat mark (§2) at 96 pt, "Chronato" 24 semibold, "Version x" 13 `textSecondary`, the existing tagline, link, update controls and licence lines (12 `textSecondary`).

## 10. Motion

| Event | Treatment |
|---|---|
| Status item, menu | None. The title changes once a minute; the glyph swaps instantly with the state. |
| Panels appear and close | The system's (`animationBehavior = .utilityWindow`). |
| Reports period or scope change | Content crossfade, `Studio.motion` (120 ms, ease-out 0.16, 1, 0.3, 1); toolbar and title stay put. |
| Outline expand and collapse | `Studio.motion` (replaces today's 0.2 s snappy). |
| Copy Summary → Copied | Immediate; back after 1.5 s. |
| Loading | Indeterminate progress only; never a percentage or countdown. |

With Reduce Motion (`accessibilityReduceMotion`) every one of these is immediate. Nothing animates while idle.

## 11. Accessibility

- The status item's label follows the state (§3); menu titles read as words — no "●", "⚠" or "⏸" characters in titles (VoiceOver reads them aloud); symbols are images.
- Informative menu lines and all window text meet 4.5:1, essential non-text 3:1 (§2); nothing essential sits in the dimmed disabled colour.
- Colour is never the only cue: customer names beside dots, errors with symbol and words, running shown by the glyph's hand and the word *Running*.
- Everything works by keyboard: native menu navigation and type-select; both panels keyboard-first; Reports toolbar shortcuts and the outline table; Full Keyboard Access reaches every control.
- Increase Contrast strengthens tile borders to `controlBorder`; Reduce Transparency needs nothing (Studio surfaces are opaque); Reduce Motion as §10.

## 12. Verification and acceptance

The GUI is not driven by tools. Implementers verify through `swift run Chronato snapshot <dir>` and text dumps, both appearances:

- PNGs of the Note panel, the New Timer panel (empty query, query "nor auto", no match), Reports, every Settings tab, and the status-item image + title per state.
- `menu-<state>.txt` for every row of §4.3: the `NSMenu` built from a preview store, one line per item — submenu depth, title, subtitle, key equivalent, enabled, image name — diffed against §4.2–§4.7. Preview states missing today (pending stop, last error, update available, refused AI session, long and day-long away) are added to `TrackerStore.preview(_:)`.

Accepted when:

1. Clicking the status item opens a native `NSMenu`, not a window; Escape, arrow keys, type-select and Return behave as in any Mac menu.
2. Every `menu-<state>.txt` matches §4: titles, order, separators, key equivalents, enabled state.
3. The status-item glyph is a template in every state; the running title is `h:mm` in monospaced digits, updated once a minute; nothing animates.
4. One click on a Recent item or an activity in Start starts it; the running combination is never in Recent; single-choice levels collapse.
5. ⌘P, ⌘S, ⌘E, ⌘N, ⌘R, ⌘, and ⌘Q work while the menu is open; ⌘. never stops a timer.
6. Note panel: prefilled; Return closes only after Kimai accepted the note; Esc discards; typing survives a ⌃⌥⌘T pause; ⌘V works; the previously active app stays active.
7. New Timer: "nor auto" + Return starts Northwind Traders › Ops Dashboard › Automation on the fixture; the last choice is preselected; a failed start keeps query, selection and note.
8. Away: Count without asking up to 4 h; "…" and the alert above 4 h; no Count item and the explanatory line from 24 h; Resume, Stay Paused and Stop do what `resolveAway` does.
9. Offline: the last known state under "Kimai is not reachable"; Kimai actions disabled; Try Again refreshes; a pending stop reads "Ends at … once Kimai is reachable".
10. Reports: title once at 24/28 pt; native toolbar with ⌘1–⌘4, ⌘←/⌘T/⌘→, ⌘R, ⇧⌘C; usable at 760 × 540, 960 × 680 and 1440 × 900; muted chart with one accent; the outline table works by keyboard.
11. Settings: toolbar tabs; Appearance System / Light / Dark changes every Chronato window, panel and menu at once and survives a relaunch.
12. Rendered contrast meets §2 in both appearances; errors carry symbol and words; white is never set on tomato.
13. Reduce Motion leaves no animation in Reports; nothing else animates to begin with.
14. `swift build` with no new warnings, `swift test`, and `scripts/e2e.sh` (all 169 checks) pass.

## 13. Implementation map

- `Sources/Chronato/Studio.swift` — tokens, `AppearanceMode` (done).
- `Sources/Chronato/TrackerStore.swift` — `Prefs.appearance` (done). Store API unchanged; preview states grow for §12.
- `Sources/Chronato/ChronatoApp.swift` — `AppearanceMode.follow()` at launch (done); the status item and controller replace the `MenuBarExtra` scene.
- `Sources/Chronato/MenuBarController.swift` (new) — status item, menu, delegate; takes `EntryNames`, `sinceText`, `minutes()`, `startableCustomers` and `MenuBarLabel.compose`'s pause badge from `MenuPanel.swift`, which goes away.
- `Sources/Chronato/NotePanel.swift`, `NewTimerPanel.swift` (new) — §5, §6.
- `Sources/Chronato/ReportsView.swift` — §8. `SettingsView.swift`, `SettingsAgents.swift` — §9. `Updater.swift` — the menu item replaces `UpdateReminderButton` and `CheckForUpdatesButton`.
- `Sources/Chronato/Snapshot.swift` — §12 renders and menu dumps.
- `Sources/Chronato/Brand.swift` — `Brand.accent` forwards to `Studio.accentFill`; the flat mark for About is drawn from `Branding/brand.md`'s construction.
