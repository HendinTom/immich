# Gallery Review mobile checks

This PR preserves the existing integrated Review prototype and establishes its
repeatable Android check/build entrypoint. It does not implement the planned
multi-device rules, Trash review, reset, or additional settings.

Use Flutter 3.47.2, Java 21, Android SDK/NDK versions from the upstream project,
and OpenAPI Generator 7.25.0. Put `flutter`, `dart`, and `openapi-generator-cli`
on PATH; set JAVA_HOME and ANDROID_HOME for your workstation. No absolute user
paths or credentials belong in this repository.

From a fresh checkout:

```sh
bash scripts/gallery-review/mobile-check.sh --bootstrap --build
```

For an existing generated checkout:

```sh
bash scripts/gallery-review/mobile-check.sh --build
```

`--bootstrap` regenerates the SDK, routes/models, database helpers, native bridge,
and translations using upstream tools. It does not run the aggressive clean task.
The script checks formatting and analysis for the custom feature, then runs its
journal/gesture tests plus relevant upstream native sync/repository tests. This
is a targeted check, not a claim that the whole mobile test suite was run.

The APK and SHA-256/commit manifest are written to ignored `.gallery-review/mobile/`.
The APK is ARM64 and debug-signed, using the separate upstream debug package.
It is for evaluation, not a production-signed release. A stable private signing
key and distribution policy must be agreed before ongoing phone releases.

## Backend for manual integration checks

Use the server PR's isolated Compose lab (`http://127.0.0.1:22840`). In the Android
emulator, connect to `http://10.0.2.2:22840`. The lab creates its own synthetic
non-admin users; read their credentials only from its private local state file.
Do not use the homelab account or a personal library for local destructive tests.

Install alongside the standard app:

```sh
adb install -r .gallery-review/mobile/COMMIT/gallery-review-debug.apk
```

Verify Keep, Trash, Undo, canceled swipe, persistence after restart, and photo/
video rendering. API smoke tests do not prove device Trash restoration. Physical
phone permissions and background behavior remain manual acceptance checks.

## Review and release

Open mobile changes against `gallery-main` in your fork. GitHub checks do not
have homelab credentials and never install an app on a phone or deploy a server.
Merge only after review. Build a fresh artifact from the merged revision; confirm
its manifest says `dirty: false`. Server rollout is independently gated by the
server PR's explicit deployment command. Neither PR auto-merges the other.
