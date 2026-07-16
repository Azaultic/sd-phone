# sd-phone

iOS-themed in-game phone for FiveM. **v0.1 scaffold** — ships the
lockscreen and homescreen only, with every app icon wired to a Lua
callback that's currently a no-op. App surfaces (Phone, Messages,
Safari, …) are deferred to v0.2.

The phone is built around a real iPhone bezel image
(`iphone_regular.png`) rendered as an opaque overlay; the React app
paints inside the screen cutout. Status bar, lockscreen, and
homescreen are all hand-rolled — no off-the-shelf phone library.

## Compatibility

| Layer        | Supported                                                                                  |
|--------------|--------------------------------------------------------------------------------------------|
| Frameworks   | QBCore, QBox, ESX                                                                          |
| Inventories  | ox_inventory, tgiann-inventory, qb-inventory, qs-inventory(-pro), origen_inventory, codem-inventory, jaksam_inventory, lj-inventory, ps-inventory |
| Notify       | ox_lib (default), lation_ui (opt-in), framework-native fallback                            |

Dependencies: `ox_lib`. Detection is automatic — no config flags
required.

## Installation

1. Drop `sd-phone` into `resources/[standalone]/`.
2. Add the phone items to your inventory's items table (the bundled
   `ox_inventory` ships `phone` + `phone_red`). Each must point its
   `server.export` at `sd-phone.use<ItemName>` and set `consume = 0`.
   Map item → frame colour in `Config.Phone.Items` (`configs/config.lua`).
3. Add `ensure sd-phone` and `ensure sd-phone-props` to `server.cfg`
   (the props pack streams the in-hand phone models).
4. (Optional) Rebuild the React app — see *Building the UI* below.

The pre-built bundle ships at `web/build/`, so a fresh clone runs
without `npm install`.

## How players use it

* Use a phone item from inventory — one per frame colour: `phone`
  (black), `phone_blue`, `phone_green`, `phone_orange`, `phone_pink`,
  `phone_purple`, `phone_red`, `phone_yellow`. The frame colour and the
  in-hand prop match the variant you used. **Or**
  press `F1` (rebindable via Settings → Key Bindings → FiveM), which
  opens only if you own a phone item (else "You don't have a phone.").
  There is no `/phone` chat command.
* The phone opens on the lockscreen. Swipe up (drag from the lower
  half of the screen) or press `Enter` to unlock.
* The homescreen shows the app grid + a four-slot dock. Tapping an app
  fires the `sd-phone:openApp` NUI callback — Lua logs it but takes no
  action in v0.1.
* `Esc` (or `F1` again) closes the phone.

## Configuration

All tunables live under `configs/config.lua`:

| Section           | Purpose                                                                                                  |
|-------------------|----------------------------------------------------------------------------------------------------------|
| `Phone`           | Inventory items → frame colours, default keybind, prop prefix, dead/swim blockers.                       |
| `Lockscreen`      | Wallpaper preset, 24h-clock toggle, date-row visibility.                                                 |
| `Homescreen`      | Wallpaper preset, dock contents, full app list (id / label / icon / route / accent colour).              |
| `StatusBar`       | Cosmetic carrier text, signal bars, Wi-Fi glyph, starting battery percentage.                            |

Wallpapers are CSS-gradient presets by default — drop a JPG into
`web/public/wallpapers/` and reference its filename from `Wallpaper`
to override.

## Architecture

```
sd-phone/
├── fxmanifest.lua
├── README.md
├── iphone_regular.png         iPhone bezel asset (consumed by web/)
├── bridge/                    Multi-framework / inventory / notify bridge
│   ├── shared/                  framework + inventory_id detection + locale loader
│   ├── client/                  notify, target, inventory shims
│   └── server/                  player, notify, inventory, money, job, gang, version
├── configs/
│   └── config.lua             Phone, Lockscreen, Homescreen, StatusBar tunables
├── locales/
│   └── en.json                UI/notification strings
├── client/
│   └── main.lua               Open/close state, keybind, NUI callbacks, battery tick
├── server/
│   └── main.lua               Usable phone-item registration + keybind ownership callback + boot banner
└── web/                       React / TS / Tailwind UI
    ├── package.json, vite.config.ts, tsconfig.json, tailwind.config.cjs, postcss.config.cjs
    ├── index.html             Vite dev entry
    ├── src/                    imports use the `@/` alias (= src/) across group boundaries
    │   ├── main.tsx, App.tsx, index.css              entry points
    │   ├── core/               NUI plumbing: nui.ts, api.ts, types.ts, dev.ts, accountsApi.ts
    │   ├── shell/              the phone OS: PhoneShell, StatusBar, Lockscreen, Homescreen,
    │   │                       ControlCenter, AppSwitcher, app icons/badges, appRegistry,
    │   │                       wallpapers, frameColors, deeplink, SetupFlow
    │   ├── ui/                 reusable iOS primitives: Sheet, AlertDialog, TabBar, SearchBar, …
    │   ├── shared/             cross-app features: AppAuth, ContactPicker/Avatar, AirShare, ShareSheet
    │   ├── apps/               one folder per app (plus _games/ and _classifieds toolkits)
    │   ├── media/              capture: audioMixer, nearbyVoice, shutter
    │   ├── render/             live game-view renderer (vendored three fork + GameRender)
    │   ├── hooks/, stores/, lib/, i18n/, assets/
    └── build/                              Pre-built bundle (committed)
```

### NUI message flow

| Direction        | Channel                          | Payload                                                          |
|------------------|----------------------------------|------------------------------------------------------------------|
| Lua  → React     | `SendNUIMessage('sd-phone:open')`    | `OpenPayload` (config, dock, apps, wallpapers, status bar state) |
| Lua  → React     | `SendNUIMessage('sd-phone:close')`   | (no payload)                                                     |
| Lua  → React     | `SendNUIMessage('sd-phone:battery')` | `number` (0..100)                                                |
| React → Lua      | `fetchNui('sd-phone:close')`         | (no payload)                                                     |
| React → Lua      | `fetchNui('sd-phone:unlock')`        | (no payload)                                                     |
| React → Lua      | `fetchNui('sd-phone:openApp')`       | `{ id, route }`                                                  |

### Net events

| Event                            | Direction        | Payload      |
|----------------------------------|------------------|--------------|
| `sd-phone:client:openFromItem`   | server → client  | `color` (frame colour of the used item) |
| `sd-phone:client:notify`         | server → client  | bridge       |

`lib.callback` `sd-phone:server:phone:resolveOpen(preferred)` → `color | nil`:
the keybind's server-side ownership gate (returns the colour to open with, or
`nil` when the player holds no phone item).

### Exports

| Export       | Returns                  |
|--------------|--------------------------|
| `isOpen()`   | `boolean`                |
| `isLocked()` | `boolean`                |
| `open()`     | opens the phone for the calling client |
| `close()`    | closes the phone         |

## Building the UI

The shipped `web/build/` was produced by Vite. To customise:

```bash
cd web
npm install
npm run dev        # local dev server with mock NUI data injected
npm run build      # writes web/build/index.html + assets/
```

The dev server (`npm run dev`) injects an `OpenPayload` immediately on
boot so the lockscreen renders against mock data. Keyboard shortcuts:

* `Enter` / `Space` / `H` — skip the unlock swipe.
* `L` — relock without closing the phone.
* `Esc` — close the phone.

For local previewing without FiveM, open `web/build/index.html`
directly — the bundle detects the missing `GetParentResourceName` and
auto-injects mock data.

## Notes

* **App surfaces are stubbed.** v0.1 ships the lockscreen + homescreen
  only. Tapping an app icon logs to console; no app screen is mounted.
* **Wallpapers ship as CSS gradients.** Drop JPGs into
  `web/public/wallpapers/` and reference them from config to swap in
  real artwork without rebuilding.
* **Battery is cosmetic.** Drains ~1% per 30s while the phone is open,
  resets to `Config.StatusBar.BatteryStart` on each open. No physical
  battery model.
* **Single-page homescreen.** Static second-page dot rendered for
  visual parity but no second page exists yet. Page swipe pending.

## Credits

* Bridge structure copied wholesale from [`sd-pettycrime`](https://docs.sd-scripts.com/).
* Coding style modelled on [`sd-pointcontrol`](https://docs.sd-scripts.com/) —
  modular per-domain folders, ox_lib `require` chains from entry
  points, NUI snapshot broadcast.
* iPhone bezel asset cropped + alpha-keyed from a public iPhone 14 Pro
  mockup PNG (`iphone_regular.png` at the resource root, kept for
  reference).
