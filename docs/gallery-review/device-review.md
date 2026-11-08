# Device-aware Gallery Review

Normal sessions start with a destination picker: server, this phone, and other registered phones on this account. The server can be unchecked for phone-only trash. Disabled devices explain whether permission, settings or sign-out prevent use. Offline eligible phones queue work for the next connection.

Advanced settings contain two independent controls, without a per-device dropdown:

- **Delete from this phone** (default on): permits local removal initiated by this app.
- **Sync remote deletions**: permits server/other-device actions to affect this phone.

The reviewer does not override a destination's setting. Android 12+ with media-management access is required for device operations in this release; other platforms remain disabled destinations. Stock clients are not registered and keep their stock behavior.

Selecting **Trash (server only)** changes the gestures/buttons to grey **Nothing** and green **Restore**. All phone controls are disabled with an explanation: device Trash sourcing/restoration is not part of this release. Only the media tilts/moves; the controls and edge glow stay fixed.

**Reset review progress** requires confirmation. It clears normal and Trash review history and Undo for this account/server on this installation. It never restores/deletes media, changes settings, or clears upload exclusions. A pending uncertain action must be retried or undone first.

The review journal saves the operation ID and selected destinations before making a request. Retries preserve those choices even after restart. Undo is idempotent. The server rejects Undo if a newer decision or incompatible server state superseded it; permanently deleted originals cannot be restored.

A separate SQLite transaction prevents foreground/background workers from changing receipts concurrently, and releases its lock if a worker exits. The device worker journals local IDs before native trash, checks OS Trash on retry, and restores only recorded IDs. Managed sync no longer interprets all server deletions as instructions to delete local copies, or all active server copies as instructions to restore local Trash. Server-only deletions persist as account/checksum upload exclusions, including after purge.

## Acceptance checks

Automated checks: `bash scripts/gallery-review/mobile-check.sh --build`. The tests cover review reset/recovery, source isolation, gesture behavior, interrupted device delivery, opt-out handling, and native sync regressions.

Use synthetic photos on an Android phone before production:

1. Server-only trash: phone copy remains, including after backup/sync and server purge; it is not re-uploaded.
2. Phone-only trash: server copy remains active; sync does not restore the phone copy. Undo restores only the worker's recorded local IDs.
3. Both destinations: verify each copy separately and check pending/applied/missing status.
4. Turn remote sync off on a second phone: it appears disabled. Queue while offline, then opt out before reconnecting: queued deletion must not execute.
5. Server Trash: Nothing changes no media; Restore changes only the server; phone controls stay disabled.
6. Reset: cancel preserves progress; confirm makes previously reviewed photos eligible again without changing media.
7. Interrupt/restart around a decision, native Trash and acknowledgement; retry and Undo must not change an unselected device.
8. Sign out/switch users: devices, operations and journals remain account-scoped.

A simulator/emulator cannot establish manufacturer-specific permission and background behavior. Real-phone acceptance remains a release gate, alongside review of the separate server PR.
# Android test distribution

Use `bash scripts/gallery-review/mobile-check.sh --test-release` for phone testing.
This builds optimized Flutter release code with the visible name **Immich**, while
retaining `app.alextran.immich.debug` and the local test signing key so it updates
the existing test installation without removing its data. It does not replace
the official Immich app. Keep the signing key private and use the same build
machine/key for published updates; CI's temporary key cannot update an APK
signed on another machine. `--build` remains available for debugger builds.
