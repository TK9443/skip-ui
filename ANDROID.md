# Fork notes — a general activity-result launcher

Forked from `skiptools/skip-ui` at `ef7bbdd` (1.59.1) for HorseDex (`TK9443/horsedex`), on branch
`android-activity-result`. Everything is in
`Sources/SkipUI/SkipUI/UIKit/UIApplication.swift` plus one Gradle dependency in
`Sources/SkipUI/Skip/skip.yml`.

## Why

`UIApplication.launch(_:)` registered exactly one `ActivityResultLauncher`, for permission requests.
Android requires `registerForActivityResult` on or before `Activity.onCreate`, and app code in native
`SKIP_BRIDGE` mode never runs that early, so an app could not add a second launcher. That blocked
photo attachments, Storage Access Framework export and the biometric lock — every flow that needs a
result back from another activity.

## What changed

`launch(_:)` now registers a second launcher alongside the permission one, for
`ActivityResultContracts.StartActivityForResult`. That single contract subsumes all the others: every
`ActivityResultContract` is an intent in and a result code plus intent out, so one launcher covers
document picking, document creation, photo picking and device-credential confirmation alike. A
registry of arbitrary contracts would not help — app code still cannot register before `onCreate`.

`startActivityForResult(_:)` is the Kotlin-facing entry point. On top of it sit bridged APIs that
native Swift can call, all in `String`/`Data`/`Bool` because Foundation value types are not safe
across the Skip bridge:

| API | What it does |
|---|---|
| `pickMediaURI(_:)` | system photo picker, or `ACTION_OPEN_DOCUMENT` below API 33 |
| `createDocumentURI(_:mimeType:)` | ask where to write a new file |
| `openDocumentURI(_:)` | ask for an existing file |
| `openDocumentTreeURI()` | ask for a folder, taking persistable read and write access |
| `documentTreeRootURI(_:)` | a chosen folder's own document URI |
| `createChildDocument(_:name:mimeType:)` | a file, or with `documentFolderMIMEType` a folder |
| `childDocumentNames(_:)` / `childDocumentURI(_:name:)` | what is inside a folder |
| `readContentURI(_:)` / `writeContentURI(_:data:)` | bytes in and out of a content URI |
| `contentURIName(_:)` / `contentURIType(_:)` | display name and MIME type |
| `openContentURI(_:mimeType:)` | hand a document to whatever can display it |
| `canAuthenticateDeviceOwner()` / `authenticateDeviceOwner(title:subtitle:)` | `BiometricPrompt` |

The biometric pair needs `androidx.biometric:biometric:1.1.0`, added to the version catalog and
dependencies in `Sources/SkipUI/Skip/skip.yml`. It is the one new dependency.

## Traps hit while writing it

- **`arrayOf(...)` produces `skip.lib.Array`, not `kotlin.Array`**, so it cannot be passed as a
  `ContentResolver.query` projection. Query with a `nil` projection and read columns back by name
  with `getColumnIndexOrThrow`.
- **A tree URI and a document URI are not interchangeable.** `buildChildDocumentsUriUsingTree` needs
  `getTreeDocumentId` for the root and `getDocumentId` for anything below it, which is why every
  child call here takes a document URI and `documentTreeRootURI` exists to get the first one.
- **`openOutputStream` needs mode `"wt"`.** Plain `"w"` does not truncate, so a shorter write leaves
  the tail of the previous contents behind.
- **`BiometricPrompt.AuthenticationCallback.onAuthenticationFailed` must not resume the caller** — it
  fires per rejected fingerprint while the prompt is still up.

## Upgrading

Branch the fork from the new upstream tag and reapply these two files.
