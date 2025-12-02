-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

-- Module Imports
-- These are module scripts. (used for re-using and organizing code(object oriented programming))
local modules = ReplicatedStorage.Modules
local CombatManager = require(modules.CombatManager)
local Util = require(modules.Util)
local CONFIG = require(modules.CONFIG)

-- Remote Events
-- They connects client and server scripts.
local eventsFolder = ReplicatedStorage:FindFirstChild("CombatEvents") -- Folder for all remote events

-- locating all remote events:
local Remotes = {
	Attack = eventsFolder.Attack,
	Block = eventsFolder.Block,
	Dodge = eventsFolder.Dodge,
	UpdateStamina = eventsFolder.UpdateStamina,
	UpdateCombo = eventsFolder.UpdateCombo,
	ApplyEffect = eventsFolder.ApplyEffect
}

-- Player Manager Cache
-- Stores CombatManager instances per-player to avoid repeated construction
local PlayerManagers = {}

-- Ensures each player has exactly one CombatManager instance
local function getOrCreateManager(player)
	if not PlayerManagers[player.UserId] then
		PlayerManagers[player.UserId] = CombatManager.new(player) --Constructor
	end
	return PlayerManagers[player.UserId]
end

-- Knockback & Damage Utility

-- Applies knockback based on attack type 
local function applyKnockback(rootPart, sourcePosition, attackType)
	local knockbackForce = attackType == "LightAttack"
		and CONFIG.Knockback.LightAttack
		or CONFIG.Knockback.HeavyAttack

	local direction = (rootPart.Position - sourcePosition).Unit
	local velocity = direction * knockbackForce + Vector3.new(0, 10, 0)

	rootPart.AssemblyLinearVelocity = velocity

	-- Resets velocity after a short duration to avoid drifting
	task.delay(CONFIG.Knockback.Duration, function()
		if rootPart and rootPart.Parent then
			rootPart.AssemblyLinearVelocity = Vector3.zero
		end
	end)
end

-- Calculates reduced damage if the defender is blocking/parrying
local function calculateBlockedDamage(manager, targetManager, baseDamage)
	local blockTime = tick() - targetManager.BlockStartTime

	-- successful parry cancels damage and stuns attacker
	if blockTime <= CONFIG.Block.ParryWindow then
		manager:ApplyStatusEffect("Stun", CONFIG.Block.ParryStunDuration)
		targetManager.Statistics.PerfectParries += 1
		return 0
	end

	-- Standard block = reduced damage + stamina drain on defender
	local finalDamage = baseDamage * (1 - CONFIG.Block.DamageReduction)
	local staminaDrain = finalDamage * CONFIG.Block.StaminaDrainOnBlock

	targetManager:ConsumeStamina(staminaDrain)
	return finalDamage
end

-- Handles all hit functions such as damage application, effects, knockback
local function applyDamageEffects(manager, targetManager, targetParts, finalDamage, attackType, isCritical, attackerPosition)
	if finalDamage <= 0 then
		return
	end

	targetParts.Humanoid:TakeDamage(finalDamage)
	applyKnockback(targetParts.Root, attackerPosition, attackType)

	-- Example heavy attack side-effect (bleed)
	if attackType == "HeavyAttack" and math.random() < 0.3 and targetManager then
		targetManager:ApplyStatusEffect("Bleed", CONFIG.StatusEffects.Bleed.Duration)
	end

	-- Update attacker/defender combat statistics
	if targetManager then
		manager.Statistics.TotalDamageDealt += finalDamage
		manager.Statistics.AttacksLanded += 1
		targetManager.Statistics.TotalDamageTaken += finalDamage
	end

	Util.CreateDamageIndicator(targetParts.Root.Position, finalDamage, isCritical)
end

-- Target Validation
-- Checks if target is a valid character to hit (range, direction, health)
local function isValidTarget(targetCharacter, attackerCharacter, attackerRoot)
	if targetCharacter == attackerCharacter then
		return false
	end

	local targetParts = Util.GetCharacterParts(targetCharacter)
	if not targetParts.Root or not targetParts.Humanoid then
		return false
	end

	if targetParts.Humanoid.Health <= 0 then
		return false
	end

	-- Range check
	--ie, target needs to be in certain range of attacker to take damage.
	local distance = (attackerRoot.Position - targetParts.Root.Position).Magnitude
	if distance > CONFIG.Combat.AttackRange then
		return false
	end

	-- target must be in front of attacker
	if not Util.IsInFront(attackerRoot, targetParts.Root, CONFIG.Combat.AttackAngle) then
		return false
	end

	return true, targetParts
end

-- Attack Processing (Single Target)
-- Evaluates and processes a hit on one target (player or NPC)
local function processSingleTarget(
	targetCharacter,
	targetPlayer,
	attackerCharacter,
	attackerRoot,
	manager,
	baseDamage,
	isCritical,
	attackType,
	hitTargets
)
	if hitTargets[targetCharacter] then
		return false -- ensures each target is only hit once per swing
	end

	local isValid, targetParts = isValidTarget(targetCharacter, attackerCharacter, attackerRoot)
	if not isValid then
		return false
	end

	hitTargets[targetCharacter] = true

	local finalDamage = manager:CalculateDamage(baseDamage, isCritical)

	-- Block/parry handling
	local targetManager = targetPlayer and getOrCreateManager(targetPlayer)
	if targetManager and targetManager.IsBlocking then
		finalDamage = calculateBlockedDamage(manager, targetManager, finalDamage)

		if finalDamage == 0 then
			Util.CreateDamageIndicator(targetParts.Root.Position, 0, false)
			return true
		end
	end

	-- calling applyDamageEffects (function) to actually apply knockback, damages, effects, etc.
	applyDamageEffects(manager, targetManager, targetParts, finalDamage, attackType, isCritical, attackerRoot.Position)

	return true
end

-- Character Identification (Player/NPC)
-- ie, checks if a character is a player or an NPC
local function isPlayerCharacter(model)
	for _, player in Players:GetPlayers() do
		if player.Character == model then
			return true
		end
	end
	return false
end

-- Multi-Target Scan (Players + NPCs)
-- Scans environment for hit targets during a melee attack swing
local function scanForTargets(character, attackerRoot, manager, baseDamage, isCritical, attackType)
	local hitSomething = false
	local hitTargets = {}

	-- Check player targets
	for _, targetPlayer in Players:GetPlayers() do
		if targetPlayer.Character then
			local hit = processSingleTarget(
				targetPlayer.Character,
				targetPlayer,
				character,
				attackerRoot,
				manager,
				baseDamage,
				isCritical,
				attackType,
				hitTargets
			)
			hitSomething = hitSomething or hit
		end
	end

	-- Check NPC/other model targets
	for _, model in workspace:GetDescendants() do
		if not model:IsA("Model") then
			continue
		end
		if model == character then
			continue
		end
		if isPlayerCharacter(model) then
			continue
		end

		local humanoid = model:FindFirstChildOfClass("Humanoid") --locating humanoid in model
		local rootPart = model:FindFirstChild("HumanoidRootPart") --locating humanoidrootpart in model

		if humanoid and rootPart then
			local hit = processSingleTarget(
				model,
				nil,
				character,
				attackerRoot,
				manager,
				baseDamage,
				isCritical,
				attackType,
				hitTargets
			)
			hitSomething = hitSomething or hit
		end
	end

	return hitSomething
end

-- Attack Execution Flow
local function performAttack(attacker, attackType)
	local manager = getOrCreateManager(attacker)

	-- to avoid spamming attacks
	if not manager:ValidateAttack() then
		return
	end

	-- Ensures stamina, status, cooldowns permit this action
	local canPerform, reason = manager:CanPerformAction(attackType)
	if not canPerform then
		return
	end

	local character = attacker.Character
	if not character then
		return
	end

	local parts = Util.GetCharacterParts(character)
	if not parts.Root or not parts.Humanoid then
		return
	end

	manager:ConsumeStamina(CONFIG.Stamina.Costs[attackType])
	manager:SetCooldown(attackType)

	-- Pull correct damage values
	local baseDamage = attackType == "LightAttack"
		and CONFIG.Combat.LightAttackDamage
		or CONFIG.Combat.HeavyAttackDamage

	local isCritical = math.random() < CONFIG.Combat.CriticalChance

	-- Multi-target scan
	local hitSomething = scanForTargets(character, parts.Root, manager, baseDamage, isCritical, attackType)

	-- Combo logic
	if hitSomething then
		manager:IncrementCombo()
	elseif CONFIG.Combo.ComboResetOnMiss then
		manager:ResetCombo()
		manager.Statistics.AttacksMissed += 1
	end
end

-- Blocking
-- player gets no damage if this action is performed.
local function performBlock(player, isBlocking)
	local manager = getOrCreateManager(player)

	if not isBlocking then
		manager.IsBlocking = false
		return
	end

	if not manager:CanPerformAction("Block") then
		return
	end

	manager.IsBlocking = true
	manager.BlockStartTime = tick()
	manager:ConsumeStamina(CONFIG.Stamina.Costs.Block)
end

-- Dodge / Mobility Action
-- player ducks away from attack 
local function performDodge(player)
	local manager = getOrCreateManager(player)

	if not manager:CanPerformAction("Dodge") then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local parts = Util.GetCharacterParts(character)
	if not parts.Root then
		return
	end

	manager:ConsumeStamina(CONFIG.Stamina.Costs.Dodge)
	manager:SetCooldown("Dodge")

	-- Applying a directional velocity burst (speed blitz)
	local dodgeDirection = parts.Root.CFrame.LookVector
	parts.Root.AssemblyLinearVelocity = dodgeDirection * 50

	task.delay(0.2, function()
		if parts.Root and parts.Root.Parent then
			parts.Root.AssemblyLinearVelocity = Vector3.zero
		end
	end)

	manager:ApplyStatusEffect("Dodging", 0.3)
end

-- Remote Event Handlers
-- recieving attack, block, dodge requests from client
Remotes.Attack.OnServerEvent:Connect(function(player, attackType)
	if attackType ~= "LightAttack" and attackType ~= "HeavyAttack" then
		return
	end
	performAttack(player, attackType)
end)

Remotes.Block.OnServerEvent:Connect(function(player, isBlocking)
	performBlock(player, isBlocking)
end)

Remotes.Dodge.OnServerEvent:Connect(function(player)
	performDodge(player)
end)

-- Player Lifecycle
-- gives them combat manager on joining the game
Players.PlayerAdded:Connect(function(player)
	getOrCreateManager(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerManagers[player.UserId] = nil -- cleanup to prevent memory leaks
end)

-- Heartbeat Update Loop (for optimization)
-- handles stamina regen, cooldowns, status effects, etc.

RunService.Heartbeat:Connect(function(deltaTime)
	for _, manager in PlayerManagers do
		manager:Update(deltaTime) -- stamina regen, cooldowns, status effects, etc.
	end
end)
