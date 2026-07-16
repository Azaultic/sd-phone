-- Photos / Camera. The Camera app renders the live game view into a NUI canvas (vendored
-- three.js + CfxTexture in web/src/render/) for a first-person viewfinder. The shutter
-- grabs that canvas as a base64 data-URL and sends it to the server over a latent event
-- (server/photos/init.lua), which uploads it to Fivemanage and stores only the returned
-- CDN URL in `phone_photos`.
--
-- The Fivemanage Media key is read SERVER-SIDE so it never reaches clients: set FivemanageMedia
-- in configs/server/apikeys.lua (that file is excluded from fxmanifest files{}). A blank config
-- value still falls back to the legacy `sd_fivemanage_key` server convar. Create a "Media" token
-- at https://app.fivemanage.com.
return {
    -- JPEG quality (0.0 - 1.0). 0.85 matches NPWD's default and balances
    -- file size against visible compression artefacts.
    Quality = 0.85,

    -- Per-player retention cap. Once exceeded, oldest photos are pruned to
    -- keep the row count bounded.
    MaxPhotosPerPlayer = 200,

    -- Per-player cap on custom albums (Recents + Favourites are always-present
    -- standard albums and don't count toward this).
    MaxAlbumsPerPlayer = 50,

    -- Album-name length bounds. Max mirrors the React `<input maxLength>` so
    -- client and server agree.
    MinAlbumNameLength = 1,
    MaxAlbumNameLength = 40,
}
