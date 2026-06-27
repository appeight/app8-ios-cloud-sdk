# App8 Offline Bundle Format (`.a8pack`)

A self-contained, on-device copy of one **published** flow or screen. Produced by the App8
canvas/Mac app (backend-assembled), consumed by **App8Cloud** to render with no network and to
warm the cache for a fast, network-resilient first paint.

This is the shared contract for three repos:
- **Backend** (`app8-web`) builds the envelope from the published `/sdk/v1` gated content.
- **Mac app** (`App8CanvasMac`) downloads + packs it.
- **Cloud SDK** (`app8-ios-cloud-sdk`) imports it into its disk cache.

## Layout

`.a8pack` is a **directory** (a macOS package; a single item in Finder). Transport as a zip if you
like, but the SDK import API takes the unpacked directory.

```
MyFlow.a8pack/
  manifest.json          # envelope — small, scannable
  assets/
    logo.png
    Inter-Bold.ttf
    intro.mp4
```

## `manifest.json` (envelope)

```jsonc
{
  "type": "app8.offline.flow",      // or "app8.offline.screen"
  "name": "Onboarding",
  "version": "v3",                   // published version label (null = latest)
  "dslVersion": "1.0",               // = max(min_dsl_version) across members
  "bundleFormat": 1,                 // THIS container schema (independent of dslVersion)
  "appId": "5f…",
  "key": "onboarding",               // flow_key or screen_key
  "createdAt": "2026-06-27T10:00:00Z",
  "content": "<base64( payload-json bytes )>",
  "assets": [
    { "id": "a1", "name": "logo", "filename": "logo.png", "kind": "image",
      "mimeType": "image/png", "sizeBytes": 45000, "sha256": "…", "path": "assets/logo.png" },
    { "id": "f1", "name": "Inter", "filename": "Inter-Bold.ttf", "kind": "font",
      "postScriptName": "Inter-Bold", "sha256": "…", "path": "assets/Inter-Bold.ttf" }
  ]
}
```

- `content` is base64 of the payload JSON below — keeps the DSL byte-preserved (stable hashes,
  numeric precision) and the envelope cheap to scan.
- `assets[]` lists **only** the binaries the bundled flow/screen actually references (scoped, not the
  whole app). `kind ∈ {image, font, video, other}`. `path` is relative to the bundle root and must not
  escape it (no `..`, no absolute paths). `sha256` is verified on import. Fonts carry `postScriptName`.

## Decoded `content` payload

Optional fields; presence depends on `type`. Shaped to fill the SDK cache 1:1.

```jsonc
{
  // App-wide (both types):
  "localizations": { "defaultLocale": "en", "locales": { "en": { "k": "v" } } },
  "datasources": { "category/name": { /* mock */ } },
  "resourceMeta": {                  // server freshness, so reconnect refreshes only what changed
    "manifest": { "updatedAt": "…", "contentHash": "…" },
    "styles":   { "updatedAt": "…", "contentHash": "…" }
  },

  // type == "app8.offline.screen":
  "app": { /* app manifest: title, navigation, transitions */ },
  "styles": [ { /* style */ } ],
  "components": [ { "id": "card", /* … */ } ],
  "screens": {
    "<screenKey>": { "version": "v3", "updatedAt": "…", "contentHash": "…", "data": { /* screen DSL */ } }
  },

  // type == "app8.offline.flow":
  "flow": {
    "manifest": { "servedVersion": "v3", "startScreen": "intro",
                  "screens": [ { "screenKey": "intro" } ], "transitions": [ /* … */ ] },
    "styles": [ { /* flow-pinned style */ } ],
    "components": [ { "id": "card" } ],
    "screens": { "<screenKey>": { /* member screen DSL — RAW, see note */ } }
  }
}
```

> **Screen-entry shape differs by type, intentionally.** A screen bundle wraps each entry as
> `{ version, data }` (it pins a screen version + freshness meta). A flow member is the **raw** screen
> DSL — members have no individual version (they're pinned to the flow version), so there's nothing to
> wrap. The two live at different keys (`payload.screens` vs `payload.flow.screens`) and the importer
> branches on `type`, so a consumer never needs to handle both shapes at one key.

## How the SDK imports it

`importOfflineBundle(at:)` writes into the **existing** App8Cloud disk cache (`DiskCache` /
`AssetCache` / `FontRegistry`) — no parallel data source:

| Payload | Destination |
|---|---|
| `app` | `writeManifest` + `updateAppResourceMeta("manifest")` + `touchMeta(dslVersion:)` |
| `styles` | `writeStyles` + `updateAppResourceMeta("styles")` |
| `components` | `writeComponents` (keyed by top-level `id`) |
| `screens[k]` | `writeScreen(k, version)` **and** `writeScreen(k, _latest)` + `writeScreenMeta` |
| `flow.manifest` | `writeFlowManifest(version)` + `_latest` |
| `flow.styles` / `flow.components` | `writeFlowStyles/Components(version)` + `_latest` |
| `flow.screens[k]` | `writeFlowScreen(k, version)` + `_latest` |
| `datasources[c/n]` | `writeDatasource(c, n)` |
| `localizations` | `writeLocalizations` + meta |
| `assets[]` | `AssetCache.write` under id, filename, basename, name; fonts also `FontRegistry.register` |

Because every SDK read is cache-first, the unchanged read path then renders offline; when online, the
existing freshness check (`updatedAt`/`contentHash` from `resourceMeta`) refreshes only what changed.

## Backend response vs. on-disk manifest

The backend endpoints
(`GET /api/v1/apps/{appId}/offline-bundle/{flow|screen}/{key}?version=`) return a **transport**
envelope: identical to `manifest.json` except each `assets[]` entry carries a signed `downloadUrl` +
`expiresAt` instead of `sha256` + `path`. The Mac client downloads each `downloadUrl`, computes the
`sha256`, writes the bytes to `assets/<filename>`, sets `path`, and drops `downloadUrl`/`expiresAt` —
producing the final on-disk `manifest.json` above. `content` is passed through verbatim.

## Versioning

- `bundleFormat` gates the container; importers reject unknown majors.
- `dslVersion` is compared against the SDK's `maxSupportedDslVersion`; a newer bundle is rejected with
  `dslVersionUnsupported` (mirrors the online 412).
