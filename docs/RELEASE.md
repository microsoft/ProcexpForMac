# Release & Notarization — Process Explorer for macOS

The scripts below provide local build and Developer ID validation.

## Quick start (once you have a Developer ID)

```bash
# 1. Build the Release app and optional local-test DMG.
PROCEXP_VERSION=1.0.0 PROCEXP_BUILD_VERSION=1.0.0 \
   PROCEXP_BUILD_FLAVOR=official PACKAGE_DMG=0 \
   bash Scripts/build_release.sh

# 2. Developer ID sign, notarize, and staple.
export DEVELOPER_ID_APP='Developer ID Application: Jane Doe (AB12CD34EF)'
export KEYCHAIN_PROFILE='procexp-notary'
bash Scripts/sign_notarize.sh
```

`sign_notarize.sh` signs and notarizes the helper and app first, packages that
exact stapled app as `ProcExp.app`, then signs, notarizes, and staples
`build/ProcExp.dmg`. Use the governed pipeline artifact for an official release.

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

The Hardened Runtime is required for notarization. The Release configuration in
`project.yml` enables it, and `sign_notarize.sh` also applies
`codesign --options runtime` when replacing transport signatures with Developer
ID signatures. Debug builds keep it disabled for local development.

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

Local builds use the isolated app ID `com.sysinternals.procexpmac.dev` and
helper ID `com.sysinternals.procexpmac.dev.helper`. `embed_helper.sh` derives
their launchd plist from the canonical production plist, replacing the label,
program, Mach service, and associated app ID as one validated tuple. Official
builds retain the identifiers above.

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
4. Apply inside-out ad-hoc transport signatures to the completed local bundle.
5. When `PACKAGE_DMG` is not `0`, stage the app with an `/Applications` symlink
   and create a local-test DMG.

Set `PACKAGE_DMG=0` to produce only the app.

The default development flavor produces `ProcExp (Dev).app` and
`build/ProcExp-Dev.dmg`, using the `.dev` app and helper identifiers. Set
`PROCEXP_BUILD_FLAVOR=official` only when preparing input for Developer ID
signing. The official Azure builder sets that flavor with `PACKAGE_DMG=0`; the
shared signing template creates the distribution DMG only after notarization.

### `Scripts/sign_notarize.sh`

Guarded on `DEVELOPER_ID_APP`, `KEYCHAIN_PROFILE`, and the canonical app/helper
identity tuple. Then:

1. `codesign` the embedded helper (if present) with the debugger entitlement +
   Hardened Runtime.
2. Sign the app without `--deep`, preserving the helper's distinct signature
   and entitlement, then verify the nested bundle.
3. Submit a zip of the signed app to `notarytool`, then staple and validate the
   app.
4. Create `build/ProcExp.dmg` from that exact app as `ProcExp.app` plus the
   `/Applications` symlink.
5. Sign, notarize, staple, and validate the DMG.

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
spctl --assess --type open --context context:primary-signature -v build/ProcExp.dmg

# Signature + notarization of the app inside.
codesign --verify --deep --strict --verbose=2 /Applications/ProcExp.app
xcrun stapler validate /Applications/ProcExp.app
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
