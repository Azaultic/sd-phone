# Higher-resolution map (deep zoom)

This explains how to make the Maps / Find Friends / shared-location map zoom in
**much further and stay crisp**.

## Why this is needed

The map is a **tile pyramid**: a separate set of images per zoom level. The
default community pack (`meesvrh`) only ships zoom levels **0–5** (~1.5 m/px).
Past z5 the app just **upscales** the z5 tiles, which looks blurry. Leaflet or
any other library can't change this — the only way to get sharper deep zoom is a
pack that actually **has** deeper levels (z6, z7, z8).

The renderer now already lets you **zoom in far further** (it upscales the
deepest level you have). To make that deep zoom *sharp*, give it deeper tiles.

## The one rule: keep the same projection

Every pin, the live "you are here" dot, friend dots, route lines and the shared-
location preview are placed with one linear projection (`WORLD` bounds in
`data.ts`, derived from the standard community map CRS). So your deep pack **must
use that same community projection** — then everything lines up with **no
recalibration**. (Packs built on a Google/Mercator projection — e.g.
`gta5-map.github.io` — will NOT line up. Don't use those.)

A community-projection **satellite** pack with levels **z0–8** exists. There is
currently **no** deeper community **atlas** pack, so atlas stays z5 (it still
zooms further, just softer). Satellite is where the big win is.

## Get the tiles (either method needs these)

1. **Download a z0–8 community-projection satellite pack.** A known one ships
   with `RiceaRaul/gta-v-map-leaflet` (download link in that repo's README — the
   `styleSatelite` folder is the z0–8 satellite set). Any pack whose tiles line
   up with the current z0–5 map works. **z0–7 is the sweet spot** — far smaller
   than z8 and still razor sharp.

2. **Lay it out as `satellite/<z>/<x>/<y>.jpg`.** The app builds tile URLs as
   `<base>/satellite/<z>/<x>/<y>.jpg`, so if your pack's folder is called
   `styleSatelite`, rename it to `satellite`.

## Method A — Bundle in the resource (NO GitHub, recommended)

Fully self-contained: the phone serves the tiles itself, offline, no external
host. The only cost is resource size (clients download it once on join; ~100–300
MB for z0–7).

1. Put the folder at **`sd-phone/maptiles/satellite/<z>/<x>/<y>.jpg`** (resource
   root, NOT `web/build` — Vite wipes that). The `maptiles/**` entry is already
   in `fxmanifest.lua`. The NUI loads it via a **relative** path (`../../maptiles`
   from `web/build/index.html` = resource root) — an absolute `nui://...` URL does
   NOT resolve here.

2. In `web/src/components/apps/maps/data.ts`, set:
   ```ts
   satellite: { base: '../../maptiles', ext: 'jpg', maxZoom: 7 },
   ```

3. Rebuild + restart (below). Done — crisp deep satellite, no hosting.

   *(Note: `nui://` tiles only resolve in-game, not in the dev browser. That's
   fine — they show in FiveM; dev falls back to the bundled base image.)*

## Method B — Host on GitHub → jsDelivr

Smaller resource, but depends on jsDelivr/GitHub.

1. Put the folder under `tiles/` and push `tiles/satellite/...` to a public repo
   (e.g. `YOURNAME/sd-map-tiles`). jsDelivr serves it:
   `https://cdn.jsdelivr.net/gh/YOURNAME/sd-map-tiles@main/tiles/satellite/7/0/0.jpg`
2. In `data.ts`:
   ```ts
   satellite: { base: 'https://cdn.jsdelivr.net/gh/YOURNAME/sd-map-tiles@main/tiles', ext: 'jpg', maxZoom: 7 },
   ```

## Rebuild (required for either method)

The UI is a compiled bundle, so changes to `data.ts` need a build:
```
cd web
npm run build
```
Restart `sd-phone` (or refresh) and zoom in — satellite is now crisp deep, and
the zoom cap auto-raises to match the new depth.

## Verifying alignment

Open Maps, zoom in on a landmark, and check the blue "you are here" dot sits on
the right spot. If a same-projection pack looks even slightly shifted, the
in-game **`/mapcal`** command (already in `client/apps/maps.lua`) walks you
through re-deriving the `WORLD` bounds. With a correct community-projection pack
you shouldn't need it.

## Atlas

If a deeper community-projection **atlas** pack ever appears, do the same thing
for `TILE_SOURCES.atlas` (`ext` may be `png`). Until then, leave atlas at
`maxZoom: 5`.
