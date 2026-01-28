-- Services:
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StarterPack = game:GetService("StarterPack")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

-- Data stores:
local InvDataStore = DataStoreService:GetDataStore("InventoryDataStore")

-- Modules:
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Types = require(Modules.Types)
local Janitor = require(Modules.Janitor)
local Signal = require(Modules.Signal)

-- Constants:
local AUTO_SAVE_TIME = 60 * 2 -- time in minutes for auto saving data
local SAVE_KEY = "%i-V.01" -- key for saving data

local InventoryServer = {}

InventoryServer.Inventories = {}
InventoryServer.Janitors = {}
InventoryServer.HasLoaded = {} 
InventoryServer.Respawning = {} 
InventoryServer.ToolCanTouch = {}
InventoryServer.ToolCanCollide = {}

InventoryServer.MaxItemStack = {
	Resource = 16,
	Consumable = 16,
	LegendaryItem = 5,
	MythicItem = 1
}

InventoryServer.MaxStackSize = 20 -- max number of items in inventory

-- Starting the system:
function InventoryServer.start()
	
	for _, player: Player in Players:GetPlayers() do
		InventoryServer.onPlayerAdded(player)
	end
	--when a player joins the game:
	Players.PlayerAdded:Connect(InventoryServer.onPlayerAdded)
	
	--when a player leaves the game:
	Players.PlayerRemoving:Connect(InventoryServer.onPlayerRemoving)
	
	-- Signal remotes:
	-- handling client requests (server validates client requests):
	Signal.ListenRemote("InventoryServer:getInventoryData", InventoryServer.getInventoryData) 
	Signal.ListenRemote("InventoryServer:equipToHotbar", InventoryServer.equipToHotbar)
	Signal.ListenRemote("InventoryServer:unequipFromHotbar", InventoryServer.unequipFromHotbar)
	Signal.ListenRemote("InventoryServer:holdItem", InventoryServer.holdItem)
	Signal.ListenRemote("InventoryServer:unholdItem", InventoryServer.unholdItem)
	Signal.ListenRemote("InventoryServer:dropItem", InventoryServer.dropitem)
	
	--Auto saving players data when game (server) shuts down:
	game:BindToClose(function()
		for _, player: Player in Players:GetPlayers() do
			InventoryServer.saveData(player)
		end 
	end)
	
	--Auto Saving Data based on number of players active in game:
	task.spawn(function()
		while true do
			task.wait()
			for _, player: Player in Players:GetPlayers() do
				task.wait(AUTO_SAVE_TIME / #Players:GetPlayers())
				InventoryServer.saveData(player)
			end
		end
	end)
	
	-- Connceting post simulation:
	RunService.PostSimulation:Connect(InventoryServer.onPostSimulation)
end

-- function to connect to PlayerAdded event:
function InventoryServer.onPlayerAdded(player: Player)
	--waiting until tool is added to player's backpack
	for _, tool: Tool in StarterPack:GetChildren() do
		while not player.Backpack:FindFirstChild(tool.Name) do
			task.wait()
		end
	end
	-- Creating Janitor:
	local janitor = Janitor.new()
	InventoryServer.Janitors[player] = janitor -- adding janitor to Janitors table
	janitor:GiveChore(function()
		InventoryServer.Janitors[player] = nil -- removing janitor from Janitors table 
		InventoryServer.Respawning[player] = nil -- removing player from respawning table
	end)
	
	-- Creating Inventory:
	local inv: Types.Inventory = {
		Inventory = {},
		Hotbar = {},
		NextStackId = 0
	}
	
	InventoryServer.Inventories[player] = inv -- Stores the player's inventory 
	janitor:GiveChore(function()
		InventoryServer.Inventories[player] = nil -- removing inventory from Inventories table (to prevent memmory leak)
	end)
	
	-- Waiting until player's character is loaded:
	if not player.Character then
		player.characterAdded:Wait()
	end
	InventoryServer.loadData(player) -- Loading player's data
	
	function InventoryServer.charAdded(char: Model)
		
		-- Registering and unregistering items based on their parent:
		for i, tool in player.Backpack:GetChildren() do
			InventoryServer.registerItem(player, tool)
		end
		
		char.ChildAdded:Connect(function(child)
			InventoryServer.registerItem(player, child)
		end)
		char.ChildRemoved:Connect(function(child)
			InventoryServer.unregisterItem(player, child)
		end)
		
		player.Backpack.ChildAdded:Connect(function(child)
			InventoryServer.registerItem(player, child)
		end)
		player.Backpack.ChildRemoved:Connect(function(child)
			InventoryServer.unregisterItem(player, child)
		end)
		
		-- function to be ran when a player dies (to ensure they dont lose their items):
		local humanoid: Humanoid = char:WaitForChild("Humanoid")
		humanoid.Died:Connect(function()
			InventoryServer.Respawning[player] = true
			-- Unholding item:
			InventoryServer.unholdItem(player)

			-- Temporarly reparenting all items so that player wont lose their items:
			local allItems: {Tool} = player.Backpack:GetChildren()
			for i, item: Tool in allItems do
				item.Parent = script
			end
 
			-- Character respawning:
			player.CharacterAdded:Wait()
			local backpack = player:WaitForChild("Backpack")
			
			-- Restore tools when player respawns::
			for i, item: Tool in allItems do
				item.Parent = backpack
			end
			
			InventoryServer.Respawning[player] = nil
		end)
	end
	
	task.spawn(InventoryServer.charAdded, player.Character)
	janitor:GiveChore(player.CharacterAdded:Connect(InventoryServer.charAdded))
end

-- funtion to connect to PlayerRemoving event:
function InventoryServer.onPlayerRemoving(player: Player)
	-- Saving data:
	InventoryServer.saveData(player)
	-- Clearing extra data when player leaves game:
	InventoryServer.Janitors[player]:Destroy()
end

-- Heartbeat Loop:
function InventoryServer.onPostSimulation(dt: number)
	InventoryServer.updateDroppedItems()
end

-- Checking if inventory is full:
function InventoryServer.checkInvStorage(player: Player, item: Tool)
	-- Getting inventory
	local inv: Types.Inventory = InventoryServer.Inventories[player]
	-- Checking if inventory is full:
	if #inv.Inventory >= InventoryServer.MaxStackSize then
		for i, stackData: Types.StackData in inv.Inventory do
			if stackData.Name == item.Name and #stackData.Items < InventoryServer.MaxItemStack[stackData.ItemType] then
				return false
			end
		end
		return true
	end
	return false
end

-- Updating dropped Items:
function InventoryServer.updateDroppedItems()
	
	-- Looping through all items:
	for i, tool: Tool in CollectionService:GetTagged("ItemTool") do
		if not tool:IsDescendantOf(workspace) then
			continue
		end
		
		-- Finding handle of the tool:
		local handle = tool:FindFirstChild("Handle")
		if not handle then
			warn("Handle not found for: "..tool.Name) 
			continue
		end
		
		-- Finding humanoid:
		local humanoid: Humanoid? = tool.Parent:FindFirstChild("Humanoid")
		local prompt: ProximityPrompt = handle:FindFirstChild("DropItemsPrompt")
		
		-- Checking if humanoid exists:
		if humanoid then
			
			-- Re-enabling canTouch:
			for i, part:BasePart in tool:GetDescendants() do
				if part:IsA("BasePart") then
					-- Enabling canTouch:
					local preTouchValue = InventoryServer.ToolCanTouch[part]
					if preTouchValue then
						part.CanTouch = preTouchValue
						InventoryServer.ToolCanTouch[part] = nil
					end
					
					-- Enabling canCollide:
					local preCollideValue = InventoryServer.ToolCanCollide[part]
					if preCollideValue then
						part.CanCollide = preCollideValue
						InventoryServer.ToolCanCollide[part] = nil
					end
				end
			end
			
			-- Clearing prompt:
			if prompt then
				prompt:Destroy()
			end
			
		else
			-- Adding prompt to tools:
			if not prompt then
				--Disabling canTouch and canCollide:
				for i, part: BasePart in tool:GetDescendants() do
					if part:IsA("BasePart") then
						-- Disabling canTouch:
						InventoryServer.ToolCanTouch[part] = part.CanTouch
						part.CanTouch = false
						InventoryServer.ToolCanCollide[part] = part.CanCollide
						part.CanCollide = true
					end
				end

				-- Adding prompt to handle:
				prompt = script.DropItemsPrompt:Clone()
				prompt.ObjectText = tool.Name
				prompt.Parent = handle
				
				-- Connecting triggered event:
				prompt.Triggered:Connect(function(player: Player)
					
					-- Checking if inventory is full:
					if InventoryServer.checkInvStorage(player, tool) then
						warn(player.Name.."'s inventory is full")
						return
					end
					
					-- Inserting items into player's backpack:
					local backpack: Backpack = player:FindFirstChild("Backpack")
					if not backpack then
						return
					end
					tool.Parent = backpack
				end)
			end
			
		end
	end
	
end

-- Registering Items:
function InventoryServer.registerItem(player: Player, tool: Tool)
	-- Double checking if tool is a Tool:
	if tool.ClassName ~= "Tool" then
		return
	end
	-- checking if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	
	local inv = InventoryServer.Inventories[player]
	
	-- Making sure tool is not already registered:
	for i, stackData: Types.StackData in inv.Inventory do
		if table.find(stackData.Items, tool) then
			return
		end
	end
	
	local foundStack: Types.StackData = nil
	-- Checking if there is a stack for tool:
	for i, stackData: Types.StackData in inv.Inventory do
		-- Checking if there is space for next item:
		if stackData.Name == tool.Name and #stackData.Items < InventoryServer.MaxItemStack[stackData.ItemType] then
			table.insert(stackData.Items, tool)
			foundStack = stackData
			break
		end
	end
	
	-- Creating a new stack if there is no stack for the tool:
	if not foundStack then
		if #inv.Inventory < InventoryServer.MaxStackSize then
			-- Creating new stack:
			local newStack: Types.StackData = {
				Name = tool.Name,
				Description = tool.ToolTip,
				Image = tool.TextureId,
				ItemType = tool:GetAttribute("ItemType"),
				IsDroppable = tool:GetAttribute("IsDroppable"),
				Items = {tool},
				StackId = inv.NextStackId,
				Rarity = tool:GetAttribute("Rarity")
			}
			inv.NextStackId += 1
			table.insert(inv.Inventory, newStack)
			
			-- Equipping tool to Hotbar:
			for slotNumber: number = 1, 9 do
				if inv.Hotbar["Slot" .. slotNumber] == nil then
					InventoryServer.equipToHotbar(player, slotNumber, newStack.StackId)
					break
				end
			end
		else
			warn("Inventory Full!")
		end
	end
	-- updating Client:
	Signal.FireClient(player, "InventoryClient:update", inv)
end

-- Unregistering Items:
function InventoryServer.unregisterItem(player: Player, tool: Tool)
	-- Double checking if tool is a Tool:
	if tool.ClassName ~= "Tool" then 
		return
	end
	-- checking if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	
	-- If Tool is in Backpack or Character and player's character has loaded in, then the function will not run.
	if tool.Parent == player.Backpack or (player.Character ~= nil and tool.Parent == player.Character) then
		return
	end
	
	-- Getting inventory:
	local inv: Types.Inventory = InventoryServer.Inventories[player]
	
	-- Removing tool from stack:
	for i, stackData: Types.StackData in inv.Inventory do
		-- Finding the tool to be removed:
		local found = table.find(stackData.Items, tool)
		-- Removing tool from stack if tool is found:
		if found then
			table.remove(stackData.Items, found)
		end
		-- Removing stack if it is empty:
		if #stackData.Items == 0 then
			local stackFound = table.find(inv.Inventory, stackData)
			-- Removing stack from inventory if it is found:
			if stackFound then
				table.remove(inv.Inventory, stackFound)
				-- Removing tool from hotbar if it is equipped:
				InventoryServer.unequipFromHotbar(player, stackData.StackId)
			end
		end
	end
	-- updating Client:
	Signal.FireClient(player, "InventoryClient:update", inv)
end

-- Equipping items to Hotbar:
function InventoryServer.equipToHotbar(player: Player, equipTo: number, stackId: number)
	-- checking if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	-- Getting player's inventory:
	local inv = InventoryServer.Inventories[player]
	
	-- Removing tool from hotbar if it is already equipped (to prevent same item to be equipped in hotbar multiple times):
	InventoryServer.unequipFromHotbar(player, stackId)
	
	local isValid: boolean = false
	for i, stackData: Types.StackData in inv.Inventory do
		-- If stack is found in inventory, then it is valid(to be equipped to hotbar):
		if stackData.StackId == stackId then
			isValid = true
		end
	end
	
	-- If the stack is not valid, then the function will not run:
	if isValid == false then
		return
	end
	
	-- If the stack is valid, then equip the tool to hotbar:
	inv.Hotbar["Slot" .. equipTo] = stackId
	-- updating Client:
	Signal.FireClient(player, "InventoryClient:update", inv)
end

-- Unequipping items from Hotbar:
function InventoryServer.unequipFromHotbar(player: Player, stackId: number)
	-- checking if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	-- Getting inventory:
	local inv: Types.Inventory = InventoryServer.Inventories[player]
	
	-- Removing item from Hotbar:
	for slotKey, equippedId in inv.Hotbar do
		if equippedId == stackId then
			inv.Hotbar[slotKey] = nil
		end
	end
	-- updating Client:
	Signal.FireClient(player, "InventoryClient:update", inv)
end

-- Getting inventory data:
function InventoryServer.getInventoryData(player: Player)
	
	-- Waiting for player's inventory to load:
	while not InventoryServer.Inventories[player] do
		task.wait()
	end
	return InventoryServer.Inventories[player]
	
end

-- Finding stack data from stackId:
function InventoryServer.findStackDataFromStackId(player: Player, stackId: number)
	if stackId == nil then
		return
	end
	
	for i, stackData: Types.StackData in InventoryServer.Inventories[player].Inventory do
		if stackData.StackId == stackId then
			return stackData
		end
	end
end

-- Holding item: 
function InventoryServer.holdItem(player: Player, slotNum: number)
	-- checking if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	-- Getting inventory:
	local inv: Types.Inventory = InventoryServer.Inventories[player]
	local stackData: Types.StackData = nil
	
	-- Finding stack:
	for slotKey: string, stackId: number in inv.Hotbar do
		if slotKey == "Slot".. slotNum then
			stackData = InventoryServer.findStackDataFromStackId(player, stackId)
			break
		end
	end
	
	-- Unholding items:
	InventoryServer.unholdItem(player)
	
	if stackData ~= nil then
		
		-- Equipping first tool in stack:
		local tool: Tool = stackData.Items[1]
		if not player.Character then
			return
		end
		tool.Parent = player.Character
		
		-- Updating Client using signal:
		Signal.FireClient(player, "InventoryClient:update", inv)
	end
	
end

-- unholding item:
function InventoryServer.unholdItem(player: Player)
	-- checking if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	-- Getting inventory:
	local inv: Types.Inventory = InventoryServer.Inventories[player]
	
	-- Unequipping:
	local char: Model = player.Character
	if not char then
		return
	end
	
	local humanoid: Humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end
	
	humanoid:UnequipTools()
	
	-- Updating Client:
	Signal.FireClient(player, "InventoryClient:update", inv)
end

-- Dropping item:
function InventoryServer.dropitem(player: Player, stackId: number)
	
	-- Return if player is respawning:
	if InventoryServer.Respawning[player] then
		return
	end
	
	-- Finding stack data:
	local stackData: Types.StackData = InventoryServer.findStackDataFromStackId(player, stackId)
	if not stackData then
		return
	end
	if not stackData.IsDroppable then
		return false
	end
	
	-- Character variables:
	local char: Model = player.Character
	if not char then
		return
	end
	local rootPart: BasePart = char:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end
	
	-- Dropping first item in list:
	local toolToDrop = stackData.Items[1]
	toolToDrop:PivotTo(rootPart.CFrame * CFrame.new(0,0,-3)) -- drops the item 3 studs in front of the player
	toolToDrop.Parent = workspace
	return true
end

-- Data Saving:
function InventoryServer.saveData(player: Player)
	-- If player has not loaded in yet, return:
	if InventoryServer.HasLoaded[player] ~= true then
		return
	end
	
	print("Saving data for player: " .. player.Name .. " - " .. player.UserId)
	
	local inv: Types.Inventory = InventoryServer.Inventories[player]
	if not inv then
		return
	end
	local modifiedInv = {
		Inventory = {},
		Hotbar = inv.Hotbar,
		NextStackId = inv.NextStackId
	}
	
	for i, stackData: Types.StackData in inv.Inventory do
		table.insert(modifiedInv.Inventory, {
			Name = stackData.Name,
			Count = #stackData.Items,
			StackId = stackData.StackId
		})
	end
	print(modifiedInv)

	local saveString = HttpService:JSONEncode(modifiedInv)
	
	-- Saving:
	local success = false
	local result = nil
	local timeoutTime = 5
	local startTime = os.clock()
	
	while not success do
		
		-- Checking timeout:
		if os.clock() - startTime > timeoutTime then
			print("Unable to save data of ".. player.Name.." - "..player.UserId)
			return
		end
		
		-- Adding pcall to handle potential errors:
		success, result = pcall(function()
			-- Saving player data: 
			InvDataStore:SetAsync(SAVE_KEY:format(player.UserId), saveString)
		end)
		if not success then
			task.wait(1)
		end
		
	end
	
	print("Finished saving data for player: " .. player.Name .. " - " .. player.UserId)
end

-- Data Loading:
function InventoryServer.loadData(player: Player)
	print("Loading data for player: " .. player.Name .. " - " .. player.UserId)
	
	-- Getting player data:
	local saveString = InvDataStore:GetAsync(SAVE_KEY:format(player.UserId))
	if saveString == nil then
		print("No data found for: "..player.Name.." - "..player.UserId)
		InventoryServer.HasLoaded[player] = true
		return
	end
	local savedData = HttpService:JSONDecode(saveString)
	print(savedData)
	
	-- Loading inventory: 
	local inv = {
		Inventory = {},
		Hotbar = savedData.Hotbar,
		NextStackId = savedData.NextStackId
	} 
	local char: Model = player.Character or player.CharacterAdded:Wait()
	local backpack: Backpack = player:WaitForChild("Backpack")
	
	for i, savedStack in savedData.Inventory do
		
		-- Finding item:
		local sample: Tool = ServerStorage.Items:FindFirstChild(savedStack.Name)
		if not sample then
			warn("Item not found: " .. savedStack.Name)
			continue
		end
		
		-- Creating Stack:
		local stack: Types.StackData = {
			Name = savedStack.Name,
			Description = sample.ToolTip,
			Image = sample.TextureId,
			ItemType = sample:GetAttribute("ItemType"),
			IsDroppable = sample:GetAttribute("IsDroppable"),
			Items = {},
			StackId = savedStack.StackId,
			Rarity = sample:GetAttribute("Rarity")
		}
		
		-- Cloning items:
		for i = 1, savedStack.Count do
			local clone: Tool = sample:Clone()
			clone.Parent = backpack
			table.insert(stack.Items, clone)
		end
			
		-- Inserting stack into inventory:
		table.insert(inv.Inventory, stack)
		
	end
	InventoryServer.Inventories[player] = inv
	InventoryServer.HasLoaded[player] = true
	InventoryServer.Janitors[player]:GiveChore(function()
		InventoryServer.HasLoaded[player] = nil
	end)
	
	-- Updating Gui:
	Signal.FireClient(player, "InventoryClient:update", InventoryServer.Inventories[player])
	print("Finished loading data for player: " .. player.Name .. " - " .. player.UserId)
end

return InventoryServer
