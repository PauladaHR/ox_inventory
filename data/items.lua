if shared.framework == 'rsg' then
	local RSGBridge = require 'modules.bridge.rsg.shared'
	return RSGBridge.loadItems()
end