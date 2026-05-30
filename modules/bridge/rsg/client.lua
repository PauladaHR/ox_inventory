local RSGCore = exports['rsg-core']:GetCoreObject()

RegisterNetEvent('RSGCore:Client:OnPlayerUnload', function()
    client.onLogout()
end)

RegisterNetEvent('RSGCore:Player:SetPlayerData', function(data)
    RSGCore.PlayerData = data
end)

RegisterNetEvent('RSGCore:Client:OnJobUpdate', function()
    TriggerServerEvent('ox_inventory:rsg:requestGroups')
end)

RegisterNetEvent('ox_inventory:rsg:setGroups', function(groups)
    client.setPlayerData('groups', groups or {})
end)

---@diagnostic disable-next-line: duplicate-set-field
function client.setPlayerStatus(values)
    for name, value in pairs(values) do
        if value > 100 or value < -100 then
            value = value * 0.0001
        end

        local currentValue = client.player:get(name) or 0
        client.player:setr(name, lib.math.clamp(currentValue + value, 0, 100))
    end
end
