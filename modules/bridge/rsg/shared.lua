local Bridge = {}

local function clone(value)
    if type(value) ~= 'table' then return value end

    local copy = {}

    for k, v in pairs(value) do
        copy[k] = clone(v)
    end

    return copy
end

local function generateText(length)
    local text

    repeat
        local chars = {}

        for i = 1, length do
            chars[i] = string.char(math.random(65, 90))
        end

        text = table.concat(chars)
    until text ~= 'POL' and text ~= 'EMS'

    return text
end

function Bridge.generateSerial()
    return ('%s%s%s'):format(math.random(10, 99), generateText(3), math.random(1000, 9999))
end

local function getRsgItemData(item)
    return item and (item.rsg or item)
end

function Bridge.ensureMetadata(item, metadata)
    metadata = type(metadata) == 'table' and metadata or {}

    local rsg = getRsgItemData(item)
    local itemType = rsg and rsg.type

    if itemType == 'weapon' or itemType == 'weapon_thrown' or itemType == 'equipment' then
        metadata.serie = metadata.serie or metadata.serial or Bridge.generateSerial()
        metadata.serial = metadata.serial or metadata.serie
        metadata.quality = metadata.quality or 100
    elseif rsg and rsg.decay then
        metadata.quality = metadata.quality or 100
        metadata.lastUpdate = metadata.lastUpdate or os.time()
    end

    return metadata
end

function Bridge.toOxSlot(slot, item)
    if not slot or not slot.name then return end

    local metadata = slot.metadata or slot.info or {}

    if type(metadata) ~= 'table' then
        metadata = {}
    else
        metadata = clone(metadata)
    end

    local count = slot.count or slot.amount or 1

    return {
        name = slot.name,
        count = count,
        slot = tonumber(slot.slot) or slot.slot,
        metadata = Bridge.ensureMetadata(item, metadata),
    }
end

function Bridge.toOxInventory(inventory, itemLookup)
    local items = {}

    if type(inventory) ~= 'table' then return items end

    for slotId, slot in pairs(inventory) do
        if slot and slot.name then
            slot.slot = slot.slot or tonumber(slotId) or slotId
            local item = itemLookup and itemLookup(slot.name)
            local oxSlot = Bridge.toOxSlot(slot, item)

            if oxSlot then
                items[#items + 1] = oxSlot
            end
        end
    end

    return items
end

function Bridge.toRsgSlot(slot, item)
    if not slot or not slot.name then return end

    item = getRsgItemData(item) or {}

    local info = slot.metadata or {}

    if type(info) ~= 'table' then
        info = {}
    else
        info = clone(info)
    end

    info.serie = info.serie or info.serial

    if info.serie then
        info.serial = nil
    end

    return {
        name = slot.name,
        amount = slot.count or slot.amount or 1,
        info = info,
        label = item.label or slot.label or slot.name,
        description = item.description or slot.description or '',
        weight = item.weight or slot.weight or 0,
        type = item.type or info.type or 'item',
        unique = item.unique or item.stack == false or false,
        useable = item.useable or false,
        image = item.image or (item.client and item.client.image),
        shouldClose = item.shouldClose ~= nil and item.shouldClose or item.close,
        slot = slot.slot,
        combinable = item.combinable,
        tier = item.tier,
    }
end

function Bridge.toRsgInventory(inventory, itemLookup)
    local items = {}

    if type(inventory) ~= 'table' then return items end

    for slotId, slot in pairs(inventory) do
        if slot and slot.name then
            slot.slot = slot.slot or tonumber(slotId) or slotId
            local item = itemLookup and itemLookup(slot.name)
            local rsgSlot = Bridge.toRsgSlot(slot, item)

            if rsgSlot then
                items[tonumber(rsgSlot.slot) or rsgSlot.slot] = rsgSlot
            end
        end
    end

    return items
end

function Bridge.convertRsgItem(name, item)
    if type(item) ~= 'table' then return end

    name = (item.name or name):lower()

    local converted = {
        label = item.label or name,
        weight = item.weight or 0,
        stack = item.unique ~= true,
        close = item.shouldClose ~= false,
        description = item.description,
        rsg = {
            name = item.name or name,
            label = item.label or name,
            weight = item.weight or 0,
            type = item.type or 'item',
            image = item.image,
            unique = item.unique == true,
            useable = item.useable == true,
            shouldClose = item.shouldClose ~= false,
            description = item.description,
            ammotype = item.ammotype,
            hash = item.hash,
            decay = item.decay,
            delete = item.delete,
            tier = item.tier,
            combinable = item.combinable,
            baseprice = item.baseprice,
            info = item.info,
        }
    }

    if item.image then
        converted.client = { image = item.image }
    end

    return converted
end

function Bridge.loadItems()
    if shared.framework ~= 'rsg' then return end

    local state = GetResourceState('rsg-core')

    if state ~= 'started' then
        error('rsg-core must be started before ox_inventory when inventory:framework is "rsg"', 0)
    end

    local core = exports['rsg-core']:GetCoreObject()
    local rsgItems = core and core.Shared and core.Shared.Items
    local items = {}

    if not rsgItems then
        error('rsg-core did not expose Shared.Items', 0)
    end

    for name, item in pairs(rsgItems) do
        items[(item.name or name):lower()] = Bridge.convertRsgItem(name, item)
    end

    return items
end

return Bridge
