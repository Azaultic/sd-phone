---@type table Groups persistence layer (server.groups.store): phone_groups row CRUD + active-group pointers.
local store   = require 'server.groups.store'
---@type table Authoritative Groups handlers (server.groups.actions): validation + permission checks.
local actions = require 'server.groups.actions'
---@type table Player bridge (bridge.server.player): citizenid lookups + cid-to-source resolution.
local player  = require 'bridge.server.player'
---@type table Badge engine (server.badges.init): recomputes + pushes home-screen unread counts.
local badges  = require 'server.badges.init'

---Schema bootstrap. Runs in a thread so it can yield until oxmysql is ready without
---blocking resource start.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:groups]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:groups]^0 schema ready')
end)

---Push a group-related event to a single player. No-op if they're offline - there's no
---listener to receive it and they'll pick up the new state next time their Groups app reloads.
---@param src number|nil
---@param eventName string
---@param payload any
local function pushTo(src, eventName, payload)
    if not src then return end
    TriggerClientEvent(eventName, src, payload)
end

-- Authoritative NUI-facing callbacks: the validation + permission checks (leader-only
-- mutations, invite-target checks, caps) live in server.groups.actions, where each handler
-- is documented. Handlers here only add the push fan-out that needs cid-to-source resolution.
lib.callback.register('sd-phone:server:groups:list', function(src)
    return actions.list(src)
end)

lib.callback.register('sd-phone:server:groups:create', function(src, payload)
    return actions.create(src, payload)
end)

---Send an invite (leader-gated in actions.invite), then alert the online target three ways:
---the raw inviteReceived push for an open Groups app, a notification banner, and a badge
---recount. `targetSource` is stripped from the response so the inviting client only gets the
---invite row back.
lib.callback.register('sd-phone:server:groups:invite', function(src, payload)
    local result = actions.invite(src, payload)
    if result.success and result.data and result.data.invite then
        local targetSrc = result.data.targetSource
        local inv = result.data.invite
        pushTo(targetSrc, 'sd-phone:client:groups:inviteReceived', inv)
        pushTo(targetSrc, 'sd-phone:client:notify', {
            app   = 'groups',
            appId = 'groups',
            title = inv.groupName or 'Group invite',
            body  = ('%s invited you to join'):format(inv.invitedBy or 'Someone'),
            time  = 'now',
        })
        badges.push(targetSrc)
        result.data = { invite = inv }
    end
    return result
end)

---Accept an invite (target-gated in actions.accept). On success the leader, if online, gets a
---memberJoined push so an open detail page refreshes; the leader's raw citizenid is stripped
---from the response. The badge recount runs on success AND failure - a dead invite consumed
---elsewhere still needs the caller's Groups badge corrected.
lib.callback.register('sd-phone:server:groups:accept', function(src, payload)
    local result = actions.accept(src, payload)
    if result.success and result.data then
        local leaderSrc = player.getSourceByIdentifier(result.data.leader)
        pushTo(leaderSrc, 'sd-phone:client:groups:memberJoined', {
            groupId = result.data.group.id,
        })
        result.data = { group = result.data.group }
    end
    badges.push(src)
    return result
end)

---Decline an invite (idempotent in actions.decline) and recount the caller's Groups badge -
---declining is one of the two ways a pending-invite badge unit clears.
lib.callback.register('sd-phone:server:groups:decline', function(src, payload)
    local result = actions.decline(src, payload)
    badges.push(src)
    return result
end)

---Leave a group (member-only; actions.leave rejects leaders). The leader is re-read from the
---store AFTER the removal so the memberLeft push only fires for a group that still exists.
lib.callback.register('sd-phone:server:groups:leave', function(src, payload)
    local result = actions.leave(src, payload)
    if result.success and result.data then
        local group = store.getGroup(result.data.groupId)
        if group then
            local leaderSrc = player.getSourceByIdentifier(group.leader_cid)
            pushTo(leaderSrc, 'sd-phone:client:groups:memberLeft', {
                groupId = result.data.groupId,
            })
        end
    end
    return result
end)

---Disband a group (leader-gated in actions.disband) and push a disbanded notice to every
---OTHER online ex-member. The member-cid list is stripped from the response - the disbanding
---client only needs the group id back.
lib.callback.register('sd-phone:server:groups:disband', function(src, payload)
    local result = actions.disband(src, payload)
    if result.success and result.data then
        for i = 1, #result.data.memberCids do
            local cid = result.data.memberCids[i]
            local memberSrc = player.getSourceByIdentifier(cid)
            if memberSrc and memberSrc ~= src then
                pushTo(memberSrc, 'sd-phone:client:groups:disbanded', {
                    groupId = result.data.groupId,
                    name    = result.data.name,
                })
            end
        end
        result.data = { groupId = result.data.groupId }
    end
    return result
end)

---Kick a member by citizenid (leader-gated in actions.kick) and, if the kicked player is
---online, push them a kicked notice so their app drops the group immediately.
lib.callback.register('sd-phone:server:groups:kick', function(src, payload)
    local result = actions.kick(src, payload)
    if result.success and result.data then
        local kickedSrc = player.getSourceByIdentifier(result.data.citizenid)
        pushTo(kickedSrc, 'sd-phone:client:groups:kicked', {
            groupId = result.data.groupId,
        })
    end
    return result
end)

---Change the group photo (leader-gated in actions.setAvatar) and push an updated notice to
---every OTHER online member so their list refreshes. Member cids are stripped from the
---response - the leader's client only needs the group id and the stored URL back.
lib.callback.register('sd-phone:server:groups:setAvatar', function(src, payload)
    local result = actions.setAvatar(src, payload)
    if result.success and result.data then
        for i = 1, #result.data.memberCids do
            local cid = result.data.memberCids[i]
            local memberSrc = player.getSourceByIdentifier(cid)
            if memberSrc and memberSrc ~= src then
                pushTo(memberSrc, 'sd-phone:client:groups:updated', {
                    groupId = result.data.groupId,
                })
            end
        end
        result.data = { groupId = result.data.groupId, avatar = result.data.avatar }
    end
    return result
end)

-- Thin delegates: active-group selection (membership-gated) and the cheap active-id read,
-- both documented in server.groups.actions.
lib.callback.register('sd-phone:server:groups:setActive', function(src, payload)
    return actions.setActive(src, payload)
end)

lib.callback.register('sd-phone:server:groups:activeId', function(src)
    return actions.getActiveGroupIdFor(src)
end)

---Full export-view (real citizenids + live member sources) for the caller's client-side
---cache. Membership-gated: the view names every member's citizenid and current server id, so
---only a current member may pull it - a kicked player, or any modded client probing group
---ids, gets nil. The legitimate client only ever asks for its own active group, which
---membership always covers.
lib.callback.register('sd-phone:server:groups:exportView', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid or not store.isMember(payload.groupId or '', cid) then return nil end
    return actions.getGroupForExport(payload.groupId or '')
end)

-- Server-side exports for other resources. Trusted callers (never reachable by a client), so
-- they return the unmasked export view; each delegate is documented in server.groups.actions.
---@param source number player whose active group is requested
---@return table|nil export-view of the player's active group
exports('getActiveGroup', function(source)
    return actions.getActiveGroupForExport(source)
end)

---@param source number player whose active group id is requested
---@return string|nil cached id, nil if no active group set
exports('getActiveGroupId', function(source)
    return actions.getActiveGroupIdFor(source)
end)

---@param groupId string
---@return table|nil export-view of the named group
exports('getGroup', function(groupId)
    return actions.getGroupForExport(groupId)
end)
