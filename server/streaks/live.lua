---@type table Live-push module; the table returned at end of file.
local live = {}

---@type table<number, boolean> Players with the Streaks gallery open (live-push targets), by src.
---The app subscribes on open and unsubscribes on close, so pushes reach only players actually
---looking at the gallery rather than every online phone (a closed phone has no listener mounted, so
---the old -1 broadcast was pure serialize-and-send waste for it).
local present = {}

---Flip a player's presence. Self-scoped: only ever subscribes/unsubscribes the caller.
---@param src number player server id
---@param on boolean whether the gallery is open
function live.watch(src, on)
    if on then present[src] = true else present[src] = nil end
end

---Drop a departing player's presence (srcs recycle across sessions, so a stale key would push
---another player's gallery update to the wrong client).
---@param src number player server id
function live.drop(src)
    present[src] = nil
end

---Push one gallery event to every present viewer, pruning any whose player has vanished. The
---payload is assembled server-side in actions from validated values only and reaches multiple
---players, so it must never carry a poster's citizenid or any field the gallery UI doesn't render.
---@param event string client event suffix ('newPost' | 'postChanged')
---@param data table sanitized payload
local function push(event, data)
    for src in pairs(present) do
        if GetPlayerName(src) then
            TriggerClientEvent('sd-phone:client:streaks:' .. event, src, data)
        else
            present[src] = nil
        end
    end
end

---A freshly created post - open galleries prepend it without a resync.
---@param data table sanitized post payload { id, author, imageUrl, caption?, dayStreak, postDate, createdAt, likeCount }
function live.newPost(data)
    push('newPost', data)
end

---A like-count change - carries only the post id and its authoritative new count.
---@param data table { postId: integer, likeCount: integer }
function live.postChanged(data)
    push('postChanged', data)
end

return live
