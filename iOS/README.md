# Chronato for iPhone

The iOS app: same Kimai account model as the Mac app (server URL + API token in
the Keychain), start / pause / resume / stop, recent entries, today/week totals.
It links `ChronatoCore` from the repository root as a local Swift package.

## Layout

| Folder | Target membership | What |
|---|---|---|
| `App/` | Chronato | SwiftUI app: onboarding, Track, Reports, Settings tabs. App icon. |
| `Shared/` | Chronato + ChronatoWidgets | `PhoneTracker` (the engine), `AppGroup` + `SharedSnapshot`, App Intents, Live Activity attributes and views, widget views, brand colours, `PrivacyInfo.xcprivacy`, AccentColor. |
| `Widgets/` | ChronatoWidgets | Widget extension: the status widget and the Live Activity configurations. |
| `Config/` | none (build settings point here) | Info.plist additions and entitlements for both targets. |

The folders are Xcode 16 *synchronized folders*: a file you add to one of them
belongs to its targets without editing `project.pbxproj`.

## Identifiers

- App `com.weidhaus.chronato`, widget extension `com.weidhaus.chronato.widgets`, team `5SB3S8ESR3`, automatic signing.
- App Group `group.com.weidhaus.chronato`: `snapshot.json` (what widgets and intents read) and the paused session.
- Keychain access group `$(AppIdentifierPrefix)com.weidhaus.chronato.shared`, named in Info.plist as `ChronatoKeychainGroup`. `Credentials` (ChronatoCore) uses it on iOS and falls back to the app's own group when a build lacks the entitlement.

## Build and run in the simulator

From the repository root:

```sh
xcodebuild -project iOS/Chronato.xcodeproj -scheme Chronato \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Simulator builds sign to run locally and need no provisioning profile; the
entitlements (App Group, keychain group) are embedded as simulated entitlements.

Launch with fixture data instead of a Kimai server:

```sh
xcrun simctl boot "iPhone 17"
xcrun simctl install "iPhone 17" <DerivedData>/Build/Products/Debug-iphonesimulator/Chronato.app
xcrun simctl launch "iPhone 17" com.weidhaus.chronato -ChronatoFixture running   # idle | running | paused | unconfigured
xcrun simctl io "iPhone 17" screenshot chronato.png
```

In Xcode, the shared scheme has `-ChronatoFixture running` under Run →
Arguments, switched off. Fixture mode makes no network calls and leaves the
Keychain alone; it still writes the snapshot, so widgets show the same data.

More launch arguments for screenshots: `-ChronatoTab reports` (or `settings`)
opens that tab, `-reportPeriod month` (`day|week|month|year`) and
`-reportScope all` (`me|ai|all`) set the Reports tab's remembered choice.

To check that `ChronatoCore` alone builds for iOS:

```sh
xcodebuild -scheme ChronatoCore -destination 'generic/platform=iOS Simulator' build
```

## Widgets, Live Activity, Shortcuts

- **Status widget** (Home Screen small and medium, Lock Screen rectangular and
  inline): running → names, ticking time, Pause and Stop; paused → Resume;
  idle → today's time and "Start <most recent>". It reads the App Group
  snapshot; `SnapshotSync` reloads timelines (debounced) after every change.
- **Live Activity** (Lock Screen and Dynamic Island) while a timer runs or is
  paused, with Pause/Resume and Stop. `LiveActivitySync` starts, updates and
  ends it from the snapshot, also when a refresh finds a timer started in the
  browser or on the Mac.
- **App Intents** (`Shared/Intents.swift`): Start (a Kimai activity in a
  project, optional note), Stop, Pause, Resume, Current Timer, with Siri
  phrases. They act on `PhoneTracker.shared`, so every Kimai call stays in the
  engine. The ones that change the timer are `LiveActivityIntent`s: the widget
  and Live Activity buttons run them in the app's process.

The widget target compiles `Shared/` with `WIDGET_EXTENSION` set, which leaves
out the App Shortcuts and the Live Activity requests (app only).

To look at every widget family and the Live Activity views without adding
them to a Home Screen, a Debug build renders them to PNGs, light and dark:

```sh
xcrun simctl launch "iPhone 17" com.weidhaus.chronato -ChronatoFixture idle -ChronatoRenderWidgets YES
open "$(xcrun simctl get_app_container "iPhone 17" com.weidhaus.chronato data)/Documents/WidgetGallery"
```

## App icon

`swift scripts/make-icon.swift Branding` also writes `Branding/AppIcon-iOS-1024.png`
(full bleed, no alpha). Copy it to `iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.

## TestFlight

```sh
scripts/ios-release.sh --dry-run   # unsigned Release archive + App Store checks, no Apple account
ASC_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=<issuer uuid> \
  scripts/ios-release.sh           # archive, check, upload to App Store Connect
```

The script archives the `Chronato` scheme (Release, generic iOS device) into
`dist/ios/`, checks the archive (bundle ids, matching app and widget versions,
export-compliance key, icon, privacy manifests) and exports it with
`iOS/ExportOptions.plist` (`app-store-connect`, `destination` `upload`), which
uploads it. It signs in with an App Store Connect API key from the environment
only; `-allowProvisioningUpdates` lets automatic signing register the App IDs,
the App Group and the profiles for team 5SB3S8ESR3. The build number is a UTC
timestamp (or `BUILD_NUMBER`), so every upload is new; `MARKETING_VERSION` in
the project is the version testers see.

`ITSAppUsesNonExemptEncryption` is `NO` (HTTPS only), so App Store Connect asks
no export-compliance question per build.

Known limit: there is no push, so a timer stopped in the browser or on the Mac
while the app is not running keeps ticking in the widget and Live Activity
until the app next opens (or an intent runs).
