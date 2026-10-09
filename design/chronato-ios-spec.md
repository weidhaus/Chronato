# Chronato for iPhone: interaction specification

Design handoff · 9 October 2026. The iPhone adaptation of [the Mac specification](chronato-interaction-spec.md), which stays the authority for Chronato's identity, tokens and wording; this document governs the iPhone app, its widgets and its Live Activity. Both follow the Meetfacts + HoldFn art direction: native platform feel, the Studio material language (graphite, satin silver, one restrained accent: tomato), system typography, honest states, no decorative chrome. Example data is the fictional fixture of `PhoneTracker.fixture(_:)`. Measurements are iOS points.

**Implemented with this spec:** everything below (§14 lists the files). `PhoneTracker`, the App Intents and the App Group snapshot keep their behaviour; the app icon and the `Brandmark` image are the logo work's and are not changed here.

## 1. Product boundary and intent

**Kept:** start, pause, resume, stop and switch Kimai timers; one note per entry; Recent; New Timer with search; Today · This week; the 24 h cap; Reports by period and scope with the share summary; Settings; onboarding with the token check; the Home Screen and Lock Screen widget, the Live Activity (Lock Screen and Dynamic Island) and every App Intent, Siri phrase and widget button.

**The quiet instrument, on a phone.** Chronato is glanced at and touched for two seconds. The system draws the chrome — the floating tab bar, toolbars, sheets, search and their Liquid Glass — and Chronato draws only content, in the Studio inks, on the system's grouped backgrounds. No custom cards, tinted row backgrounds, filled tomato buttons, shadows or gradients. Where the Mac uses a menu, the iPhone uses a grouped list in the same order and words.

**Not on iPhone, honestly:** the away state and its decision (a phone has no keyboard or mouse idle signal, so nothing auto-pauses); the pending auto-stop (the 24 h cap is applied only when Kimai answers, so nothing waits for the network); AI-agent sessions (the MCP server runs on the Mac; their hours appear in Reports); Sparkle updates (the App Store and TestFlight update the app); the global shortcut. Should the engine gain away or pending-stop states, they use the Mac's words verbatim (§4.3).

## 2. Identity and colour

**Mark:** the app icon, from the `Brandmark` image set, large once — 88 pt in onboarding — and 56 pt in Settings → About. The Dynamic Island shows the flat mark, `Mark` (`Shared/Brand.swift`), drawn from the same `MarkRing` geometry as the Mac (`ChronatoCore`): the arc in `.primary`, the dot in `accentFill`.

**Tokens:** `iOS/Shared/Studio.swift` holds the Mac's tokens with the same names and values (`Sources/Chronato/Studio.swift`; change both together, as the art direction asks, rather than sharing a package). On iPhone they are inks and lines over the system's backgrounds:

| Role | iPhone | Why |
|---|---|---|
| Backgrounds | `systemGroupedBackground`, `secondarySystemGroupedBackground`, sheets and bars as the system draws them | System Settings' look, as the Mac's Settings panes; Liquid Glass comes from system components. `canvas`, `sidebar`, `surface`, `raised` exist for parity and are not used by the app |
| Body text, row titles, figures | `textPrimary` | |
| Metadata, captions, footers, row values | `textSecondary` | The system's `secondaryLabel` is 3.3:1 in light (table below) |
| Section headers | the system's | 17 pt semibold is large text: 3.3:1 meets 3:1 |
| Tint: toolbar buttons, links, selected tab, picker values, checkmarks, command symbols, Connect | `accentInk`, set with `.tint` at the root and as the `AccentColor` asset (light and dark), so alerts and dialogs match | |
| "Now": the running dot, the island's running mark, the island keyline, the chart's current-slot label | `accentFill` (dot, mark, keyline), `accentInk` (label) | |
| Errors | `errorInk` symbol `exclamationmark.triangle.fill` **and** words (`Problem`) | Tomato and this red are too close to tell apart |
| Warnings | system orange symbol, text in `textPrimary` | Orange text fails contrast |
| Share-bar tracks; neutral bars (AI agents) | `lineSubtle`; `controlBorder` | |

**Contrast, computed** (WCAG 2.x, sRGB; light: `systemGroupedBackground` #F2F2F7 / `secondarySystemGroupedBackground` #FFFFFF; dark: #000000 / #1C1C1E / `tertiarySystemGroupedBackground` #2C2C2E):

| Pair | Light | Dark | Target |
|---|---|---|---|
| `textPrimary` | 14.14 / 15.78 | 19.35 / 15.68 / 12.84 | 4.5 |
| `textSecondary` | 5.59 / 6.24 | 11.11 / 9.00 / 7.37 | 4.5 |
| `accentInk` | 5.65 / 6.31 | 9.46 / 7.67 / 6.28 | 4.5 |
| `errorInk` | 6.78 / 7.56 | 12.28 / 9.95 / 8.15 | 4.5 |
| `controlBorder` (non-text) | 4.00 / 4.46 | 6.50 / 5.27 / 4.32 | 3.0 |
| `accentFill` (non-text) | 3.34 / 3.73 | 5.64 / 4.57 / 3.74 | 3.0 |
| system `secondaryLabel` (for comparison) | 3.29 / 3.44 | 6.36 / 5.94 / 5.29 | — |
| white on `accentInk` | 6.31 | **2.22 — not allowed** | |
| white on `accentFill` | **3.73 — not for text** | | |

**The accent is allowed for:** the tint (above); the running dot and the island's running mark; the chart's current-slot label.

**Not allowed:** text of command rows (on iOS tomato text in a list reads as a destructive action, so a command row has a `textPrimary` title and a tinted symbol, like a Mac menu item); `.borderedProminent` or glass-prominent buttons (iOS draws their label white: 2.2:1 on `accentInk` in dark, 3.7:1 on `accentFill`); fills, cards, row backgrounds; chart bars; warnings and errors; decoration. On iOS 26 a sheet's `confirmationAction` is drawn by the system as glass with the label in the tint, which is allowed.

**Customer colours** are Kimai data: a 8–10 pt dot beside the customer's name, never text colour and never the only identification; chart bars at 85 %.

**Typography:** the system font and Dynamic Type everywhere. `Studio.Typography` keeps the Mac's role names, mapped to text styles:

| Role | iPhone | Mac |
|---|---|---|
| `title` (Reports period title) | Title 3 semibold | 24 / 28 semibold |
| `figure` (report figures) | Title 2 semibold, monospaced digits | 20 semibold |
| `heading` (what runs: "Activity · Project") | Headline | 17 semibold |
| `body` | Body | 13 |
| `secondary` (metadata, captions) | Subheadline | 12 |
| `numeral` (axis labels, small figures) | Caption, monospaced digits | 11 |
| The running time | 52 pt light, monospaced digits, scaled with Dynamic Type (`@ScaledMetric` relative to Large Title) | — |

No uppercase microtext. Times that tick or line up use monospaced digits. Spacing between things uses `Studio.Space` (4 / 8 / 12 / 16 / 24 / 32); list, control and bar metrics are the system's.

## 3. Structure

- `TabView` with **Track** (`stopwatch`), **Reports** (`chart.bar.xaxis`), **Settings** (`gearshape`): the iOS 26 floating tab bar. Each tab is a `NavigationStack` with a large title. Lists and forms are the default inset-grouped style.
- Sheets: **New Timer** (full height, it searches) and **Note** (medium detent).
- Without a saved connection the app shows onboarding (§9) instead of the tabs.
- **Appearance** (Settings): Match System, Light or Dark, stored under the Mac's key `appearance`, applied at once to every window of the app — sheets, alerts and dialogs included — through `overrideUserInterfaceStyle` (`AppearanceMode.apply()`; `preferredColorScheme(nil)` does not reliably return to the system's). Widgets and the Live Activity follow the system, like the rest of the Home and Lock Screen.

## 4. Track

### 4.1 Skeleton

Blocks in the Mac menu's order (its §4.2), as they read with a timer running. Brackets mark optional parts.

```
Track                                                     [progress indicator while busy]
[A  ⚠ The request timed out.                        ⓧ    errorInk symbol and text; ⓧ dismisses]
[A  Connecting to Kimai…                                  with a progress indicator]
[A  ⌁ Kimai is not reachable                              wifi.slash in orange
      The Internet connection appears to be offline.      textSecondary
    ↻ Try Again                                           refresh
    footer: Below is what Chronato knew last.]            only with a timer shown
B   Automation · Ops Dashboard                            Headline
    ● Northwind Traders — Call tagging automation         customer dot; textSecondary
    1:18:42                                               the running time, ticking
    ● Running since 13:02                                 accentFill dot
C   ‖ Pause
    □ Stop
    ✎ Edit Note…                                          "Add Note…" without a note
    footer: Today 3:05 · This week 12:40
D   Recent
    Automation · Ops Dashboard                     ▷      play.circle in textSecondary
    ● Northwind Traders — Lead routing webhook
    …                                                     up to 10 (TrackingPolicy)
    footer: Tap to switch to an entry. Touch and hold to change it first.
E   + New Timer…
```

Command rows (C, E, Try Again) are list buttons whose title is `textPrimary` and whose symbol is the tint; disabled, the whole row is dimmed. Symbols are the Mac menu's: `pause`, `play`, `stop`, `pencil`, `plus`, `arrow.clockwise`.

### 4.2 State contract

| State | A (notices) | B | C | D, E | Totals footer |
|---|---|---|---|---|---|
| **Unconfigured** | — | onboarding (§9) instead of the tabs | | | |
| **Connecting** (launch) | "Connecting to Kimai…" | the paused session if one is stored, else nothing — never "Not running" before Kimai has said so | disabled, as Offline | disabled | none (no 0:00 guess) |
| **Offline** | "Kimai is not reachable", the reason without its "Can't reach Kimai:" prefix, **Try Again** | the last known state, under the notice and its footer | disabled; a paused timer's Stop and note stay available (they need no Kimai) | disabled | last known |
| **Idle** | — | "Not running" | — | enabled | yes |
| **Running** | — | as the skeleton | **Pause**, **Stop**, **Add Note… / Edit Note…** | Recent switches; New Timer… | yes |
| **Paused** | — | names; "1:13" (the running time's size, `textSecondary`) "worked before"; "Paused since 14:20" with `pause.fill` | **Resume**, **Stop** (forgets the paused timer), **Add Note… / Edit Note…** | Recent and New Timer start something else | yes, then "Kimai has no pause: the entry ended at 14:20. Resume starts a new one with the same customer, project, activity and note." |
| **Busy** (a change in flight) | — | unchanged | disabled | disabled | |
| **Last error** (`lastError`, also the 24 h notice) | first, until dismissed (ⓧ) or the next successful change | | | | |

### 4.3 Away and pending stop

Not reachable on iPhone (§1). If the engine ever reports them, B and C take the Mac's words exactly: "Away 14:02–14:27 (25 min)"; **Resume** (footer "Time away is not tracked"), **Resume and Count Time Away** ("Starts again from 14:02"; with "…" and a confirmation over 4 h; absent from 24 h with "More than a day away is not counted"), **Stay Paused**, **Stop**; no note row. A waiting stop reads "Ends at 14:20 once Kimai is reachable", never "Stopped".

### 4.4 Interaction

- One tap on a Recent row starts that combination; while a timer runs it switches (Kimai stops the running entry in the same request). The running combination is never listed. Touch and hold: **Start** (or **Switch To**) and **Change and Start…**, which opens New Timer with that row and its note chosen. VoiceOver gets "Change and Start" as a custom action.
- Pull to refresh reloads the catalog and the state; returning to the foreground refreshes.
- Haptics confirm what Kimai accepted: `.start` when a new entry runs, `.stop` when it ended, `.error` with a new error, `.selection` on choices. Nothing vibrates optimistically.

### 4.5 Honest wording

The Mac's rules (its §4.9) apply unchanged: *Running* and *Paused* come only from what Kimai answered; while a change is in flight its controls are disabled and nothing claims it worked; *Paused* is Chronato's word and the footer says what Kimai did; offline, the last known state sits under "Kimai is not reachable"; a note is never reported "Saved"; no "synced", "all caught up", "tracked automatically". Formats: `h:mm:ss` only for the running time; `h:mm` for totals and worked time; decimal hours in Reports; times today as "13:02", else "Fri, 9 Oct, 17:30".

## 5. New Timer sheet

The Mac's New Timer panel (its §6) as a sheet, opened by **New Timer…** and by **Change and Start…**.

- `NavigationStack`, inline title "New Timer"; **Cancel** (`cancellationAction`); **Start**, titled **Switch** while a timer runs (`confirmationAction`, disabled without a selection, offline or busy; a progress indicator in its place while Kimai answers).
- Search in the navigation bar drawer, always shown, prompt "Search customers, projects and activities". Case- and diacritic-insensitive; every whitespace-separated term must appear in the customer, project or activity name: "nor auto" finds Northwind Traders › Ops Dashboard › Automation.
- Content, top to bottom: **Note (optional)**, first, so it stays above the keyboard (Return starts); its footer "Stops the running timer and starts this one." or "Starts this one instead of resuming the paused timer."; the error when starting failed, or the warning "Kimai is not reachable"; the results.
- A result row: customer dot, "Activity" (`textPrimary`), "Customer › Project" (`textSecondary`); a checkmark in the tint on the selected row (`isSelected` for VoiceOver).
- Order: the opening choice (the last started combination, or the Recent row being changed), then the combinations of Recent customers in recency order, then the rest by customer, project and activity name. The selection is the chosen row while it matches the search, else the first match. No match: "No match for “…”". Nothing startable: "No project with an activity is visible to this Kimai user."
- Starting closes the sheet once Kimai started the timer; a failure keeps query, selection and note and shows the error.

## 6. Note sheet

The Mac's Note panel (its §5), opened by **Add Note… / Edit Note…** while running or paused.

- Medium detent, inline title "Note"; the names ("Activity · Project", customer) without the note; one focused field, placeholder "Add a note", prefilled; **Cancel** and **Save**.
- **Save** or Return: unchanged closes; a running entry's note goes to Kimai and the sheet closes only when Kimai accepted it, else it stays with the text and the error; a paused session's note is kept with it (Resume carries it to Kimai). **Cancel** or a swipe down discards.
- It writes only to the timer it was opened for. If that timer ends or is replaced meanwhile (a widget, Siri, the Mac), Save is disabled and the sheet says "This timer has ended, so the note was not saved." — the text stays to copy.

## 7. Reports

Same data and maths as the Mac's Reports window (its §8), restrained the same way.

- Large title "Reports". Toolbar: **Today** (leading; disabled while the shown period contains today); **Show** (trailing menu: My hours `person` / AI agents `sparkles` / Everyone `person.2`; its symbol shows the choice); **Share Summary** (`square.and.arrow.up`, the Mac's Copy Summary text, through the share sheet), replaced by a progress indicator while reloading.
- Above the content: the period, segmented Day / Week / Month / Year; then ‹ the period title once (`title`) over the scope line ("My hours", "AI agents", "Everyone") ›. Notices as rows: "Only your own entries: …" (`info.circle`, `textSecondary`), "Couldn't reload: …" (`Problem`).
- **Chart cell:** "Total" (or the selected slot, "Tue 6 Oct"), the figure, the caption ("Ø 5.26 h on 5 days"; kept in place while a slot is read). Bars in the customer colour at 85 %, radius 2, no gradients or shadows; horizontal grid `lineSubtle` 0.5 pt; axis labels `numeral` in `textSecondary` with "h". The current slot's label is `accentInk` semibold and always shown; on a phone hours are labelled every sixth and days of a month every seventh, never next to the current one. Legend top leading, hidden over eight customers. Tap or drag reads a slot (the others drop to 35 %, a selection haptic). Chart text stops growing at the xxLarge size; 220 pt high.
- **Figures** as rows (the Mac's KPI tiles without the tiles): Billable, Revenue (with revenue only), Entries — title and caption leading, the figure trailing in `figure`.
- **AI agents:** one row per agent, `sparkles` in `textSecondary`, hours, a neutral `controlBorder` bar; with Everyone the footer "14 % of all hours".
- **Customers:** a native outline (`DisclosureGroup` rows): customers Medium with their dot and expanded, projects collapsed, activities in `textSecondary`; hours trailing; under each a share bar (track `lineSubtle`, fill the customer colour, 55 % below customers), the percentage and the revenue.
- **States:** a progress indicator while loading; "No time booked" with the scope's sentence; "Couldn't load the report" with the error and **Try Again**.
- No animation on period or scope changes: list rows would slide, and the Mac's crossfade has no list equivalent.

## 8. Settings

One grouped form, the Mac's sections in its order:

- **Connection:** Server, User, Kimai version (values in `textSecondary`); the status — "Connected" (green `checkmark.circle.fill`), "Connecting…", or the offline reason as a warning; **Open Kimai** (`arrow.up.forward.app`, the timesheet page in the user's language).
- **Disconnect…** in `errorInk`, with its confirmation ("Disconnect from Kimai?" — "Chronato removes the API token from this iPhone's Keychain. Your time entries in Kimai are not affected."); footer as before.
- **Appearance:** a menu picker, **Match System**, **Light**, **Dark** with `circle.lefthalf.filled`, `sun.max`, `moon`; footer "Widgets and the Live Activity follow the system."
- **AI Agents:** information only: agents book their own time from the Mac through Chronato's MCP server; their hours are in Reports under AI agents.
- **About:** the icon at 56 pt, "Chronato", "Version 1.0.2 (1)", the GitHub link; footer "Kimai time tracking from your iPhone. Free and open source (MIT). Not affiliated with Kimai."

## 9. Onboarding

Inline title "Connect". The icon at 88 pt, "Welcome to Chronato" (Title 2 semibold), one sentence in `textSecondary` — the mark large once, then the form. **Your Kimai:** server address (`globe`), API token (`key`) with the system Paste button (tinted `controlBorder`: its glyph is white); footer about the Keychain. Then the error, if any, and **Connect** as a semibold list button in the tint ("Connecting…" with a progress indicator). **Where do I get an API token?**: three steps with `1.circle`… in `textSecondary`. The token is checked against Kimai before anything is saved (unchanged).

## 10. Widgets and Live Activity

The system re-renders archived widget and Live Activity views in modes Chronato does not control (tinted and clear Home Screens, the Lock Screen's vibrancy, Always-On). So:

- Containers are the system's: the widget's `.containerBackground(.fill.tertiary)` (silver in light, graphite in dark) and the Lock Screen's material for the Live Activity.
- Text uses the hierarchical `.primary` and `.secondary` styles, never the appearance-dependent Studio colours (dynamic colours are not reliably resolved in archived views). The only Studio colour is `accentFill`, which has one value.
- Tomato only for running: the 8 pt dot beside the ticking time (Home Screen widgets, Lock Screen Live Activity, expanded island), the dot of the island's mark, the island keyline. Paused shows `pause.fill` in `.secondary`.
- Buttons are neutral (`.bordered`, `.tint(.primary)`: the system's grey with a primary label) and run the same App Intents as before (Pause, Resume, Stop, Start; `LiveActivityIntent`s in the app's process).
- Times use the default system design (not rounded) with monospaced digits.

| Surface | Running | Paused | Idle | Not connected |
|---|---|---|---|---|
| Small | ● customer, activity, ● time, Pause and Stop (symbols; names for VoiceOver) | "Paused", activity, "1:13 worked before", **Resume** | "Today 2:35", customer, **▶ Activity** | "Not connected to Kimai", "Open Chronato to connect." |
| Medium | "Activity · Project", ● "Customer — Note", ● time; **Pause**, **Stop** | "Paused", names, worked; **Resume**, **Stop** | "Today 2:35", "Activity · Project", customer; **Start** | as Small |
| Lock Screen rectangular | time, activity, customer | "Paused", activity, "1:13 worked before" | "Today 2:35", last activity, customer | "Chronato", "Not connected to Kimai" |
| Lock Screen inline | `stopwatch` time + activity | `pause.fill` "Paused · Activity" | `stopwatch` "Today 2:35" | "Chronato" |
| Live Activity, Lock Screen | "Activity · Project", ● "Customer — Note"; ● time; **Pause**, **Stop** | the same with "Paused" over "1:13"; **Resume**, **Stop** | — | — |
| Dynamic Island | compact: the mark (arc white, dot tomato), the time (Subheadline semibold, 60 pt wide); expanded: mark, customer, ● time, names, buttons | grey `pause.fill`, "1:13" in secondary | — | — |

## 11. Motion and haptics

| Event | Treatment |
|---|---|
| Tabs, sheets, menus, search, disclosure | The system's. |
| The running time | `Text(timerInterval:)` ticks by itself; no per-second app state. Totals update once a minute. |
| Period, scope, slot changes in Reports | Immediate. |
| Start, stop, pause accepted by Kimai; a new error; a choice | `.start`, `.stop`, `.error`, `.selection` haptics. |
| Loading | Indeterminate progress only. |

Nothing animates while idle. Reduce Motion leaves only the system's own adapted transitions.

## 12. Accessibility

- Dynamic Type throughout; the running time scales; the chart's text stops at xxLarge so the bars keep their room, while the figures above and the breakdown below keep scaling. At accessibility sizes rows wrap rather than truncate.
- VoiceOver: names are combined into one element; durations are spoken ("1 hour, 13 minutes worked before"); Recent rows carry a hint ("Starts a timer for this entry" / "Switches the timer to this entry") and the "Change and Start" action; the selected New Timer row is `isSelected`; decorative symbols and dots are hidden.
- Colour is never the only cue: running is the dot **and** the word *Running*; errors are the symbol **and** words; customers are named beside their dots.
- Contrast: §2's table; essential text never sits in the system's grey secondary label or in a disabled colour.
- Reduce Transparency and Increase Contrast are handled by the system's materials and controls, which Chronato does not replace.

## 13. Verification and acceptance

Verified in the iOS Simulator with fixtures, in light and dark (`xcrun simctl ui <device> appearance light|dark`), by reading screenshots (`xcrun simctl io <device> screenshot`):

- `-ChronatoFixture idle|running|paused|offline|error|unconfigured` (no network, no Keychain); `-ChronatoTab reports|settings`; `-reportPeriod day|week|month|year`, `-reportScope me|ai|all`; `-ChronatoSheet newTimer|note`; `-appearance light|dark` (the stored choice); Debug builds: `-ChronatoScroll bottom` (every list scrolled to its end) and `-ChronatoRenderWidgets YES` (the widget and Live Activity gallery, `Documents/WidgetGallery/*.png`).

Accepted when:

1. No custom card backgrounds, tinted rows, filled tomato buttons, shadows or gradients remain; bars, sheets and the tab bar are the system's.
2. Tomato appears only as the tint, the running dot and mark, and the chart's current label; white is never set on tomato.
3. Every state of §4.2 reads as specified, with the Mac's words; offline and busy disable what needs Kimai.
4. New Timer: "nor auto" + Start starts Northwind Traders › Ops Dashboard › Automation; the last choice is preselected; a failed start keeps query, selection and note.
5. Note: prefilled; Save closes only after Kimai accepted; a replaced timer is never written to.
6. Reports: one title; the chart's current slot accented and labelled; labels centred on their slots; the outline works; text capped in the chart only.
7. Appearance Match System / Light / Dark changes every window and sheet at once and survives a relaunch.
8. Widgets and the Live Activity keep every family, state and button; tomato only for running.
9. The Simulator build of the Chronato scheme (app and widgets) has no warnings; `scripts/ios-release.sh --dry-run` passes.

## 14. Implementation map

- `iOS/Shared/Studio.swift` (new) — tokens, `AppearanceMode`. `iOS/Shared/Brand.swift` — `Brand.accent` forwards to `accentFill`; `Dot`, `RunningDot`, `Mark`, `Problem`; `DurationText.hours` as on the Mac. `iOS/Shared/Assets.xcassets/AccentColor` — `accentInk`, light and dark.
- `iOS/App/ChronatoApp.swift` — root tint, Appearance, the Debug scroll aid. `TrackView.swift` — §4. `NewTimerSheet.swift` (was `StartForm.swift`) — §5. `NoteSheet.swift` (was `TimerCard.swift`) — §6. `ReportsTab.swift` — §7. `SettingsView.swift` — §8. `OnboardingView.swift` — §9.
- `iOS/Shared/WidgetViews.swift`, `LiveActivity.swift`, `iOS/Widgets/ChronatoWidgets.swift` — §10. `WidgetGallery.swift` renders them.
- `iOS/Shared/PhoneTracker.swift` — `Prefs.appearance`, `canAct`, the `offline` and `error` fixtures. Its behaviour, the intents and the snapshot are unchanged.
