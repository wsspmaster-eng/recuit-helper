local effil = require('effil')
local imgui = require 'mimgui'
local ffi = require 'ffi'
local sampev = require 'samp.events'
local encoding = require 'encoding'
encoding.default = "CP1251"
local u8 = encoding.UTF8

local fa_status, faicons = pcall(require, 'fAwesome6')
local inicfg = require 'inicfg'
local vkeys = require 'vkeys'

local new = imgui.new
local win_state = new.bool(false)
local settings_window = new.bool(false)
local show_cursor_state = new.bool(false)
local hidden_window = new.bool(false)
local is_first_open = true

local saved_size = imgui.ImVec2(400, 500)

local daily = {}
local premium = {}
local quests = {}
local premiumBP = false
local bUpdateCache = true
local cached_list = {}

local bool_pool = {}
local bool_pool_index = 1

local function restoreGameState()
    displayRadar(true)
    displayHud(true)
    sampSetCursorMode(0)
end

local function resetBoolPool()
    bool_pool_index = 1
end

local configPath = 'config/mimgui/BP.lua.ini'
local config = inicfg.load({
    settings = {
        cursor_key = 18,
        show_instructions = true,
        transparent_mode_key = 116,
        enable_transparency = true
    },
    hidden_quests = {}
}, configPath)

local settings = {
    cursor_key = new.int(config.settings.cursor_key),
    show_instructions = new.bool(config.settings.show_instructions),
    transparent_mode_key = new.int(config.settings.transparent_mode_key),
    enable_transparency = new.bool(config.settings.enable_transparency),
    waiting_for_key = new.bool(false),
    key_mode = new.int(0)
}

local silent_update_active = false
local silent_phase = 0 

function requestBPDataSilently()
    if silent_update_active then
        sampAddChatMessage("{FF6347}[BP Helper] {FFFFFF}Îáíîâëåíèå óæå èäåò", -1)
        return
    end
    
    silent_update_active = true
    silent_phase = 1
    
    lua_thread.create(function()
        sampSendChat('/battlepass')
        local wait_time = 0
        
        while silent_phase == 1 and wait_time < 50 do
            wait(100)
            wait_time = wait_time + 1
        end
        
        wait(300)
        
        while isKeyDown(settings.cursor_key[0]) do
            wait(10)
        end
        
        setVirtualKeyDown(0x1B, true)
        wait(50)
        setVirtualKeyDown(0x1B, false)
        
        wait(300)
        
        silent_update_active = false
        silent_phase = 0
        restoreGameState()
    end)
end

local function getNewBool(default_value)
    if not bool_pool[bool_pool_index] then
        bool_pool[bool_pool_index] = new.bool(default_value or false)
    else
        bool_pool[bool_pool_index][0] = default_value or false
    end
    local result = bool_pool[bool_pool_index]
    bool_pool_index = bool_pool_index + 1
    return result
end

local function getIcon(name)
    if not fa_status then return "?" end
    return faicons(name)
end

local function saveConfig()
    config.settings.cursor_key = settings.cursor_key[0]
    config.settings.show_instructions = settings.show_instructions[0]
    config.settings.transparent_mode_key = settings.transparent_mode_key[0]
    config.settings.enable_transparency = settings.enable_transparency[0]
    
    config.hidden_quests = {}
    for _, quest in ipairs(quests) do
        if not quest.show[0] then
            local quest_key = string.format("%s_%s", quest.categoryId, quest.id)
            config.hidden_quests[quest_key] = true
        end
    end
    
    inicfg.save(config, configPath)
    bUpdateCache = true
end

local function threadHandle(runner, url, args, resolve, reject)
    local t = runner(url, args)
    local r = t:get(0)
    while not r do
        r = t:get(0)
        wait(0)
    end
    local status = t:status()
    if status == 'completed' then
        local ok, result = r[1], r[2]
        if ok then resolve(result) else reject(result) end
    elseif status == 'canceled' then
        reject(status)
    end
    t:cancel(0)
end

local function requestRunner()
    return effil.thread(function(u, a)
        local https = require 'ssl.https'
        local ok, result = pcall(https.request, u, a)
        return {ok, result}
    end)
end

local function async_http_request(url, args, resolve, reject)
    local runner = requestRunner()
    if not reject then reject = function() end end
    lua_thread.create(function()
        threadHandle(runner, url, args, resolve, reject)
    end)
end

local function getBattlepassContent(key)
    local requestURL = ('https://reserve-server-api.arizona.games/client/json/table/get?project=arizona&server=1&key=%s'):format(key)
    async_http_request(requestURL, nil, function(result)
        if result then
            local status, decoded = pcall(decodeJson, u8:decode(result))
            if status and decoded then
                if key == 'battlepass_mission_default' then daily = decoded
                elseif key == 'battlepass_mission_premium' then premium = decoded end
            end
        end
    end)
end

local function apply_custom_style()
    local style = imgui.GetStyle()
    style.WindowRounding = 8.0
    style.ChildRounding = 6.0
    style.FrameRounding = 5.0
    style.ItemSpacing = imgui.ImVec2(8, 6)
    style.WindowPadding = imgui.ImVec2(10, 10)
    
    local clr = imgui.Col
    local ImVec4 = imgui.ImVec4
    style.Colors[clr.WindowBg] = ImVec4(0.12, 0.12, 0.14, 0.98)
    style.Colors[clr.FrameBg]  = ImVec4(0.18, 0.18, 0.20, 1.00)
    style.Colors[clr.Button]   = ImVec4(0.20, 0.20, 0.23, 1.00)
    style.Colors[clr.Header]   = ImVec4(0.22, 0.22, 0.25, 1.00)
end

imgui.OnInitialize(function()
    local configF = imgui.ImFontConfig()
    configF.MergeMode = true
    if fa_status then
        local iconRanges = new.ImWchar[3](faicons.min_range, faicons.max_range, 0)
        imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(faicons.get_font_data_base85('solid'), 14, configF, iconRanges)
    end
    apply_custom_style()
end)

local function updateQuestsCache()
    if not bUpdateCache then return end
    
    cached_list = {}
    local pinned = {}
    local active = {}

    for _, quest in ipairs(quests) do
        if not quest.progress and quest.show[0] then
            if quest.pinned[0] then
                table.insert(pinned, quest)
            else
                table.insert(active, quest)
            end
        end
    end
    
    for _, q in ipairs(pinned) do table.insert(cached_list, q) end
    for _, q in ipairs(active) do table.insert(cached_list, q) end

    bUpdateCache = false
end

local function drawQuestCard(quest, is_active)
    local style = imgui.GetStyle()
    local displayText = quest.text
    local quest_progress = (quest.max > 1) and (quest.curr / quest.max) or 0
    
    if quest.max > 1 then
        displayText = string.format("%s (%d/%d) - %d%%", quest.text, quest.curr, quest.max, math.floor(quest_progress * 100))
    end
    
    local draw_list = imgui.GetWindowDrawList()
    local availWidth = imgui.GetContentRegionAvail().x
    
    -- Âûäåëÿåì ìåñòî ïîä êíîïêè òîëüêî åñëè çàæàò Alt (èëè àêòèâíî ìåíþ)
    local buttonsAreaWidth = is_active and 60 or 0 
    local textWidth = availWidth - buttonsAreaWidth
    
    local text_color = style.Colors[imgui.Col.Text]
    local accent_color = imgui.ImVec4(0.25, 0.25, 0.28, 1.0)

    if quest.pinned[0] then
        accent_color = imgui.ImVec4(1.0, 0.75, 0.0, 1.0)
    end

    local startPos = imgui.GetCursorPos()
    local p = imgui.GetCursorScreenPos()

    imgui.BeginGroup()
        -- Òåêñò âûâîäèòñÿ ÂÑÅÃÄÀ
        imgui.PushStyleColor(imgui.Col.Text, text_color)
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + textWidth)
        imgui.Text(displayText)
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
        
        -- Ïðîãðåññ-áàð âûâîäèòñÿ ÂÑÅÃÄÀ (åñëè îí åñòü ó çàäàíèÿ)
        if quest.max > 1 and quest_progress > 0 then
            imgui.PushStyleColor(imgui.Col.PlotHistogram, imgui.ImVec4(0.26, 0.59, 0.98, 0.8))
            imgui.ProgressBar(quest_progress, imgui.ImVec2(textWidth - 10, 3), "")
            imgui.PopStyleColor()
        end
        
        local textHeight = imgui.GetItemRectSize().y
        local finalHeight = math.max(textHeight, is_active and 28 or 0)

        -- Êíîïêè ðèñóþòñÿ ÒÎËÜÊÎ â àêòèâíîì ðåæèìå
        if is_active then
            imgui.SetCursorPos(imgui.ImVec2(imgui.GetWindowContentRegionMax().x - buttonsAreaWidth, startPos.y))
            
            if quest.pinned[0] then
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.6, 0.5, 0.1, 0.5))
            else
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 0.3))
            end
            if imgui.Button(getIcon('thumbtack') .. "##pin_" .. quest.id, imgui.ImVec2(24, 24)) then
                quest.pinned[0] = not quest.pinned[0]
                bUpdateCache = true
            end
            imgui.PopStyleColor()

            imgui.SameLine()
            
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.7, 0.2, 0.2, 0.4))
            if imgui.Button("X##del_" .. quest.id, imgui.ImVec2(24, 24)) then
                quest.show[0] = false
                saveConfig()
                bUpdateCache = true
            end
            imgui.PopStyleColor()
        end

        -- Âåðòèêàëüíàÿ öâåòíàÿ ëèíèÿ-ìàðêåð ñëåâà
        local col_u32 = imgui.ColorConvertFloat4ToU32(accent_color)
        -- Äèíàìè÷åñêè ðàññ÷èòûâàåì âûñîòó ëèíèè â çàâèñèìîñòè îò íàëè÷èÿ êíîïîê è ïðîãðåññ-áàðà
        local line_height = is_active and math.max(textHeight, 28) or (textHeight + (quest_progress > 0 and 6 or 0))
        draw_list:AddRectFilled(imgui.ImVec2(p.x - 5, p.y), imgui.ImVec2(p.x - 2, p.y + line_height), col_u32)
        
        -- Âûðàâíèâàåì îòñòóïû
        if is_active and textHeight < 28 then imgui.SetCursorPosY(startPos.y + 28) end
    imgui.EndGroup()
    
    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))
end

function main()
    while not isSampAvailable() do wait(100) end
    sampAddChatMessage("{32CD32}[BP Helper] {FFFFFF}Çàãðóæåí. Êîìàíäà: /bph", -1)

    getBattlepassContent('battlepass_mission_default')
    getBattlepassContent('battlepass_mission_premium')

    sampRegisterChatCommand('bph', function ()
        win_state[0] = not win_state[0]
        if win_state[0] and is_first_open then
            is_first_open = false
            requestBPDataSilently()
        end
    end)
    
    while true do
        wait(0)
        if win_state[0] and isKeyJustPressed(settings.transparent_mode_key[0]) then
            show_cursor_state[0] = not show_cursor_state[0]
        end
    end
end

imgui.OnFrame(function() return win_state[0] end, function(player)
    updateQuestsCache()

    local is_active = show_cursor_state[0]
    local is_cursor_key_pressed = isKeyDown(settings.cursor_key[0])
    local show_interface = is_active or is_cursor_key_pressed
    local style = imgui.GetStyle()
    
    local alpha = 0.98
    if not show_interface and settings.enable_transparency[0] then
        alpha = 0.65
    end
    style.Colors[imgui.Col.WindowBg].w = alpha
    style.Colors[imgui.Col.Text].w = show_interface and 1.0 or 0.9

    local win_flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
    if show_interface then
        player.HideCursor = false
        imgui.SetNextWindowSize(saved_size, imgui.Cond.FirstUseEver)
    else
        player.HideCursor = not sampIsCursorActive()
        imgui.GetIO().WantCaptureMouse = false
        imgui.SetNextWindowSize(saved_size, imgui.Cond.Always)
        win_flags = win_flags + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoFocusOnAppearing
    end
    
    if imgui.Begin(u8'BP_Main_Window', win_state, win_flags) then
        if show_interface then saved_size = imgui.GetWindowSize() end
        
        if show_interface then
            if imgui.Button(getIcon('eye-slash') .. u8" Ñêðûòûå çàäàíèÿ", imgui.ImVec2(-1, 25)) then hidden_window[0] = true end
            if imgui.Button(getIcon('rotate') .. u8" Îáíîâèòü", imgui.ImVec2(-1, 25)) then requestBPDataSilently() end
            if imgui.Button(getIcon('gear') .. u8" Íàñòðîéêè", imgui.ImVec2(-1, 25)) then settings_window[0] = true end
            imgui.Spacing()
        end
        
        imgui.BeginChild("QuestsList", imgui.ImVec2(0, 0), true)
            if #cached_list == 0 then
                imgui.TextWrapped(u8"Íåò àêòèâíûõ çàäàíèé. Âûïîëíèòå ñòàðûå èëè îòêðîéòå ìåíþ BP.")
            else
                for i, quest in ipairs(cached_list) do
                    imgui.PushIDInt(i)
                    drawQuestCard(quest, show_interface)
                    imgui.PopID()
                end
            end
        imgui.EndChild()
        imgui.End()
    end
end)

imgui.OnFrame(function() return settings_window[0] end, function(player)
    player.HideCursor = false
    
    local io = imgui.GetIO()
    imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    
    local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar
    if imgui.Begin(u8'BP_Settings_Window', settings_window, flags) then
        imgui.Text(getIcon('gear') .. u8' BP Helper - Íàñòðîéêè')
        imgui.Separator()
        imgui.Spacing()
        
        imgui.Text(u8"Êëàâèøà äëÿ êóðñîðà:")
        imgui.SameLine()
        
        local key_name = vkeys.id_to_name(settings.cursor_key[0]) or "Unknown"
        
        local btn_text = settings.waiting_for_key[0] and "..." or u8(key_name)
        if imgui.Button(btn_text .. "##cursor", imgui.ImVec2(130, 25)) then
            settings.waiting_for_key[0] = true
        end
        
        if imgui.Checkbox(u8"Ïðîçðà÷íûé ôîí â ïàññèâíîì ðåæèìå", settings.enable_transparency) then
            saveConfig()
        end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        if imgui.Button(u8"Çàêðûòü", imgui.ImVec2(-1, 30)) then
            settings_window[0] = false
            settings.waiting_for_key[0] = false
        end
        
        imgui.End()
    end
    
    if settings.waiting_for_key[0] then
        for i = 3, 255 do
            if imgui.IsKeyPressed(i) then
                settings.cursor_key[0] = i
                settings.waiting_for_key[0] = false
                saveConfig()
                sampAddChatMessage("{32CD32}[BP Helper] {FFFFFF}Êëàâèøà êóðñîðà óñïåøíî èçìåíåíà!", -1)
                break
            end
        end
    end
end)

imgui.OnFrame(function() return hidden_window[0] end, function(player)
    player.HideCursor = false
    imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
    if imgui.Begin(u8'Ñêðûòûå çàäàíèÿ', hidden_window) then
        for _, quest in ipairs(quests) do
            if not quest.show[0] then
                imgui.Text(quest.text)
                imgui.SameLine(imgui.GetWindowWidth() - 100)
                if imgui.Button(u8"Âåðíóòü##"..quest.id) then
                    quest.show[0] = true
                    saveConfig()
                    bUpdateCache = true
                end
                imgui.Separator()
            end
        end
        imgui.End()
    end
end)

function sampev.onServerMessage(color, text)
    local clean_text = text:gsub("{%x%x%x%x%x%x}", "")
    
    if clean_text:find("%[Áîåâîé Ïðîïóñê%] Âû óñïåøíî âûïîëíèëè çàäàíèå") then
        local result = clean_text:match("'(.-)'")
        if result then
            result = u8(result)
            for _, quest in ipairs(quests) do
                if quest.title and quest.title == result then
                    quest.progress = true
                    quest.pinned[0] = false
                    quest.curr = quest.max
                    bUpdateCache = true 
                    break
                end
            end
        end
    end
end

addEventHandler('onReceivePacket', function(id, bs)
    if id == 220 then
        raknetBitStreamIgnoreBits(bs, 8)
        if (raknetBitStreamReadInt8(bs) == 17) then
            raknetBitStreamIgnoreBits(bs, 32)
            local length = raknetBitStreamReadInt16(bs)
            local encoded = raknetBitStreamReadInt8(bs)
            local str = (encoded ~= 0) and raknetBitStreamDecodeString(bs, length + encoded) or raknetBitStreamReadString(bs, length)
            
            if str:find("event.battlePass.initializeBattlePassData") then
                local battlePassData = str:match("`(.+)`")
                if battlePassData then
                    local status, battlePassDataParsed = pcall(decodeJson, battlePassData)
                    if status and type(battlePassDataParsed) == "table" and battlePassDataParsed[1] and battlePassDataParsed[1].premium ~= 0 then
                        premiumBP = true
                    end
                end
                
                if silent_update_active or #quests == 0 then
                    resetBoolPool()
                    quests = {}
                end
                if silent_phase == 1 then silent_phase = 2 end
                
            elseif str:find("event.battlePass.updateQuestsProgress") then
                local innerList = string.match(str, "%[%[(.-)%]%]")
                if innerList then
                    innerList = "[" .. innerList .. "]"
                    local status, data = pcall(decodeJson, innerList)
                    if status and type(data) == "table" then
                        for i, item in ipairs(data) do
                            local source = (item.categoryId == "daily" and daily) or (item.categoryId == "premium" and premiumBP and premium) or nil
                            if source then
                                local function findItemById(array, id)
                                    for _, it in ipairs(array) do if it.id == id then return it end end
                                end
                                local matchedItem = findItemById(source, item.id)
                                if matchedItem then
                                    local function updateQuest(target, itemData)
                                        for _, q in ipairs(quests) do
                                            if q.id == target.id and q.categoryId == target.categoryId then
                                                q.progress = itemData.progress >= target.totalProgress
                                                q.curr = itemData.progress
                                                return true
                                            end
                                        end
                                        return false
                                    end
                                    
                                    if not updateQuest(matchedItem, item) then
                                        local quest_key = string.format("%s_%s", matchedItem.categoryId, matchedItem.id)
                                        table.insert(quests, {
                                            id = matchedItem.id,
                                            categoryId = matchedItem.categoryId,
                                            text = u8(matchedItem.description),
                                            title = u8(matchedItem.title),
                                            progress = item.progress >= matchedItem.totalProgress,
                                            curr = item.progress,
                                            max = matchedItem.totalProgress,
                                            show = getNewBool(not config.hidden_quests[quest_key]),
                                            pinned = getNewBool(false)
                                        })
                                    end
                                end
                            end
                        end
                        bUpdateCache = true
                    end
                end
                if silent_phase == 1 then silent_phase = 2 end
            end
        end
        raknetBitStreamResetReadPointer(bs) 
    end
    return true
end)


