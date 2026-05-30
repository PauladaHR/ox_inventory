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

local function setupPlayer(Player)
    local PlayerData = normalisePlayerData(Player)
    server.setPlayerInventory(PlayerData, PlayerData.items)

        -- Add player methods FIRST before doing anything else
    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "AddItem", function(item, amount, slot, info)
        return Inventory.AddItem(Player.PlayerData.source, item, amount, info, slot)
    end)

    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "RemoveItem", function(item, amount, slot)
        return Inventory.RemoveItem(Player.PlayerData.source, item, amount, nil, slot)
    end)

    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "GetItemBySlot", function(slot)
        return setItemCompatibilityProps(Inventory.GetSlot(Player.PlayerData.source, slot))
    end)

    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "GetItemByName", function(itemName)
        return setItemCompatibilityProps(Inventory.GetSlotWithItem(Player.PlayerData.source, itemName))
    end)

    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "GetItemsByName", function(itemName)
        return setItemCompatibilityProps(Inventory.GetSlotsWithItem(Player.PlayerData.source, itemName))
    end)

    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "ClearInventory", function(filterItems)
        Inventory.Clear(Player.PlayerData.source, filterItems)
    end)

    RSGCore.Functions.AddPlayerMethod(Player.PlayerData.source, "SetInventory", function(items)
        return exports.ox_inventory:setPlayerInventory(Player.PlayerData.source, items)
    end)
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


local function export(exportName, func)
    AddEventHandler(('__cfx_export_%s_%s'):format(string.strsplit('.', exportName, 2)), function(setCB)
        setCB(func or function()
            error(("export '%s' is not supported when using ox_inventory"):format(exportName))
        end)
    end)
end

---Imagine if somebody who uses qb/qbox would PR these functions.
export('rsg-inventory.LoadInventory', function(playerId)
    if Inventory(playerId) then return end

    local player = RSGCore.Functions.GetPlayer(playerId)

    if player then
        setupPlayer(player)

        return Inventory(playerId).items
    end
end)

export('rsg-inventory.SaveInventory', function(playerId)
    if type(playerId) ~= 'number' then
        TypeError('playerId', 'number', type(playerId))
    end

    Inventory.Save(playerId)
end)

export('rsg-inventory.SetInventory', function(invId, items)
    return exports.ox_inventory:setPlayerInventory(invId, items)
end)

export('rsg-inventory.SetItemData')
export('rsg-inventory.UseItem')
export('rsg-inventory.GetSlotsByItem')
export('rsg-inventory.GetFirstSlotByItem')

export('rsg-inventory.GetItemBySlot', function(playerId, slotId)
    return Inventory.GetSlot(playerId, slotId)
end)

export('rsg-inventory.GetTotalWeight', function(playerId)
    local inventory = exports.ox_inventory:GetInventory(playerId)
    return inventory and inventory.weight or 0
end)

export('rsg-inventory.GetItemsByName', function(playerId, itemName)
    local items = Inventory.GetSlotsWithItem(playerId, itemName)
    if not items then return {} end

    -- Convert to RSG format with compatibility props
    local result = {}
    for i, item in pairs(items) do
        if item then
            item.info = item.metadata
            item.amount = item.count
            result[i] = item
        end
    end
    return result
end)

export('rsg-inventory.GetSlots')
export('rsg-inventory.GetItemCount')

export('rsg-inventory.CanAddItem', function(playerId, itemName, amount)
    return (Inventory.CanCarryAmount(playerId, itemName) or 0) >= amount
end)

export('rsg-inventory.ClearInventory', function(playerId, filter)
    Inventory.Clear(playerId, filter)
end)

export('rsg-inventory.CloseInventory', function(playerId, inventoryId)
    local playerInventory = Inventory(playerId)

    if not playerInventory then return end

    local inventory = Inventory(playerInventory.open)

    if inventory and (inventoryId == inventory.id or not inventoryId) then
        playerInventory:closeInventory()
    end
end)

export('rsg-inventory.OpenInventory', function(playerId, invId, data)
    if data and data.maxweight and data.slots then
        exports.ox_inventory:RegisterStash(invId, data.label or invId, data.slots, data.maxweight)
    end
    return exports.ox_inventory:forceOpenInventory(playerId, 'stash', invId)
end)

export('rsg-inventory.OpenInventoryById', function(playerId, targetId)
    return exports.ox_inventory:forceOpenInventory(playerId, 'player', targetId)
end)

local pendingShops = {}

export('rsg-inventory.CreateShop', function(shopData)
    local oxShopData = {
        name = shopData.name,
        inventory = {},
        groups = shopData.groups,
    }

    if shopData.items then
        for i, item in pairs(shopData.items) do
            oxShopData.inventory[i] = {
                name = item.name,
                price = item.price,
                count = item.amount or item.count or 1
            }
        end
    end

    pendingShops[shopData.name] = oxShopData
    return true
end)

export('rsg-inventory.OpenShop', function(playerId, shopName)
    local player = RSGCore.Functions.GetPlayer(playerId)
    if not player then return false end

    local shopData = pendingShops[shopName]
    if not shopData then return false end

    local ped = GetPlayerPed(playerId)
    local coords = GetEntityCoords(ped)

    -- Add the player's current location to the shop data
    shopData.locations = {{
        coords = coords,
        size = vec3(2, 2, 2)
    }}

    exports.ox_inventory:RegisterShop(shopName, shopData)

    TriggerClientEvent('rsg-inventory:openShop', playerId, {type = shopName, id = 1})
    return true
end)
export('rsg-inventory.CreateInventory', function(invId, data)
    if data and data.maxweight and data.slots then
        exports.ox_inventory:RegisterStash(invId, data.label or invId, data.slots, data.maxweight)
    end
end)

--- Check if a shop exists in the registry.
--- @param shopName string Name of the shop
--- @return boolean True if the shop exists, false otherwise
export('rsg-inventory.DoesShopExist', function(shopName)
        if type(shopName) ~= "string" then return false end
    return pendingShops and pendingShops[shopName] ~= nil
end)

export('rsg-inventory.AddItem', function(invId, itemName, amount, slot, metadata, reason)
    if exports.ox_inventory:CanCarryItem(invId, itemName, amount, metadata) then
        exports.ox_inventory:AddItem(invId, itemName, amount, metadata, slot)
        return true
    end
    return false
end)

export('rsg-inventory.RemoveItem', function(invId, itemName, amount, slot, reason)
    if exports.ox_inventory:RemoveItem(invId, itemName, amount, nil, slot) then
        return true
    else
        warn('Failed to remove item:', itemName)
        return false
    end
end)

export('rsg-inventory.HasItem', function(items, amount)
    amount = amount or 1

    local count = exports.ox_inventory:Search('count', items)

    if type(items) == 'table' and type(count) == 'table' then
        for _, v in pairs(count) do
            if v < amount then
                return false
            end
        end

        return true
    end

    return count >= amount
end)