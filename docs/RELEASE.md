# Release & Notarization — Process Explorer for macOS

This document describes how to produce a distributable, notarized build of
Process Explorer, including the privileged helper. Two scripts drive the
process:

- `Scripts/build_release.sh` — builds `Release` and packages a DMG. Works today
  with ad-hoc signing; produces a locally-runnable (but *not* distributable)
  artifact.
- `Scripts/sign_notarize.sh` — Developer ID signs, notarizes, and staples that
  artifact. Requires a paid Apple Developer account.

## Quick start (once you have a Developer ID)

```bash
# 1. Build the Release app + DMG (ad-hoc signed).
bash Scripts/build_release.sh

# 2. Developer ID sign, notarize, and staple.
export DEVELOPER_ID_APP='Developer ID Application: Jane Doe (AB12CD34EF)'
export KEYCHAIN_PROFILE='procexp-notary'
bash Scripts/sign_notarize.sh
```

The result is `build/ProcexpMac.dmg`, notarized and stapled, ready to ship.

---

## Prerequisites

### 1. Apple Developer account + certificate

- A paid **Apple Developer Program** membership.
- A **Developer ID Application** certificate installed in your **login**
  keychain. Create it in *Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸
  + ▸ Developer ID Application*, or via the Developer portal.
- Confirm it is present and note the exact common name:

  ```bash
  security find-identity -v -p codesigning
  # => "Developer ID Application: Jane Doe (AB12CD34EF)"
  ```

  Use that full string (including the Team ID in parentheses) as
  `DEVELOPER_ID_APP`.

### 2. notarytool credentials

Store an app-specific password once so the scripts can submit non-interactively.

1. Create an **app-specific password** at <https://account.apple.com> ▸
   *Sign-In and Security ▸ App-Specific Passwords*.
2. Store it as a notarytool keychain profile:

   ```bash
   xcrun notarytool store-credentials procexp-notary \
       --apple-id you@example.com \
       --team-id AB12CD34EF \
       --password xxxx-xxxx-xxxx-xxxx
   ```

3. Export the profile name for the script:

   ```bash
   export KEYCHAIN_PROFILE='procexp-notary'
   ```

### 3. Hardened Runtime

The Hardened Runtime is required for notarization. `sign_notarize.sh` applies it
at signing time via `codesign --options runtime`, so it does not need to be
baked into every dev build. If you prefer it enabled in the project directly,
set `ENABLE_HARDENED_RUNTIME: YES` in `project.yml` (it is `NO` today so that
ad-hoc local builds and previews stay friction-free).

---

## Embedding the privileged helper

The app ships with an optional root helper (`com.sysinternals.procexpmac.helper`)
that provides cross-user thread sampling and privileged actions over XPC. It is
**not embedded by the default Xcode target** because embedding + registering an
`SMAppService` daemon only works under Developer ID signing. Full design and
build-phase steps live in [../Helper/README.md](../Helper/README.md); the
release-relevant summary:

1. Build the helper executable from the SPM `ProcexpHelper` product (its product
   name must be exactly `com.sysinternals.procexpmac.helper`).
2. Copy it and `Helper/com.sysinternals.procexpmac.helper.plist` into the app at
   `Contents/Library/LaunchDaemons/` (a *Copy Files* build phase with
   destination **Wrapper**).
3. `sign_notarize.sh` signs the helper **first** (inside-out order) with
   `Helper/ProcexpHelper.entitlements` (the `com.apple.security.cs.debugger`
   entitlement that permits `task_for_pid` under the Hardened Runtime), then
   signs the app with `Helper/ProcexpMac.entitlements` (the
   `com.apple.developer.service-management.managed-by-launchd` entitlement).
4. Keep the pinning keys described in `Helper/README.md` aligned with the
   official signing identity. `AssociatedBundleIdentifiers` and the Release
   `SecRequirement` are enabled so the daemon only accepts the signed app.

The release scripts and ADO verification fail if the helper is absent. A
privileged-helper release must never silently degrade to an app-only package.

### SMAppService requires a signed build

`SMAppService.register()` (the app's *Install Privileged Helper…* menu item)
**fails under ad-hoc signing** and only succeeds once the app is Developer ID
signed and (ideally) notarized. After installing, the user approves the daemon
in *System Settings ▸ General ▸ Login Items & Extensions*, after which
`PrivilegedDataProvider.isHelperInstalled()` returns `true` and the app adopts
the privileged provider.

---

## What each script does

### `Scripts/build_release.sh`

1. `xcodegen generate` — regenerate `ProcexpMac.xcodeproj` from `project.yml`.
2. Ensure the app-icon assets exist (runs `Scripts/make_icon.sh` if missing).
3. Build a Universal `arm64` + `x86_64` Release app and helper.
4. Stage `ProcexpMac.app` + an `/Applications` symlink and `hdiutil create` a
   compressed (`UDZO`) DMG at `build/ProcexpMac.dmg` for drag-install.

Set `PACKAGE_DMG=0` to produce only the app.

Works today with ad-hoc signing; the produced DMG runs locally but Gatekeeper
will warn on other machines until it is notarized.

### `Scripts/sign_notarize.sh`

Guarded on `DEVELOPER_ID_APP` and `KEYCHAIN_PROFILE`. Then:

1. `codesign` the embedded helper (if present) with the debugger entitlement +
   Hardened Runtime.
2. `codesign --deep` the app with the managed-by-launchd entitlement + Hardened
   Runtime; verify with `codesign --verify` and `spctl`.
3. `codesign` the DMG.
4. `xcrun notarytool submit --wait` the DMG, then `xcrun stapler staple` the DMG
   (and app).

---

## Icon

`Scripts/make_icon.sh` draws a 1024×1024 base PNG with AppKit/CoreGraphics
(a dark navy rounded tile with a green CPU bar-graph + activity-pulse motif),
downsamples it with `sips` into every asset-catalog size
(`App/Assets.xcassets/AppIcon.appiconset/`), writes the `Contents.json`, and
emits a standalone `build/AppIcon.icns`. Regenerate any time with:

```bash
bash Scripts/make_icon.sh
```

The asset catalog is wired via `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in
`project.yml`, so `xcodebuild` compiles it into `Assets.car`
(and `Contents/Resources/AppIcon.icns`) automatically.

---

## Verifying a shipped build

On a clean machine (or after removing the quarantine bit locally):

```bash
# Gatekeeper assessment of the DMG.
spctl --assess --type open --context context:primary-signature -v build/ProcexpMac.dmg

# Signature + notarization of the app inside.
codesign --verify --deep --strict --verbose=2 /Applications/ProcexpMac.app
xcrun stapler validate /Applications/ProcexpMac.app
```

All three should report success once notarization + stapling have completed.

---

## Environment / credentials the user must supply to ship

| Item | How to obtain | Used by |
|---|---|---|
| Developer ID Application certificate | Apple Developer Program → Xcode/portal | `DEVELOPER_ID_APP` |
| `DEVELOPER_ID_APP` env var | full cert common name incl. Team ID | `sign_notarize.sh` |
| App-specific password | account.apple.com | `notarytool store-credentials` |
| notarytool profile | `xcrun notarytool store-credentials …` | `KEYCHAIN_PROFILE` |
| `KEYCHAIN_PROFILE` env var | the profile name you chose | `sign_notarize.sh` |
