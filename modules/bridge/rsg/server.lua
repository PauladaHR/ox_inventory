assert(lib.checkDependency('rsg-core', '2.3.0'), 'rsg-core v2.3.0 or higher is required')
assert(GetResourceState('hiro-core') == 'started', 'hiro-core is required and must start before ox_inventory')

local Inventory = require 'modules.inventory.server'
local Items = require 'modules.items.server'
local RSGBridge = require 'modules.bridge.rsg.shared'

local RSGCore = exports['rsg-core']:GetCoreObject()
local Hiro = exports['hiro-core']:GetCoreObject()

local function getPassport(player)
    if not player then return end

    return player.id or player.passport or (player.PlayerData and player.PlayerData.id)
end

local function getFullName(player)
    if not player then return end

    local playerData = player.PlayerData
    local charinfo = player.charinfo or (playerData and playerData.charinfo)

    if charinfo then
        return ('%s %s'):format(charinfo.firstname or '', charinfo.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    end

    return player.name or (playerData and playerData.name) or GetPlayerName(player.source or (playerData and playerData.source))
end

local function getGroups(passport)
    local groups = {}

    if not passport then return groups end

    local ok, userGroups = pcall(Hiro.GetUserGroups, passport)

    if not ok or type(userGroups) ~= 'table' then
        return groups
    end

    for _, group in pairs(userGroups) do
        local _, hierarchy = pcall(Hiro.GetUserHierarchy, passport, group)
        groups[group] = tonumber(hierarchy) or 0
    end

    return groups
end

local function getPlayerFromInventory(inv)
    local source = inv and (inv.id or inv.source)
    return source and RSGCore.Functions.GetPlayer(source)
end

local function normalisePlayerData(player)
    local playerData = player.PlayerData or player
    playerData.identifier = playerData.citizenid
    playerData.name = getFullName(playerData)
    playerData.groups = getGroups(getPassport(playerData))
    return playerData
end

local function setupPlayer(player)
    local source = (player.PlayerData and player.PlayerData.source) or player.source

    if source then
        player.Functions.AddItem = function(item, amount, slot, info, reason, notify)
            local success = Inventory.AddItem(source, item, amount or 1, info, slot)

            if success and notify then
                TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[item], 'add', amount or 1)
            end

            return success
        end

        player.Functions.RemoveItem = function(item, amount, slot, reason, isMove, notify)
            local success = Inventory.RemoveItem(source, item, amount or 1, nil, slot)

            if success and notify then
                TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[item], 'remove', amount or 1)
            end

            return success
        end

        player.Functions.SetInventory = function(items)
            local inv = Inventory(source)

            if not inv then return false end

            local inventory, totalWeight = server.convertInventory(source, items)
            inv.items = inventory
            inv.weight = totalWeight
            inv.changed = true

            local slots = {}
            local index = 0

            for slotId = 1, inv.slots do
                index += 1
                slots[index] = { item = inventory[slotId] or { slot = slotId }, inventory = inv.id }
            end

            inv:syncSlotsWithClients(slots, true)
            server.syncInventory(inv)

            return true
        end

        player.Functions.GetItemBySlot = function(slot)
            local inv = Inventory(source)
            local item = inv and inv.items[tonumber(slot)]

            return item and RSGBridge.toRsgSlot(item, Items(item.name))
        end

        player.Functions.GetItemByName = function(itemName)
            local inv = Inventory(source)
            local slot = inv and Inventory.GetSlotWithItem(inv, itemName)

            return slot and RSGBridge.toRsgSlot(slot, Items(slot.name))
        end
    end

    local playerData = normalisePlayerData(player)
    server.setPlayerInventory(playerData, playerData.items)
end

local function backupRsgInventories()
    if not GetConvarBool('inventory:rsgbackup', true) then return end

    pcall(MySQL.query.await, 'ALTER TABLE `players` ADD COLUMN `inventory_rsg_backup` LONGTEXT NULL')
    pcall(MySQL.query.await, 'UPDATE `players` SET `inventory_rsg_backup` = `inventory` WHERE `inventory_rsg_backup` IS NULL AND `inventory` IS NOT NULL')
end

CreateThread(function()
    backupRsgInventories()

    Wait(1500)

    for _, source in ipairs(RSGCore.Functions.GetPlayers()) do
        local player = RSGCore.Functions.GetPlayer(source)

        if player then
            setupPlayer(player)
        end
    end
end)

AddEventHandler('RSGCore:Server:PlayerLoaded', setupPlayer)

AddEventHandler('RSGCore:Server:OnPlayerUnload', function(source)
    server.playerDropped(source)
end)

AddEventHandler('RSGCore:Server:PlayerDropped', function(player)
    local source = player and player.PlayerData and player.PlayerData.source

    if source then
        server.playerDropped(source)
    end
end)

AddEventHandler('RSGCore:Server:OnJobUpdate', function(source)
    local player = RSGCore.Functions.GetPlayer(source)
    local inventory = Inventory(source)

    if not player or not inventory or not inventory.player then return end

    inventory.player.groups = getGroups(player.PlayerData.id)
    inventory.player.job = Hiro.GetUserJob(player.PlayerData.id)
    TriggerClientEvent('ox_inventory:rsg:setGroups', source, inventory.player.groups)
end)

RegisterNetEvent('ox_inventory:rsg:requestGroups', function()
    local source = source
    local player = RSGCore.Functions.GetPlayer(source)
    local inventory = Inventory(source)

    if not player or not inventory or not inventory.player then return end

    inventory.player.groups = getGroups(player.PlayerData.id)
    TriggerClientEvent('ox_inventory:rsg:setGroups', source, inventory.player.groups)
end)

---@diagnostic disable-next-line: duplicate-set-field
function server.setPlayerData(player)
    local passport = getPassport(player)
    local job = passport and Hiro.GetUserJob(passport) or player.job

    return {
        source = player.source,
        id = passport,
        passport = passport,
        citizenid = player.citizenid,
        name = getFullName(player),
        groups = getGroups(passport),
        job = job,
        sex = player.charinfo and player.charinfo.gender,
        dateofbirth = player.charinfo and player.charinfo.birthdate,
    }
end

---@diagnostic disable-next-line: duplicate-set-field
function server.hasGroup(inv, group)
    local player = inv.player or inv
    local passport = player.passport or player.id

    if not passport then return end

    local function hasPermission(permission, level)
        if type(level) == 'table' then
            for i = 1, #level do
                if Hiro.HasPermission(passport, permission, level[i]) then
                    return permission, Hiro.GetUserHierarchy(passport, permission) or level[i]
                end
            end

            return
        end

        if Hiro.HasPermission(passport, permission, level) then
            return permission, Hiro.GetUserHierarchy(passport, permission) or level or 0
        end
    end

    if type(group) == 'table' then
        for name, requiredLevel in pairs(group) do
            local groupName, groupRank = hasPermission(name, requiredLevel)

            if groupName then
                return groupName, groupRank
            end
        end

        return
    end

    return hasPermission(group)
end

function server.convertInventory(source, data)
    local converted = RSGBridge.toOxInventory(data, Items)
    local inventory = {}
    local totalWeight = 0
    local ostime = os.time()

    for i = 1, #converted do
        local slot = converted[i]
        local item = Items(slot.name)

        if item then
            slot.metadata = Items.CheckMetadata(slot.metadata or {}, item, slot.name, ostime)

            local weight = Inventory.SlotWeight(item, slot)
            totalWeight += weight

            inventory[slot.slot] = {
                name = item.name,
                label = item.label,
                weight = weight,
                slot = slot.slot,
                count = slot.count,
                description = item.description,
                metadata = slot.metadata,
                stack = item.stack,
                close = item.close,
            }
        end
    end

    return inventory, totalWeight
end

---@diagnostic disable-next-line: duplicate-set-field
function server.syncInventory(inv)
    local player = getPlayerFromInventory(inv)

    if not player then return end

    local rsgItems = RSGBridge.toRsgInventory(inv.items, Items)
    player.Functions.SetPlayerData('items', rsgItems)
end

local function ensureWeaponRegistration(source, item)
    if not item.info or not item.info.serie then return end

    local player = RSGCore.Functions.GetPlayer(source)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid

    if not citizenid then return end

    local exists = MySQL.scalar.await('SELECT 1 FROM player_weapons WHERE serial = ? AND citizenid = ? LIMIT 1', {
        item.info.serie,
        citizenid,
    })

    if not exists then
        MySQL.insert.await('INSERT INTO player_weapons (serial, citizenid) VALUES (?, ?)', {
            item.info.serie,
            citizenid,
        })
    end
end

function server.UseItem(source, itemName, data)
    local item = Items(itemName)
    local rsgItem = RSGBridge.toRsgSlot(data, item)

    if not rsgItem then return end

    if rsgItem.type == 'weapon' then
        ensureWeaponRegistration(source, rsgItem)
        TriggerClientEvent('rsg-weapons:client:UseWeapon', source, rsgItem)
        return true
    elseif rsgItem.type == 'weapon_thrown' then
        TriggerClientEvent('rsg-weapons:client:UseThrownWeapon', source, rsgItem)
        return true
    elseif rsgItem.type == 'equipment' then
        TriggerClientEvent('rsg-weapons:client:UseEquipment', source, rsgItem)
        return true
    end

    local usable = RSGCore.Functions.CanUseItem(itemName)
    local callback = type(usable) == 'table' and (rawget(usable, '__cfx_functionReference') and usable or usable.cb or usable.callback) or type(usable) == 'function' and usable

    if not callback then return false end

    return callback(source, rsgItem)
end

---@diagnostic disable-next-line: duplicate-set-field
function server.isPlayerBoss(playerId, group)
    local player = RSGCore.Functions.GetPlayer(playerId)
    local passport = player and player.PlayerData and player.PlayerData.id

    if not passport then return false end

    return Hiro.GetUserHierarchy(passport, group) == 1
end
