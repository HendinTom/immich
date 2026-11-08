# Gallery Review device policy (protocol 1)

This additive server extension preserves the stock Immich endpoints and response schemas. The modified Android app discovers `/api/gallery-review/capabilities`. All extension endpoints require authentication; policy endpoints additionally require a user session, not an API key or shared link.

## User-visible rules

- Normal review chooses server and/or registered phones. Server is optional. No destination means no destructive action.
- The current phone is selectable when “Delete from this phone” is on (default on), Android media-management permission is granted, and read-only mode is off. Another phone additionally requires its own “Sync remote deletions” setting. Unsupported/signed-out devices remain visible but disabled. Unmodified apps are not registered.
- An offline eligible phone can be selected for normal review. Its command remains pending until the app connects and confirms the OS action. Delivery is not a guarantee that a phone is immediately reachable.
- Server-only trash retains unselected phone copies, including after server purge. Account/checksum upload exclusions survive asset deletion. Restoring the server copy clears the exclusion. Resetting review progress does not clear exclusions.
- Device-only trash leaves the server asset active. The modified app does not infer restoration from the continued existence of that server asset.
- Trash review currently sources/restores only server Trash. Device source/destination controls are disabled with an explanation. Nothing advances review without mutation; Restore affects the server only.
- Stock app behavior is unchanged. Stock server mutations enqueue work only for registered modified devices that opted in. Unregistered upload sessions retain stock upload behavior.

## API

All paths below are relative to `/api/gallery-review`. POST bodies reject unknown fields.

| Method / path | Body / result |
| --- | --- |
| GET capabilities | `protocol: 1`, `deviceIdentity: 1`, `trashSources: ["server"]` |
| POST device | `name`, `platform`, `localEnabled`, `remoteEnabled`, `canManage`, optional paired `identityKey`/`installationId`, optional `replaceDeviceId`; returns server-assigned `deviceId` and `reinstalled` |
| GET devices | Only the authenticated account's devices, including availability and disabled reason |
| GET commands | Up to 250 eligible pending checksum commands with revision, action and origin (`local`) |
| POST commands/ack | `revision`, `status` (`applied`, `missing`, `blocked`); stale acknowledgements cannot consume newer commands |
| POST exclusions | Up to 1000 SHA-1 base64 `checksums`; returns `blocked` checksums |
| POST decisions | UUID `operationId`, owned `assetId`, `action` (`trash`/`restore`), `server`, device UUID array `devices` |
| GET decisions/:id | `undone` and destination delivery states; superseded work is explicitly reported |
| POST decisions/:id/undo | Account-owned idempotent Undo; also cancels an uncertain request that never reached the server |

Android identity is scoped to the authenticated account, Android user/device, signing key and package. A separate app-private installation UUID survives updates and sign-out, but not uninstall or clear-data. The server advertises `deviceIdentity: 1`; older clients remain supported. The current session's legacy entry is adopted in place on update. A returning identity reconnects its existing entry, and superseded sessions cannot reclaim it. Reauthentication in the same installation preserves queued work and local-action semantics even after session revocation.

A different installation UUID retires prior delivery records and cancels pending phone work; later Undo cannot revive those records. New explicitly requested work is allowed. Server media and account upload exclusions are unchanged. Local native receipts and review/Undo history do not survive uninstall. Old modified sessions retain upload exclusions; stock upload sessions retain stock behavior.

Historical entries without stable identity are never merged by name. An explicit, confirmed `replaceDeviceId` can retire only another same-account legacy entry, cancelling its pending delivery and hiding it from destinations. No photos are mutated. Normal app updates preserve settings and journals. Factory reset, Android profile changes and signing-key/package changes may require explicit reconciliation; the official app remains a separate client whose backup/deletion settings can affect shared phone media. Devices are not discoverable/manageable across accounts. The server rechecks destination settings when accepting a decision; the phone checks its current setting again before native mutation. Opt-out cancels queued commands rather than replaying them after a later opt-in.

## Persistence and ordering

The migration adds the `gallery_review` schema, plus an asset trigger. No upstream API schema changes are needed. The trigger captures stock trash/restore/purge events, preserves exclusions for Live Photo motion files, and does not broaden a prior selective decision during background purge. Custom decisions suppress broadcast within their transaction and enqueue only selected destinations.

Account-scoped transaction locks serialize review decisions and Undo. A client operation UUID makes retries idempotent. Recovery is account-owned so signing in again can resolve a pending server decision after the old session is revoked; device authorization remains bound to the current authenticated session, independently of persistent phone identity. Each device/checksum has a revision so late acknowledgements cannot acknowledge a newer action. Undo refuses to overwrite subsequent server trash-state changes or newer review decisions. Metadata-only changes do not invalidate Undo. Permanently removed server media cannot be restored; Undo reports a conflict in that case.

Modified uploads check exclusions both before and after insert, protecting against concurrent purge/uniqueness races. The phone also filters backup candidates. Upload exclusions are user-owned and deleted when that account is removed.

On Android, account-scoped local receipts are written before OS changes. Restore only touches IDs recorded by this worker. Native Trash snapshots recover interrupted acknowledgements. A missing copy is reported as missing rather than success. Background operation depends on Android permissions/activity availability; pending work retries on the next sync or review action.

## Testing and release

Run `python3 scripts/gallery-review/policy_checks.py` on the local Docker engine. It builds the current server test stage, creates a private disposable network/database, applies real migrations, runs the policy suite, and removes its containers. There are no host database ports or production volumes. `release.py` includes the same suite in its release gate; PR CI also runs it.

The mobile feature PR must be tested with this server PR before deployment. The mobile app retains its basic legacy reviewer on a stock server; selective device controls and Trash review require this extension. A previously managed server becoming unsupported fails closed instead of silently reverting to broad remote deletion syncing.

Before production deployment, review both PRs, back up the database, and complete the real-phone acceptance checks. Rolling back to stock server code is not a safe way to retain selective-delete semantics for modified clients. Do not drop the extension schema or its exclusions during an upstream rebase; review generated migrations for unintended removal. Migration `down` is intended for disposable testing or a deliberate full rollback with a matching database backup.
