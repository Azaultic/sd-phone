---@type table sd-phone config root (configs/config.lua).
local config  = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid/name lookups + online-source maps.
local player  = require 'bridge.server.player'
---@type table Groups persistence layer (server.groups.store): phone_groups row CRUD + active-group pointers.
local store   = require 'server.groups.store'

---@type table Groups app config (configs/groups.lua): member/invite caps + name length rules.
local groupsCfg = config.Groups

---@type table Actions module; the table returned at end of file.
local actions = {}

---@type string Sentinel returned to React in place of the requesting player's own citizenid.
---Mirrors the 'local' checks in web/src/apps/groups/ - the UI never learns its own real cid.
local LOCAL_ID = 'local'

local util = require 'server.util'
local ok, fail = util.ok, util.fail


---Resolve a connected player's display name + citizenid in one go, from their server id ONLY -
---the single source of actor identity in this module, so a crafted payload can never
---impersonate another player. Returns nil for offline / unknown sources so callers can
---early-return.
---@param source number
---@return { cid: string, name: string }|nil
local function whois(source)
    local cid  = player.getIdentifier(source)
    if not cid then return nil end
    return { cid = cid, name = player.getName(source) }
end

---Coerce a client-supplied callback payload to a table. A modded client can send any msgpack
---value (number, boolean, ...) where the UI sends a table, and indexing a non-table raises -
---so every payload-taking handler normalizes through here before its first field read.
---@param payload any
---@return table
local function asTable(payload)
    return type(payload) == 'table' and payload or {}
end

---Reshape a hydrated store group into the React `Group` shape, with the requesting player's
---citizenid masked as 'local'. Fellow members' real citizenids ARE sent - the kick flow keys
---its target on them. `onlineCids` is an optional `{ [cid] = source }` map; when supplied each
---output member gets an `online` boolean and the group's `onlineCount` is populated.
---@param group { id: string, name: string, leader_cid: string, color: string, members: table[] }
---@param viewerCid string
---@param onlineCids? table<string, number>
---@return { id: string, name: string, leaderId: string, leaderName: string, color: string, members: { id: string, name: string, online: boolean }[], onlineCount: number }
function actions.serializeGroup(group, viewerCid, onlineCids)
    onlineCids = onlineCids or {}
    local leaderName = 'Unknown'
    local outMembers = {}
    local onlineCount = 0

    for i = 1, #group.members do
        local m = group.members[i]
        local id = (m.citizenid == viewerCid) and LOCAL_ID or m.citizenid
        local online = onlineCids[m.citizenid] ~= nil
        if online then onlineCount = onlineCount + 1 end
        outMembers[i] = { id = id, name = m.name, online = online }
        if m.citizenid == group.leader_cid then
            leaderName = m.name
        end
    end

    local leaderId = (group.leader_cid == viewerCid) and LOCAL_ID or group.leader_cid

    return {
        id          = group.id,
        name        = group.name,
        leaderId    = leaderId,
        leaderName  = leaderName,
        color       = group.color,
        avatar      = group.avatar,
        members     = outMembers,
        onlineCount = onlineCount,
    }
end

---Reshape an `{ invite, group }` pair from the store into the React `Invite` shape.
---@param pair { invite: table, group: table }
---@return { id: string, groupId: string, groupName: string, invitedBy: string, memberCount: number, color: string }
local function serializeInvite(pair)
    return {
        id          = pair.invite.id,
        groupId     = pair.group.id,
        groupName   = pair.group.name,
        invitedBy   = pair.invite.invited_name,
        memberCount = #pair.group.members,
        color       = pair.group.color,
        avatar      = pair.group.avatar,
    }
end

actions.serializeInvite = serializeInvite

---Load the full Groups state for one player - groups, pending invites, and active-group id -
---as a single round-trip. The online-cid map is computed once and reused across every group's
---serialization. Also self-heals a stale active pointer: if the stored active group no longer
---lists the caller as a member (or was deleted), it's cleared instead of returned, so exports
---reading the active group can't be pointed at a group the player left.
---@param source number
---@return { success: true, data: { groups: any[], invites: any[], activeGroupId: string|nil } }|{ success: false, message: string }
function actions.list(source)
    local me = whois(source); if not me then return fail('Player not found') end

    local groupRows   = store.listForMember(me.cid)
    local invitePairs = store.listInvitesFor(me.cid)
    local onlineCids  = player.onlineCidMap()

    local groups = {}
    for i = 1, #groupRows do
        groups[i] = actions.serializeGroup(groupRows[i], me.cid, onlineCids)
    end

    local invites = {}
    for i = 1, #invitePairs do
        invites[i] = serializeInvite(invitePairs[i])
    end

    local activeId = store.getActiveGroupId(me.cid)
    if activeId then
        local stillMember = false
        for i = 1, #groupRows do
            if groupRows[i].id == activeId then stillMember = true; break end
        end
        if not stillMember then
            store.clearActiveGroupForPlayer(me.cid, activeId)
            activeId = nil
        end
    end

    return ok({ groups = groups, invites = invites, activeGroupId = activeId })
end

local colorFor = util.colorFor


---Normalize and validate a player-supplied group name: type-checked (it's an
---attacker-controlled payload field), trimmed, then length-gated by configs/groups.lua
---MinNameLength/MaxNameLength (the max also keeps it inside the name column's VARCHAR(64)).
---Returns the trimmed name on success or `nil, message` on failure.
---@param raw any
---@return string|nil normalized, string? message
local function validateName(raw)
    if type(raw) ~= 'string' then return nil, 'Group name is required' end
    local trimmed = raw:gsub('^%s+', ''):gsub('%s+$', '')
    if #trimmed < groupsCfg.MinNameLength then
        return nil, ('Group name must be at least %d characters'):format(groupsCfg.MinNameLength)
    end
    if #trimmed > groupsCfg.MaxNameLength then
        return nil, ('Group name must be %d characters or fewer'):format(groupsCfg.MaxNameLength)
    end
    return trimmed, nil
end

---Create a new group with the caller as leader. Name-only - invitees are added afterwards
---from the leader's detail-page invite flow. The MaxOwnedPerPlayer cap is enforced here (not
---just in the UI) so a scripted client can't spam group rows.
---@param source number
---@param payload { name?: string }
---@return table
function actions.create(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local name, err = validateName(payload.name)
    if not name then return fail(err) end

    if store.countOwnedBy(me.cid) >= groupsCfg.MaxOwnedPerPlayer then
        return fail(('You can lead at most %d groups'):format(groupsCfg.MaxOwnedPerPlayer))
    end

    local id = store.newId()
    local members = { { citizenid = me.cid, name = me.name, joined_at = os.time() } }
    if not store.insertGroup(id, name, me.cid, colorFor(name), members) then
        return fail('Failed to create group')
    end

    local row = store.getGroup(id)
    return ok(actions.serializeGroup(row, me.cid))
end

---Send a pending invite to the (online) player identified by `targetSource`. Leadership of
---`groupId` is checked against the CALLER's resolved citizenid, so only the owner can grow
---the group - and the duplicate-member, duplicate-invite, member-cap and invite-cap gates all
---run server-side, where a modded client can't skip them.
---@param source number
---@param payload { groupId?: string, targetSource?: number }
---@return table
function actions.invite(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local groupId = payload.groupId
    local targetSrc = tonumber(payload.targetSource)
    if not groupId or not targetSrc then
        return fail('Group id and target player id are required')
    end

    local group = store.getGroup(groupId)
    if not group then return fail('Group not found') end
    if group.leader_cid ~= me.cid then
        return fail('Only the group leader can send invites')
    end

    local target = whois(targetSrc)
    if not target then return fail('That player is not online') end
    if target.cid == me.cid then return fail('You are already in the group') end

    if store.isMember(groupId, target.cid) then
        return fail(target.name .. ' is already in the group')
    end
    if store.hasPendingInvite(groupId, target.cid) then
        return fail(target.name .. ' already has a pending invite')
    end

    if #group.members >= groupsCfg.MaxMembersPerGroup then
        return fail(('Group already at %d members'):format(groupsCfg.MaxMembersPerGroup))
    end
    if store.countInvitesForGroup(groupId) >= groupsCfg.MaxPendingInvitesPerGroup then
        return fail('Too many pending invites for this group')
    end

    local inviteId = store.newId()
    local invite = {
        id           = inviteId,
        target_cid   = target.cid,
        invited_by   = me.cid,
        invited_name = me.name,
    }
    if not store.addInvite(groupId, invite) then
        return fail('Failed to send invite')
    end

    return ok({
        invite = {
            id          = inviteId,
            groupId     = groupId,
            groupName   = group.name,
            invitedBy   = me.name,
            memberCount = #group.members,
            color       = group.color,
            avatar      = group.avatar,
        },
        targetSource = targetSrc,
    })
end

---Accept a pending invite. Only the invite's own target may consume it (target_cid against
---the caller's resolved cid), and the member cap is re-checked at accept time - a group that
---filled up since the invite was sent consumes the invite without joining. Returns the
---freshly-joined group plus the leader's raw citizenid so init.lua can push a memberJoined
---event to whichever source the leader is connected on.
---@param source number
---@param payload { inviteId?: string }
---@return table
function actions.accept(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local hit = store.findInvite(payload.inviteId or '')
    if not hit then return fail('Invite no longer valid') end
    if hit.invite.target_cid ~= me.cid then return fail('That invite is for someone else') end

    if #hit.group.members >= groupsCfg.MaxMembersPerGroup then
        store.removeInvite(hit.invite.id)
        return fail('Group is full')
    end

    store.addMember(hit.group.id, me.cid, me.name)
    store.removeInvite(hit.invite.id)

    local row = store.getGroup(hit.group.id)
    if not row then return fail('Group was disbanded') end

    return ok({
        group  = actions.serializeGroup(row, me.cid),
        leader = row.leader_cid,
    })
end

---Decline (drop) a pending invite. The target check applies while the invite still exists,
---so one player can't burn another's pending invite. Idempotent - silently succeeds if the
---invite has already been consumed/declined elsewhere.
---@param source number
---@param payload { inviteId?: string }
---@return table
function actions.decline(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local hit = store.findInvite(payload.inviteId or '')
    if hit and hit.invite.target_cid ~= me.cid then
        return fail('That invite is for someone else')
    end
    store.removeInvite(payload.inviteId or '')
    return ok()
end

---Leave a group as a non-leader member. Leaders use `disband` - leadership transfer is a
---v0.2 feature. Membership is checked before the row mutation, and the caller's active-group
---pointer is cleared so exports can't keep reading a group they just left.
---@param source number
---@param payload { groupId?: string }
---@return table
function actions.leave(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local group = store.getGroup(payload.groupId or '')
    if not group then return fail('Group not found') end
    if group.leader_cid == me.cid then
        return fail('Leaders must disband — leave is for members')
    end
    if not store.isMember(group.id, me.cid) then
        return fail('You are not in that group')
    end

    store.removeMember(group.id, me.cid)
    store.clearActiveGroupForPlayer(me.cid, group.id)
    return ok({ groupId = group.id })
end

---Disband a group entirely (leader-only, checked against the caller's resolved cid). Returns
---the citizenids of the now-ex-members so init.lua can push a `disbanded` event to each one
---that's online; every player's active-group pointer to this group is cleared so nothing
---dangles at the deleted id.
---@param source number
---@param payload { groupId?: string }
---@return table
function actions.disband(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local group = store.getGroup(payload.groupId or '')
    if not group then return fail('Group not found') end
    if group.leader_cid ~= me.cid then
        return fail('Only the leader can disband the group')
    end

    local memberCids = {}
    for i = 1, #group.members do memberCids[i] = group.members[i].citizenid end

    store.deleteGroup(group.id)
    store.clearActiveGroupEverywhere(group.id)

    return ok({ groupId = group.id, memberCids = memberCids, name = group.name })
end

---Leader kicks a member by citizenid. Uses citizenid (not source) so the kicked player can be
---offline at the time of the kick. Leader-only, self-kick and leader-kick are refused, and the
---target must be an existing member - so an arbitrary payload string matches nothing and
---mutates nothing. The kicked player's active-group pointer is cleared too.
---@param source number
---@param payload { groupId?: string, citizenid?: string }
---@return table
function actions.kick(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local group = store.getGroup(payload.groupId or '')
    if not group then return fail('Group not found') end
    if group.leader_cid ~= me.cid then
        return fail('Only the leader can remove members')
    end
    if payload.citizenid == me.cid then
        return fail('Use disband to remove yourself as leader')
    end
    if payload.citizenid == group.leader_cid then
        return fail('Cannot remove the leader')
    end
    if not store.isMember(group.id, payload.citizenid or '') then
        return fail('That player is not in the group')
    end

    store.removeMember(group.id, payload.citizenid)
    store.clearActiveGroupForPlayer(payload.citizenid, group.id)
    return ok({ groupId = group.id, citizenid = payload.citizenid })
end

---Set a group's picture (leader-only). The URL normally comes from the Photos app picker (a
---Fivemanage upload owned by the player), but any string is accepted - so it's type-checked,
---trimmed and truncated to the avatar column's VARCHAR(512) before it reaches the store.
---Returns the member cids so init.lua can push a refresh to everyone else who's online.
---@param source number
---@param payload { groupId?: string, avatar?: string }
---@return table
function actions.setAvatar(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local group = store.getGroup(payload.groupId or '')
    if not group then return fail('Group not found') end
    if group.leader_cid ~= me.cid then
        return fail('Only the leader can change the group photo')
    end

    local avatar = payload.avatar
    if type(avatar) ~= 'string' then return fail('A photo is required') end
    avatar = avatar:gsub('^%s+', ''):gsub('%s+$', '')
    if avatar == '' then return fail('A photo is required') end
    if #avatar > 512 then avatar = avatar:sub(1, 512) end

    if not store.setAvatar(group.id, avatar) then
        return fail('Failed to update group photo')
    end

    local memberCids = {}
    for i = 1, #group.members do memberCids[i] = group.members[i].citizenid end

    return ok({ groupId = group.id, avatar = avatar, memberCids = memberCids })
end

---Set (or clear) the caller's active group. Pass `groupId = nil` to clear. Setting requires
---the caller to actually be a member, so a crafted id can't point other resources (reading
---the getActiveGroup export) at a group the player isn't in.
---@param source number
---@param payload { groupId?: string|nil }
---@return table
function actions.setActive(source, payload)
    payload = asTable(payload)
    local me = whois(source); if not me then return fail('Player not found') end

    local groupId = payload.groupId
    if groupId == nil or groupId == '' then
        store.setActiveGroupId(me.cid, nil)
        return ok({ activeGroupId = nil })
    end

    if not store.isMember(groupId, me.cid) then
        return fail('You are not a member of that group')
    end

    if not store.setActiveGroupId(me.cid, groupId) then
        return fail('Failed to set active group')
    end
    return ok({ activeGroupId = groupId })
end

---Build the export-ready view of a group: real citizenids (no 'local' rewrite) plus a live
---`source` field per member that's currently online. For trusted callers only - the
---server-side exports and the membership-gated exportView callback in init.lua.
---@param groupId string
---@return { id: string, name: string, color: string, leaderCitizenid: string, members: { citizenid: string, name: string, source: number|nil }[] }|nil
function actions.getGroupForExport(groupId)
    local g = store.getGroup(groupId)
    if not g then return nil end
    local onlineCids = player.onlineCidMap()
    local members = {}
    for i = 1, #g.members do
        local m = g.members[i]
        members[i] = {
            citizenid = m.citizenid,
            name      = m.name,
            source    = onlineCids[m.citizenid],
        }
    end
    return {
        id              = g.id,
        name            = g.name,
        color           = g.color,
        avatar          = g.avatar,
        leaderCitizenid = g.leader_cid,
        members         = members,
    }
end

---Convenience: export-view of a specific player's active group. Returns nil if the player
---isn't connected, has no active group set, or the active group has been disbanded since they
---set it - in which case the stale pointer is cleared on the way out.
---@param source number
---@return table|nil
function actions.getActiveGroupForExport(source)
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    local activeId = store.getActiveGroupId(cid)
    if not activeId then return nil end

    local g = actions.getGroupForExport(activeId)
    if not g then
        store.clearActiveGroupForPlayer(cid, activeId)
        return nil
    end
    return g
end

---Just the active group's id for a given player. Cheap one-row read - useful as a precheck
---before deciding whether to call the full `getActiveGroupForExport`.
---@param source number
---@return string|nil
function actions.getActiveGroupIdFor(source)
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    return store.getActiveGroupId(cid)
end

return actions
