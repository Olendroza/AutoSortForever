--[[
	Auto Sort Forever

	Sorts your bags automatically about a second after they change. By default
	the sort waits while an interaction menu is open (merchant, mail, bank, etc.),
	but not while only the bag window is open; /asf menu on lets it run in menus.

	How it works:
	- BAG_UPDATE is tracked per bag, so only changes to your own bags count
	  (backpack and the four bag slots). Bank-only updates are ignored.
	- BAG_UPDATE_DELAYED then starts a short delay: loot, purchases, sales,
	  crafting, mail, moving items between slots, equipping or unequipping gear.
	- PLAYER_EQUIPMENT_CHANGED also starts the delay, so swapping to a
	  two-handed weapon (which moves your off-hand item into the bags) triggers
	  a sort even if the total item count stays the same.
	- The sort waits while an interaction menu is open (merchant, mail, bank,
	  auction house, gossip, quest, trade, character pane, game menu); this is
	  the default. With `/asf menu on` it can also run while such a menu is open.
	  Opening only the bag window does not count as a menu. Combat and an item
	  held on the cursor postpone it either way.
	- The bank is sorted right after the banker opens (can be turned off), which
	  is the only moment the client's bank sort API is reliable.
	- The result of SortBags() is checked. A refused sort is retried up to 10
	  times; a temporary blocker (cursor, menu, combat) is waited out without
	  burning those retries, and a sort blocked for 5 minutes is dropped.
	- If the client's own "Clean Up Bags" option is turned off for a bag, that
	  bag is never sorted by the client. The addon reports this on login.
	- Bag updates caused by the addon's own sort are ignored for a moment, so
	  the addon never sorts in a loop.
	- A Lua error inside the addon is caught and printed once in chat, so the
	  addon keeps working and the chat does not fill up with repeats.

	Commands: /asf on | off | status | delay <seconds> | menu on|off | bank on|off
]]

local ADDON = ...

local DEFAULTS = {
	enabled = true,
	delay = 1.0,       -- seconds between a bag change and sorting
	sortBank = true,   -- sort the bank right after the banker opens
	sortInMenu = false, -- also sort while an interaction menu is open (default off)
}

-- Bag updates happening this soon after our own sort are ignored.
local SELF_SORT_GUARD = 1.0

-- Postponed sorts: a temporary blocker (cursor, menu, combat) is waited out
-- without any budget, but a real failure of the sort API is retried at most
-- 10 times. A sort that stays blocked for 5 minutes is dropped.
local RETRY_INTERVAL = 0.5
local MAX_RETRIES = 10
local MAX_PENDING = 300

-- Bank sort: wait a moment for the bank slots to load, then retry on failure.
local BANK_SORT_DELAY = 0.2
local BANK_SORT_RETRY_INTERVAL = 0.5
local BANK_SORT_MAX_RETRIES = 20

-- Bags above this index belong to the bank, not to the player.
local MAX_PLAYER_BAG = NUM_BAG_SLOTS or 4

-- Windows that count as an open menu. Only used when sortInMenu is disabled.
-- Deliberately a fixed list: the global UISpecialFrames is also filled by other
-- addons (chat addons, browsers, options panels), and those never block.
local MENU_FRAMES = {
	"MerchantFrame",
	"MailFrame",
	"BankFrame",
	"AuctionHouseFrame",
	"AuctionFrame", -- older clients
	"GossipFrame",
	"QuestFrame",
	"TradeFrame",
	"CharacterFrame",
	"GameMenuFrame",
}

local db
local checkPending = false
local dirty = false
local failuresLeft = 0
local retryScheduled = false
local pendingSince = 0
local lastSortAt = 0
local playerBagChanged = false
local bankSortAt = 0
local bankSortRetries = 0

local function Print(msg)
	print("|cff33ff99AutoSort Forever|r: " .. msg)
end

--[[ Error reporting ]]

-- Errors caused by this addon are reported in chat, but only once per unique
-- message and only a few times per session, so a repeating fault cannot flood
-- the chat.

local MAX_ERROR_REPORTS = 5
local errorReports = 0
local reportedErrors = {}
local unpack = unpack or table.unpack

local function ReportError(err)
	local text = tostring(err or "unknown error")
	text = text:match("^[^\n]*") or text -- first line only
	if #text > 200 then
		text = text:sub(1, 200) .. "..."
	end
	if reportedErrors[text] then
		return
	end
	reportedErrors[text] = true
	errorReports = errorReports + 1
	if errorReports > MAX_ERROR_REPORTS then
		if errorReports == MAX_ERROR_REPORTS + 1 then
			Print("more errors were suppressed - the full list is in the client's Lua error log.")
		end
		return
	end
	Print("error: " .. text)
end

-- Prints a status message only the first time it appears in this session.
local function PrintOnce(key, msg)
	key = "once:" .. tostring(key)
	if reportedErrors[key] then
		return
	end
	reportedErrors[key] = true
	Print(msg)
end

local function Traceback(err)
	return debug and debug.traceback and debug.traceback(err, 2) or err
end

-- Wraps a callback so that a Lua error inside it becomes a single chat line
-- instead of a silent failure or a broken event handler.
local function Guard(func)
	return function(...)
		local args = { n = select("#", ...), ... }
		local ok, err = xpcall(function()
			return func(unpack(args, 1, args.n))
		end, Traceback)
		if not ok then
			ReportError(err)
		end
	end
end

local function MenuOpen()
	for i = 1, #MENU_FRAMES do
		local frame = _G[MENU_FRAMES[i]]
		if frame and frame.IsShown and frame:IsShown() then
			return true
		end
	end
	return false
end

-- Returns true only when the client confirms the sort.
local function SortBags()
	local api = C_Container and C_Container.SortBags
	if not api then
		return false
	end
	local ok, result = pcall(api)
	return ok and result ~= false
end

-- The client can be told to skip a bag when it cleans up ("Clean Up Bags"
-- turned off in the bag's right-click menu). Skipped slots are never sorted,
-- which looks exactly like the addon doing nothing.
local function ClientCleanupOff()
	local list = {}
	local api = C_Container
	if not api then
		return list
	end
	if api.GetBackpackAutosortDisabled then
		local ok, disabled = pcall(api.GetBackpackAutosortDisabled)
		if ok and disabled then
			list[#list + 1] = "backpack"
		end
	end
	local flag = Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort
	if flag and api.GetBagSlotFlag then
		for bag = 1, MAX_PLAYER_BAG do
			local ok, disabled = pcall(api.GetBagSlotFlag, bag, flag)
			if ok and disabled then
				list[#list + 1] = "bag " .. bag
			end
		end
	end
	return list
end

local TrySort

-- Only one pending retry at a time: several events (menu closed, combat ended,
-- cursor freed) can ask for a retry while a timer is already running.
local function ArmRetry()
	if retryScheduled then
		return
	end
	retryScheduled = true
	C_Timer.After(RETRY_INTERVAL, Guard(function()
		retryScheduled = false
		TrySort()
	end))
end

TrySort = function()
	if not dirty or not db or not db.enabled then
		return
	end
	-- Never sort out of nowhere minutes later.
	if GetTime() - pendingSince > MAX_PENDING then
		dirty = false
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		return -- PLAYER_REGEN_ENABLED calls us again
	end
	if (not db.sortInMenu and MenuOpen()) or GetCursorInfo() then
		-- Blocked by the player or a window: keep waiting, but this does not
		-- count as a failure. This matters with full bags, where an item can
		-- stay on the cursor for a long time.
		ArmRetry()
		return
	end

	lastSortAt = GetTime()
	if SortBags() then
		dirty = false
	elseif failuresLeft > 0 then
		failuresLeft = failuresLeft - 1
		ArmRetry()
	else
		dirty = false
		PrintOnce("sort-refused",
			"the client refused to sort the bags - will try again after the next change.")
	end
end

local function ScheduleSort()
	if checkPending then
		return
	end
	checkPending = true
	C_Timer.After((db and db.delay) or DEFAULTS.delay, Guard(function()
		checkPending = false
		if not db or not db.enabled then
			return
		end
		dirty = true
		failuresLeft = MAX_RETRIES
		pendingSince = GetTime()
		TrySort()
	end))
end

--[[ Bank sorting, right after the banker opens ]]

local TrySortBank

TrySortBank = function()
	if not db or not db.enabled or not db.sortBank then
		return
	end
	-- Stop when the banker has already been closed.
	if BankFrame and BankFrame.IsShown and not BankFrame:IsShown() then
		return
	end
	local api = C_Container and C_Container.SortBankBags
	if not api then
		return
	end
	if GetCursorInfo() then
		if bankSortRetries > 0 then
			bankSortRetries = bankSortRetries - 1
			C_Timer.After(BANK_SORT_RETRY_INTERVAL, Guard(TrySortBank))
		end
		return
	end

	local ok, result = pcall(api)
	if ok and result ~= false then
		return
	end
	if bankSortRetries > 0 then
		bankSortRetries = bankSortRetries - 1
		C_Timer.After(BANK_SORT_RETRY_INTERVAL, Guard(TrySortBank))
	end
end

local function ScheduleBankSort()
	if not db or not db.enabled or not db.sortBank then
		return
	end
	-- Two events usually announce the same banker, sort only once.
	if GetTime() - bankSortAt < 2 then
		return
	end
	bankSortAt = GetTime()
	bankSortRetries = BANK_SORT_MAX_RETRIES
	C_Timer.After(BANK_SORT_DELAY, Guard(TrySortBank))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

-- Everything below only re-tries a postponed sort, except the bank events,
-- which sort the bank when the banker opens.
for _, event in ipairs({
	"PLAYER_REGEN_ENABLED",
	"MERCHANT_CLOSED",
	"MAIL_CLOSED",
	"BANKFRAME_OPENED",
	"BANKFRAME_CLOSED",
	"TRADE_CLOSE",
	"AUCTION_HOUSE_CLOSED",
	"GOSSIP_CLOSED",
	"QUEST_FINISHED",
	"PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
	"PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
}) do
	pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", Guard(function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then
			return
		end

		AutoSortForeverDB = AutoSortForeverDB or {}
		db = AutoSortForeverDB
		for key, value in pairs(DEFAULTS) do
			if db[key] == nil then
				db[key] = value
			end
		end

		-- Repair values from hand-edited or outdated saved variables.
		if type(db.enabled) ~= "boolean" then
			db.enabled = DEFAULTS.enabled
		end
		if type(db.delay) ~= "number" or db.delay < 0.2 or db.delay > 10 then
			db.delay = DEFAULTS.delay
		end
		if type(db.sortBank) ~= "boolean" then
			db.sortBank = DEFAULTS.sortBank
		end
		if type(db.sortInMenu) ~= "boolean" then
			db.sortInMenu = DEFAULTS.sortInMenu
		end

		if not (C_Container and C_Container.SortBags) then
			db.enabled = false
			Print("this client does not support bag sorting - the addon is disabled.")
		else
			local skipped = ClientCleanupOff()
			if #skipped > 0 then
				Print("note: the client's cleanup is off for " .. table.concat(skipped, ", ")
					.. " - the client will not sort those slots. Turn 'Clean Up Bags'"
					.. " back on in the bag's right-click menu.")
			end
		end

		self:UnregisterEvent("ADDON_LOADED")

	elseif event == "BAG_UPDATE" then
		if arg1 and arg1 >= 0 and arg1 <= MAX_PLAYER_BAG then
			playerBagChanged = true
		end

	elseif event == "BAG_UPDATE_DELAYED" then
		local changed = playerBagChanged
		playerBagChanged = false
		if not changed or not db or not db.enabled then
			return
		end
		if GetTime() - lastSortAt < SELF_SORT_GUARD then
			return
		end
		ScheduleSort()

	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if db and db.enabled then
			ScheduleSort()
		end

	elseif event == "BANKFRAME_OPENED" then
		ScheduleBankSort()

	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		local pit = Enum and Enum.PlayerInteractionType
		if pit and arg1 == pit.Banker then
			ScheduleBankSort()
		end

	else
		failuresLeft = MAX_RETRIES
		pendingSince = GetTime()
		TrySort()
	end
end))

--[[ Commands ]]

local function SetEnabled(state)
	if not db then
		return
	end
	db.enabled = state
	if state then
		Print(("enabled - sorting %.1f s after a bag change."):format(db.delay))
	else
		Print("disabled.")
	end
end

SLASH_AUTOSORTFOREVER1 = "/asf"
SLASH_AUTOSORTFOREVER2 = "/autosort"
SlashCmdList["AUTOSORTFOREVER"] = Guard(function(msg)
	if not db then
		Print("the addon has not loaded yet, please try again.")
		return
	end

	msg = (msg or ""):lower():match("^%s*(.-)%s*$")

	if msg == "" or msg == "status" then
		local skipped = ClientCleanupOff()
		Print(("enabled: %s | delay: %.1f s | sort bank: %s | sort in menu: %s"):format(
			db.enabled and "yes" or "no",
			db.delay,
			db.sortBank and "yes" or "no",
			db.sortInMenu and "yes" or "no")
			.. (#skipped > 0 and (" | client cleanup off for: " .. table.concat(skipped, ", ")) or ""))

	elseif msg == "menu on" then
		db.sortInMenu = true
		Print("sorting while a menu is open: enabled.")

	elseif msg == "menu off" then
		db.sortInMenu = false
		Print("sorting while a menu is open: disabled - sorting waits until the menu is closed.")

	elseif msg == "bank on" then
		db.sortBank = true
		Print("sorting the bank when the banker opens: enabled.")

	elseif msg == "bank off" then
		db.sortBank = false
		Print("sorting the bank when the banker opens: disabled.")

	elseif msg == "on" then
		SetEnabled(true)

	elseif msg == "off" then
		SetEnabled(false)

	elseif msg:match("^delay%s+") then
		local value = tonumber(msg:match("^delay%s+([%d%.]+)$"))
		if value and value >= 0.2 and value <= 10 then
			db.delay = value
			Print(("delay set to %.1f s."):format(value))
		else
			Print("usage: /asf delay 1.0  (allowed range: 0.2 - 10)")
		end

	else
		Print("usage: /asf on | off | status | delay <seconds> | menu on|off | bank on|off")
	end
end)
