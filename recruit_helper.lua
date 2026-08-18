script_name('Recruit Helper')
script_author('OpenAI')
script_version('6.7')
script_description('Recruit Helper 6.7: призыв + Auto VOiS, безопасный CEF, ручное RP-собеседование и /inv. + Anime')

require 'lib.moonloader'
require 'lib.sampfuncs'

local sampev = require 'lib.samp.events'
local vkeys = require 'vkeys'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local moonOk, moon = pcall(require, 'moonloader')
local dlstatus = moonOk and moon.download_status or nil

-- ============================================================================
-- НАСТРОЙКИ
-- ============================================================================
local CONFIG = {
    nearDistance = 6.0,           
    frontDot = 0.25,              
    autoAcceptOffer = true,       
    autoSwitchDocumentPages = true,
    autoInvite = true,            
    outboundDelayMs = 3000,      
    chatDelayMs = 3000,          
    retryQuestionDelayMs = 5000, 
    hotkeyAltN = true,            
    debug = true,
    fileLog = true,              
    packetLog = false,            
    packetLogLimit = 40,          
    maxCefPayloadBytes = 65536,   
    maxOutboundQueue = 120,       
    maxScheduledActions = 120,    
    gcIntervalMs = 60000,         
    healthLogIntervalMs = 600000, 
    maxCandidateMessageBytes = 92, 
    checkRpNicknameOnline = true, 
    strictRpNicknameOnline = false, 
    blockBadNicknameFormat = true,  
    nicknameCheckTimeoutMs = 6000,
    interviewHud = true,          
    interviewHudFontSize = 10,
    manualInterview = true,       
    manualProfessionalCheck = false, 

    updateManifestUrl = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/version.txt',
    updateScriptUrl = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/recruit_helper.lua',
    updateAssets = {
        {
            name = 'fart.mp3',
            url = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/moonloader/hit_warnings/fart.mp3',
            relativePath = 'hit-warnings\\fart.mp3',
        },
        {
            name = 'warning.mp3',
            url = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/moonloader/hit_warnings/warning.mp3',
            relativePath = 'hit-warnings\\warning.mp3',
        },
        {
            name = 'general.mp3',
            url = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/moonloader/hit_warnings/general.mp3',
            relativePath = 'hit-warnings\\general.mp3',
        },
    },
    updateCheckOnStart = true,    

    -- Автобиндер.
    autoBinderEnabled = true,          
    discordBinderEnabled = true,       
    discordBinderIntervalMs = 3600000, 
    autoBinderRetryMs = 60000,         
    discordFirstDelayMs = 3600000,     
}

local PREFIX = '{84D7FF}[Recruit]{FFFFFF} '

local updateInProgress = false

local session = {
    active = false,
    stage = 'idle',
    targetId = nil,
    targetName = nil,
    deadline = 0,
    answers = {},
    q2Retry = false,
    q2Term = nil,
    q2FirstTermCode = nil,
    rpMenuChoices = {},
    rpAsked = {},
    rpCurrent = nil,
    warnedDocs = false,
    warnedPage2 = false,
    warnedPage4 = false,
    lastSpeechBody = nil,
    lastSpeechAt = 0,
    packetCount = 0,
    testMode = false,
    nickCheck = nil,
    docs = nil,
}

local function cp(text)
    return u8:decode(text)
end

local CREATOR_WARN_COOLDOWN = 0
local protectedHitAudio = nil
local klaksonDisabled = false

local PROTECTED_HIT_TARGETS = {
    Suleyman_Kanuni = {
        sound = 'warning.mp3',
        message = 'Не трогай меня сука!!',
        color = 0xFF4444,
    },
    Bruce_Tayson = {
        sound = 'fart.mp3',
        message = 'НЕ ТРОГАЙ РУКАМИ! РУКИ ИСПАЧКАЕШЬ В КАКАШКАХ!!!!!',
        color = 0xFF4444,
    },
    Jensen_Ackles = {
        sound = 'general.mp3',
        message = 'Не бей крутого генерала, чмо!!',
        color = 0xFFCC44,
    },
}

local function protectedHitSoundPath(fileName)
    local thisPath = thisScript() and thisScript().path or ''
    local base = thisPath:match('^(.*[\\/])')

    if not base or base == '' then
        base = tostring(getWorkingDirectory() or '')
        if base:sub(-1) ~= '\\' and base:sub(-1) ~= '/' then
            base = base .. '\\'
        end
    end

    return base .. 'hit-warnings\\' .. tostring(fileName or '')
end

local function playProtectedHitSound(fileName)
    local path = protectedHitSoundPath(fileName)
    if type(doesFileExist) == 'function' and not doesFileExist(path) then
        return false
    end
    if type(loadAudioStream) ~= 'function' or type(setAudioStreamState) ~= 'function' then
        return false
    end

    local ok = pcall(function()
        if protectedHitAudio and type(releaseAudioStream) == 'function' then
            pcall(releaseAudioStream, protectedHitAudio)
            protectedHitAudio = nil
        end

        protectedHitAudio = loadAudioStream(path)
        if not protectedHitAudio then
            error('loadAudioStream failed')
        end

        if type(setAudioStreamVolume) == 'function' then
            pcall(setAudioStreamVolume, protectedHitAudio, 1.0)
        end
        setAudioStreamState(protectedHitAudio, 1)
    end)

    return ok
end

local function checkProtectedHit(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end

    local now = os.clock() * 1000
    if type(getGameTimer) == 'function' then
        local okTimer, gameTimer = pcall(getGameTimer)
        if okTimer and type(gameTimer) == 'number' then now = gameTimer end
    end
    if now - CREATOR_WARN_COOLDOWN < 1500 then
        return
    end

    local nick = sampGetPlayerNickname(playerId)
    if not nick then return end

    local target = PROTECTED_HIT_TARGETS[nick]
    if not target then return end

    CREATOR_WARN_COOLDOWN = now

    if nick == 'Jensen_Ackles' and klaksonDisabled then
        if target.message then
            sampAddChatMessage(cp(target.message), target.color or 0xFFCC44)
        end
        return
    end

    if target.message then
        sampAddChatMessage(cp(target.message), target.color or 0xFFCC44)
    end

    if not playProtectedHitSound(target.sound) then
        pcall(function()
            sampPlaySound(1085, 0, 0)
        end)
    end
end

local function consoleIsValidUtf8(text)
    text = tostring(text or '')
    local i, n = 1, #text

    while i <= n do
        local b1 = text:byte(i)
        if b1 < 0x80 then i = i + 1
        elseif b1 >= 0xC2 and b1 <= 0xDF then
            local b2 = text:byte(i + 1)
            if not b2 or b2 < 0x80 or b2 > 0xBF then return false end
            i = i + 2
        elseif b1 >= 0xE0 and b1 <= 0xEF then
            local b2, b3 = text:byte(i + 1), text:byte(i + 2)
            if not b2 or not b3 then return false end
            if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
            if b1 == 0xE0 and b2 < 0xA0 then return false end
            if b1 == 0xED and b2 > 0x9F then return false end
            i = i + 3
        elseif b1 >= 0xF0 and b1 <= 0xF4 then
            local b2, b3, b4 = text:byte(i + 1), text:byte(i + 2), text:byte(i + 3)
            if not b2 or not b3 or not b4 then return false end
            if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
            if b1 == 0xF0 and b2 < 0x90 then return false end
            if b1 == 0xF4 and b2 > 0x8F then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

local function consoleText(text)
    text = tostring(text or '')
    if consoleIsValidUtf8(text) then
        local ok, converted = pcall(cp, text)
        if ok and type(converted) == 'string' then return converted end
    end
    return text
end

local function consolePrint(text)
    local value = consoleText(text)
    pcall(print, value)
end

local function chatInfo(text)
    sampAddChatMessage(PREFIX .. cp(text), -1)
end

local function getDebugLogPath()
    local path = thisScript() and thisScript().path or ''
    local folder = path:match('^(.*\\)') or path:match('^(.*/)') or ''
    return folder .. 'recruit_assistant_debug.log'
end

local function debugLog(text)
    if not CONFIG.debug then return end
    local line = os.date('[%Y-%m-%d %H:%M:%S] ') .. tostring(text)
    consolePrint('[Recruit Assistant] ' .. tostring(text))
    if CONFIG.fileLog then
        local file = io.open(getDebugLogPath(), 'a')
        if file then
            file:write(line, '\n')
            file:close()
        end
    end
end

local function stripColors(text)
    return (tostring(text or ''):gsub('{[%x]+}', ''))
end

local function trim(text)
    return (tostring(text or ''):match('^%s*(.-)%s*$'))
end

local function ruLower(text)
    return (tostring(text or ''):gsub('.', function(ch)
        local byte = ch:byte()
        if byte >= 0xC0 and byte <= 0xDF then return string.char(byte + 0x20)
        elseif byte == 0xA8 then return string.char(0xB8)
        elseif byte >= 0x41 and byte <= 0x5A then return string.char(byte + 0x20)
        end
        return ch
    end))
end

local function splitWords(text)
    local cleaned = ruLower(trim(text)):gsub('[%p%c]+', ' ')
    local words = {}
    for word in cleaned:gmatch('%S+') do words[#words + 1] = word end
    return words
end

local function hasWord(text, expected)
    for _, word in ipairs(splitWords(text)) do
        if word == expected then return true end
    end
    return false
end

local outboundQueue = {}
local outboundNextSendAt = 0
local scheduledActions = {}

-- ОПТИМИЗАЦИЯ: Разрешаем вызов таймера без pcall, так как это снижает нагрузку на CPU
local sysGetTimer = type(getGameTimer) == 'function' and getGameTimer or function() return math.floor(os.clock() * 1000) end
local function nowMs()
    return sysGetTimer()
end

local function scheduleAction(delayMs, fn)
    if type(fn) ~= 'function' then return false end
    local limit = tonumber(CONFIG.maxScheduledActions) or 120
    if #scheduledActions >= limit then
        debugLog('Scheduled action rejected: queue limit ' .. tostring(limit) .. ' reached.')
        return false
    end
    scheduledActions[#scheduledActions + 1] = {
        at = nowMs() + math.max(0, tonumber(delayMs) or 0),
        fn = fn,
    }
    return true
end

local function processScheduledActions()
    if #scheduledActions == 0 then return end
    local now = nowMs()
    local i = 1
    while i <= #scheduledActions do
        local action = scheduledActions[i]
        if now >= action.at then
            table.remove(scheduledActions, i)
            local ok, err = pcall(action.fn)
            if not ok then debugLog('Scheduled action failed: ' .. tostring(err)) end
        else
            i = i + 1
        end
    end
end

local function enqueueOutbound(text, kind, testModeSnapshot, testSuffix, onSent)
    if type(text) ~= 'string' or text == '' then return false end
    local limit = tonumber(CONFIG.maxOutboundQueue) or 120
    if #outboundQueue >= limit then
        debugLog('Outbound item rejected: queue limit ' .. tostring(limit) .. ' reached. text=' .. tostring(text))
        return false
    end
    outboundQueue[#outboundQueue + 1] = {
        text = text,
        kind = kind or 'message',
        testMode = testModeSnapshot == true,
        testSuffix = testSuffix,
        onSent = onSent,
    }
    return true
end

local function processOutboundQueue()
    if #outboundQueue == 0 then return end
    local now = nowMs()
    if now < outboundNextSendAt then return end
    local item = table.remove(outboundQueue, 1)
    local ok, err = pcall(function()
        if item.testMode then
            if item.kind == 'local_command' then chatInfo('[TEST локальная команда] ' .. item.text .. (item.testSuffix or ''))
            elseif item.kind == 'command' then chatInfo('[TEST команда] ' .. item.text .. (item.testSuffix or ''))
            else chatInfo('[TEST -> кандидату] ' .. item.text) end
        else
            if item.kind == 'local_command' then sampProcessChatInput(item.text)
            elseif item.kind == 'command' then sampSendChat(item.text)
            else sampSendChat(cp(item.text)) end
        end
    end)
    outboundNextSendAt = now + (tonumber(CONFIG.outboundDelayMs) or 3000)
    if not ok then debugLog('Outbound send failed: ' .. tostring(err)) end
    if type(item.onSent) == 'function' then
        local callbackOk, callbackErr = pcall(item.onSent)
        if not callbackOk then debugLog('Outbound callback failed: ' .. tostring(callbackErr)) end
    end
end

local lastGcStepAt = 0
local lastHealthLogAt = 0

local function processMaintenance()
    local interval = tonumber(CONFIG.gcIntervalMs) or 60000
    local now = nowMs()
    if lastGcStepAt == 0 or now < lastGcStepAt or now - lastGcStepAt >= interval then
        lastGcStepAt = now
        local ok, err = pcall(function() collectgarbage('step', 200) end)
        if not ok then debugLog('GC step failed: ' .. tostring(err)) end
    end

    local healthInterval = tonumber(CONFIG.healthLogIntervalMs) or 600000
    if lastHealthLogAt == 0 or now < lastHealthLogAt or now - lastHealthLogAt >= healthInterval then
        lastHealthLogAt = now
        local memoryKb = 0
        local okMemory, value = pcall(function() return collectgarbage('count') end)
        if okMemory and type(value) == 'number' then memoryKb = math.floor(value) end
        debugLog('Health: luaKB=' .. tostring(memoryKb) .. ', outbound=' .. tostring(#outboundQueue) .. ', scheduled=' .. tostring(#scheduledActions) .. ', recruit=' .. tostring(session and session.stage or 'n/a'))
    end
end

local function outboundEncodedLength(text)
    local ok, converted = pcall(cp, tostring(text or ''))
    if ok and type(converted) == 'string' then return #converted end
    return #tostring(text or '')
end

local function splitCandidateText(text)
    text = trim(tostring(text or ''))
    if text == '' then return {} end
    local maxBytes = tonumber(CONFIG.maxCandidateMessageBytes) or 92
    if outboundEncodedLength(text) <= maxBytes then return {text} end
    local chunks, current = {}, ''
    for word in text:gmatch('%S+') do
        if current ~= '' and current:match('[%.%!%?]$') then
            chunks[#chunks + 1] = current
            current = word
        else
            local candidate = current == '' and word or (current .. ' ' .. word)
            if current ~= '' and outboundEncodedLength(candidate) > maxBytes then
                chunks[#chunks + 1] = current
                current = word
            else current = candidate end
        end
    end
    if current ~= '' then chunks[#chunks + 1] = current end
    return chunks
end

local function enqueueCandidateText(text, onSent)
    local chunks = splitCandidateText(text)
    for index, chunk in ipairs(chunks) do
        local callback = (index == #chunks) and onSent or nil
        enqueueOutbound(chunk, 'message', session.testMode, nil, callback)
    end
end

local function sendChatLines(lines, delayMs)
    for _, line in ipairs(lines or {}) do
        if type(line) == 'string' and line ~= '' then enqueueCandidateText(line) end
    end
end

local function sendCandidateLine(text, onSent)
    if type(text) ~= 'string' or text == '' then return end
    enqueueCandidateText(text, onSent)
end

local function sendCandidateLines(lines, delayMs)
    sendChatLines(lines, delayMs)
end

local RP_PHRASES = {
    consent_negative = {
        'Хорошо, всего доброго.',
        'Понял Вас. Всего доброго.',
        'Хорошо, тогда не задерживаю. Всего доброго.'
    },
    docs_request = {
        'Давайте документы.',
        'Предъявите, пожалуйста, документы.',
        'Хорошо. Теперь передайте Ваши документы.'
    },
    success = {
        'Вы приняты! Добро пожаловать в наши ряды.',
        'Поздравляю, Вы приняты. Добро пожаловать!',
        'Все требования соблюдены. Вы приняты на службу.',
        'Проверка завершена успешно. Вы приняты!'
    },
    professional_fail = {
        'К сожалению, Вы профессионально непригодны.',
        'По результатам проверки Вы признаны профессионально непригодным.',
        'На данный момент Вы не соответствуете требованиям профессиональной пригодности.'
    },
    wrong_owner = {
        'Переданные документы принадлежат другому гражданину. Передайте, пожалуйста, свои документы.',
        'Эти документы оформлены на другого гражданина. Предъявите свои документы.',
        'Данные в документах принадлежат другому человеку. Передайте Ваши документы повторно.'
    },
    bad_nickname_format = {
        'Ваши имя и фамилия в документах не соответствуют установленному формату. Исправьте персональные данные и приходите повторно.',
        'В персональных данных обнаружено несоответствие установленному формату имени и фамилии. Исправьте данные и приходите повторно.',
        'Ваши персональные данные оформлены некорректно. Приведите имя и фамилию в установленный формат и возвращайтесь на призыв.'
    },
    bad_nickname_online = {
        'Ваши персональные данные требуют дополнительной проверки. Обратитесь к руководству для уточнения данных.',
        'По Вашим персональным данным требуется дополнительная проверка. Обратитесь к руководству.',
        'Необходимо дополнительно подтвердить Ваши персональные данные. Обратитесь к руководству для уточнения.'
    },
    years_unknown = {
        'Не удалось подтвердить срок Вашего проживания в штате. Передайте паспорт повторно.',
        'Срок проживания в штате не удалось проверить. Предъявите паспорт ещё раз.',
        'Я не смог подтвердить количество лет Вашего проживания в штате. Передайте паспорт повторно.'
    },
    low_years = {
        'Вы проживаете в штате менее трёх лет. Для прохождения призыва необходимо прожить в штате не менее трёх лет.',
        'Ваш срок проживания в штате меньше трёх лет. На призыв допускаются граждане, прожившие здесь не менее трёх лет.',
        'Для принятия требуется минимум три года проживания в штате. На данный момент Ваш срок меньше установленного.'
    },
    law_unknown = {
        'Не удалось проверить показатель законопослушности. Передайте паспорт повторно.',
        'Показатель законопослушности не удалось подтвердить. Предъявите паспорт ещё раз.',
        'Я не смог проверить Вашу законопослушность. Передайте паспорт повторно.'
    },
    low_law = {
        'Ваш показатель законопослушности ниже установленной нормы. Повторно явитесь на призыв после достижения 35 единиц.',
        'Для прохождения призыва требуется не менее 35 единиц законопослушности. Ваш показатель пока ниже нормы.',
        'Законопослушность должна составлять минимум 35 единиц. Повторно приходите после достижения этого значения.'
    },
    no_car_license = {
        'У Вас нет лицензии на вождение автомобиля. Получите её в центре лицензирования.',
        'Лицензия на управление автомобилем отсутствует. Получите её в центре лицензирования.',
        'У Вас отсутствует водительская лицензия. Оформите её в центре лицензирования и приходите повторно.'
    },
    car_unknown = {
        'Не удалось проверить лицензию на вождение автомобиля. Передайте документы повторно.',
        'Водительскую лицензию не удалось подтвердить. Предъявите документы ещё раз.',
        'Я не смог проверить наличие лицензии на автомобиль. Передайте документы повторно.'
    },
    gun_unknown = {
        'Не удалось проверить лицензию на оружие. Передайте документы повторно.',
        'Наличие оружейной лицензии не удалось подтвердить. Предъявите документы ещё раз.',
        'Я не смог проверить лицензию на оружие. Передайте документы повторно.'
    },
    no_medical_card = {
        'У Вас отсутствует медицинская карта. Получите её в любой больнице штата.',
        'Медицинская карта у Вас отсутствует. Оформите её в любой больнице штата.',
        'Я не вижу у Вас медицинской карты. Получите её в одной из больниц штата и приходите повторно.'
    },
    medical_unknown = {
        'Не удалось проверить медицинскую карту. Передайте документы повторно.',
        'Данные медицинской карты не удалось подтвердить. Предъявите документы ещё раз.',
        'Я не смог проверить медицинскую карту. Передайте её повторно.'
    },
    bad_health = {
        'В Вашей медицинской карте отсутствует пометка «Полностью здоров». Пройдите обследование в любой больнице штата.',
        'По медицинской карте у Вас нет отметки «Полностью здоров». Пройдите обследование в больнице штата.',
        'Медицинская карта не подтверждает, что Вы полностью здоровы. Пройдите повторное обследование в любой больнице штата.'
    },
    dependency_unknown = {
        'В медицинской карте не удалось проверить показатель зависимости от укропа. Обратитесь в больницу штата для повторного обследования.',
        'Показатель зависимости от укропа в медкарте не удалось подтвердить. Пройдите повторное обследование в больнице штата.',
        'Я не смог определить показатель зависимости от укропа по медицинской карте. Обратитесь в больницу для проверки.'
    },
    high_dependency = {
        'Показатель зависимости от укропа превышает допустимую норму. Пройдите курс лечения в любой больнице штата.',
        'Уровень зависимости от укропа выше допустимого значения. Обратитесь в больницу штата и пройдите лечение.',
        'По медицинской карте зависимость от укропа превышает норму. Пройдите курс лечения в любой больнице штата.'
    },
    no_gun_license = {
        'У Вас нет лицензии на оружие. После принятия у Вас будет 24 часа на её приобретение.',
        'Оружейная лицензия у Вас отсутствует. После принятия Вам даётся 24 часа на её получение.',
        'Лицензии на оружие сейчас нет. После принятия у Вас будет 24 часа, чтобы приобрести её.'
    },
    docs_ok = {
        'Документы в полном порядке.',
        'С документами всё в порядке.',
        'По документам замечаний нет.'
    }
}

local lastRpPhraseIndex = {}

local function rpPhrase(key)
    local list = RP_PHRASES[key]
    if type(list) ~= 'table' or #list == 0 then return tostring(key or '') end
    local index = 1
    if #list > 1 then
        index = math.random(1, #list)
        local previous = lastRpPhraseIndex[key]
        if previous and index == previous then index = (index % #list) + 1 end
    end
    lastRpPhraseIndex[key] = index
    return list[index]
end

local function getSelfIdForShowPass()
    local okCall, okPlayer, selfId = pcall(function()
        local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        return ok, id
    end)
    if okCall and okPlayer and selfId ~= nil then return tonumber(selfId) end
    return nil
end

local function sendShowPassInstruction(attempt)
    attempt = tonumber(attempt) or 1
    local selfId = getSelfIdForShowPass()
    if selfId ~= nil then
        local line = '/b Передача документов ПО РП!!! Используйте /showpass ' .. tostring(selfId)
        local encoded = line
        local okEncode, converted = pcall(cp, line)
        if okEncode and type(converted) == 'string' then encoded = converted end
        enqueueOutbound(encoded, 'command', session.testMode)
        debugLog('ShowPass instruction queued. selfId=' .. tostring(selfId))
        return true
    end
    if attempt < 10 then
        scheduleAction(500, function() sendShowPassInstruction(attempt + 1) end)
    else
        chatInfo('Не удалось определить ваш игровой ID для /showpass. Используйте /showpass вручную.')
        debugLog('ShowPass instruction failed: local player ID unavailable after 10 attempts.')
    end
    return false
end

local function sendGameCommand(command)
    if type(command) ~= 'string' or command == '' then return end
    enqueueOutbound(command, 'command', session.testMode)
end

local function sendLocalCommand(command)
    if type(command) ~= 'string' or command == '' then return end
    enqueueOutbound(command, 'local_command', session.testMode)
end

-- ============================================================================
-- AUTO VOiS
-- ============================================================================
local AUTO_VOIS = {
    enabled = true,
    dialogUnitMain = 8772,
    dialogUnitMenu = 8773,
    dialogWrong = 8776,
    dialogUnitInput = 8777,
    unitMenuResponseIndex = 3,
    dialogDelayMs = 300,
    inputSubmitDelayMs = 500,
    setTagDelayMs = 3000,
    searchTries = 20,
    searchDelayMs = 250,
    workflowTimeoutMs = 30000,
}

local AUTO_VOIS_TAG = cp('ВОиС')

local autoVoisState = {
    active = false, step = 0, token = 0, playerId = nil, playerNick = nil,
    resolving = false, resolveNick = nil, resolveTries = 0, nextResolveAt = 0, deadlineAt = 0,
}

local function autoVoisChat(message, color)
    local line = '[Auto VOiS] ' .. tostring(message)
    consolePrint(line)
    if isSampAvailable() then
        local ok, err = pcall(function() sampAddChatMessage(cp(line), color or 0x6EDC6E) end)
        if not ok then debugLog('Auto VOiS chat failed: ' .. tostring(err)) end
    end
end

local function autoVoisReset()
    autoVoisState.active = false
    autoVoisState.step = 0
    autoVoisState.playerId = nil
    autoVoisState.playerNick = nil
    autoVoisState.deadlineAt = 0
    autoVoisState.resolving = false
    autoVoisState.resolveNick = nil
    autoVoisState.resolveTries = 0
    autoVoisState.nextResolveAt = 0
end

local function autoVoisCancel()
    autoVoisState.token = autoVoisState.token + 1
    autoVoisReset()
end

local function autoVoisGetLocalPlayerData()
    local ok, playerId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not ok then return nil, nil end
    local nickname = sampGetPlayerNickname(playerId)
    if not nickname then return nil, nil end
    return playerId, nickname
end

local function autoVoisFindPlayerIdByNickname(nickname)
    if not nickname or nickname == '' then return nil end
    local target = nickname:lower()
    local maxId = 999
    local okMax, currentMax = pcall(function() return sampGetMaxPlayerId(true) end)
    if okMax and type(currentMax) == 'number' and currentMax >= 0 then maxId = math.min(999, currentMax) end
    for playerId = 0, maxId do
        if sampIsPlayerConnected(playerId) then
            local currentNickname = sampGetPlayerNickname(playerId)
            if currentNickname and currentNickname:lower() == target then return playerId end
        end
    end
    return nil
end

local function autoVoisGetCurrentDialogIdSafe()
    local okActive, active = pcall(function() return sampIsDialogActive() end)
    if not okActive or not active then return nil end
    local okId, dialogId = pcall(function() return sampGetCurrentDialogId() end)
    if not okId then return nil end
    return dialogId
end

local function autoVoisSendDialogResponseSafe(dialogId, button, listItem, inputText)
    local currentDialogId = autoVoisGetCurrentDialogIdSafe()
    if currentDialogId ~= dialogId then
        return false, 'текущий диалог: ' .. tostring(currentDialogId) .. ', ожидался: ' .. tostring(dialogId)
    end
    local ok, err = pcall(function() sampSendDialogResponse(dialogId, button or 1, listItem or 0, inputText or '') end)
    if not ok then return false, tostring(err) end
    return true
end

local function autoVoisScheduleDialogResponse(dialogId, nextStep, listItem, inputText, delayMs)
    local token = autoVoisState.token
    autoVoisState.step = nextStep
    scheduleAction(delayMs or AUTO_VOIS.dialogDelayMs, function()
        if not AUTO_VOIS.enabled or not autoVoisState.active or autoVoisState.token ~= token then return end
        local ok, err = autoVoisSendDialogResponseSafe(dialogId, 1, listItem or 0, inputText or '')
        if not ok then
            autoVoisChat('Ответ диалогу ' .. tostring(dialogId) .. ' отменён: ' .. tostring(err), 0xFF7777)
            autoVoisCancel()
        end
    end)
end

local function autoVoisSubmitPlayerId()
    local token = autoVoisState.token
    local playerId = autoVoisState.playerId
    local playerNick = autoVoisState.playerNick

    if playerId == nil or playerNick == nil then
        autoVoisChat('Потеряны данные игрока. Операция остановлена.', 0xFF7777)
        autoVoisCancel()
        return
    end

    local idText = tostring(playerId)
    autoVoisState.step = 4
    scheduleAction(AUTO_VOIS.inputSubmitDelayMs, function()
        if not AUTO_VOIS.enabled or not autoVoisState.active or autoVoisState.token ~= token then return end
        local okDialog, dialogError = autoVoisSendDialogResponseSafe(AUTO_VOIS.dialogUnitInput, 1, 0, idText)
        if not okDialog then
            autoVoisChat('Отправка ID отменена: ' .. tostring(dialogError), 0xFF7777)
            autoVoisCancel()
            return
        end
        autoVoisChat('ID ' .. idText .. ' отправлен. Жду перед выдачей тега...')
        scheduleAction(AUTO_VOIS.setTagDelayMs, function()
            if not AUTO_VOIS.enabled or not autoVoisState.active or autoVoisState.token ~= token then return end
            local command = '/settag ' .. idText .. ' ' .. AUTO_VOIS_TAG
            enqueueOutbound(command, 'command', false)
            autoVoisChat('В очередь поставлено: /settag ' .. idText .. ' ВОиС для ' .. playerNick .. '.')
            autoVoisCancel()
        end)
    end)
end

local function autoVoisStartWorkflow(playerNick, playerId)
    if not AUTO_VOIS.enabled or autoVoisState.active then return end
    autoVoisState.token = autoVoisState.token + 1
    autoVoisState.active = true
    autoVoisState.step = 1
    autoVoisState.playerId = playerId
    autoVoisState.playerNick = playerNick
    autoVoisState.deadlineAt = nowMs() + AUTO_VOIS.workflowTimeoutMs
    local token = autoVoisState.token
    scheduleAction(300, function()
        if not AUTO_VOIS.enabled or not autoVoisState.active or autoVoisState.token ~= token then return end
        autoVoisChat('Найден ' .. playerNick .. '[' .. tostring(playerId) .. ']. Открываю /unit...')
        enqueueOutbound('/unit', 'command', false)
    end)
end

local function autoVoisBeginResolve(newNick)
    if not AUTO_VOIS.enabled or autoVoisState.active or autoVoisState.resolving then return end
    autoVoisState.resolving = true
    autoVoisState.resolveNick = newNick
    autoVoisState.resolveTries = 0
    autoVoisState.nextResolveAt = nowMs()
end

local function processAutoVois()
    if not AUTO_VOIS.enabled then return end
    local now = nowMs()
    if autoVoisState.resolving and now >= autoVoisState.nextResolveAt then
        autoVoisState.resolveTries = autoVoisState.resolveTries + 1
        local playerId = autoVoisFindPlayerIdByNickname(autoVoisState.resolveNick)
        if playerId ~= nil then
            local nick = autoVoisState.resolveNick
            autoVoisState.resolving = false
            autoVoisState.resolveNick = nil
            autoVoisStartWorkflow(nick, playerId)
        elseif autoVoisState.resolveTries >= AUTO_VOIS.searchTries then
            local nick = autoVoisState.resolveNick
            autoVoisState.resolving = false
            autoVoisState.resolveNick = nil
            autoVoisChat('Не найден ID игрока ' .. tostring(nick) .. '.', 0xFF7777)
        else
            autoVoisState.nextResolveAt = now + AUTO_VOIS.searchDelayMs
        end
    end
    if autoVoisState.active and autoVoisState.deadlineAt > 0 and now >= autoVoisState.deadlineAt then
        autoVoisChat('Тайм-аут на шаге ' .. tostring(autoVoisState.step) .. '.', 0xFF7777)
        autoVoisCancel()
    end
end

-- ============================================================================
-- АВТОБИНДЕР: DISCORD
-- ============================================================================
local AUTO_BINDER = {
    enabled = CONFIG.autoBinderEnabled == true,
    discordEnabled = CONFIG.discordBinderEnabled ~= false,
    initialized = false,
    startedAt = 0,
    discordNextAt = 0,
}

local DISCORD_BIND = {
    '/rb Уважаемые военнослужащие Армии г. Лос-Сантос.',
    '/rb Напоминаю о Discord-сервере нашего штата.',
    '/rb Получите роль "Военнослужащий ЛСа" и заходите в канал "Общение ЛСа".',
    '/rb Общайтесь с сослуживцами, задавайте вопросы и следите за важной информацией.',
    '/rb https://discord.gg/arzspace',
}

local function discordBinderInterval() return math.max(60000, tonumber(CONFIG.discordBinderIntervalMs) or 3600000) end
local function autoBinderRetry() return math.max(10000, tonumber(CONFIG.autoBinderRetryMs) or 60000) end

local function initAutoBinderSchedule(resetAll)
    local now = nowMs()
    if AUTO_BINDER.initialized and not resetAll then return end
    AUTO_BINDER.initialized = true
    AUTO_BINDER.startedAt = now
    AUTO_BINDER.discordNextAt = now + math.max(60000, tonumber(CONFIG.discordFirstDelayMs) or 3600000)
end

local function autoBinderIsBusy()
    if session and session.active then return true, 'идёт призыв' end
    if autoVoisState and (autoVoisState.active or autoVoisState.resolving) then return true, 'работает Auto VOiS' end
    if #outboundQueue > 0 then return true, 'очередь сообщений занята' end
    if nowMs() < outboundNextSendAt then return true, 'действует антифлуд-пауза' end
    return false, nil
end

local function enqueueRadioBinder(lines, title)
    if type(lines) ~= 'table' or #lines == 0 then return false end
    for _, line in ipairs(lines) do
        local encoded = line
        local okEncode, converted = pcall(cp, line)
        if okEncode and type(converted) == 'string' then encoded = converted end
        if not enqueueOutbound(encoded, 'command', false) then
            debugLog('AutoBinder: не удалось поставить строку в очередь: ' .. tostring(line))
            return false
        end
    end
    chatInfo('Автобиндер: «' .. tostring(title) .. '» поставлен в очередь.')
    debugLog('AutoBinder queued: ' .. tostring(title))
    return true
end

local function sendDiscordBinderNow(ignoreBusy)
    local busy, reason = autoBinderIsBusy()
    if busy and not ignoreBusy then
        chatInfo('Discord сейчас не отправлен: ' .. tostring(reason) .. '.')
        return false
    end
    return enqueueRadioBinder(DISCORD_BIND, 'Discord ЛС')
end

local function processAutoBinder()
    if not AUTO_BINDER.enabled then return end
    initAutoBinderSchedule(false)
    local now = nowMs()
    local minFirstDelay = math.max(60000, tonumber(CONFIG.discordFirstDelayMs) or 3600000)
    if AUTO_BINDER.startedAt <= 0 or (now - AUTO_BINDER.startedAt) < minFirstDelay then return end

    if AUTO_BINDER.discordEnabled and now >= AUTO_BINDER.discordNextAt then
        local busy = autoBinderIsBusy()
        if busy then
            AUTO_BINDER.discordNextAt = now + autoBinderRetry()
        else
            if sendDiscordBinderNow(true) then
                AUTO_BINDER.discordNextAt = now + discordBinderInterval()
            else
                AUTO_BINDER.discordNextAt = now + autoBinderRetry()
            end
        end
    end
end

local function autoBinderTimeLeft(targetAt)
    if not AUTO_BINDER.initialized then return '?' end
    local left = math.max(0, tonumber(targetAt or 0) - nowMs())
    if left < 115000 then return '~' .. tostring(math.ceil(left / 1000)) .. ' сек.' end
    return '~' .. tostring(math.ceil(left / 60000)) .. ' мин.'
end

local function printAutoBinderStatus()
    initAutoBinderSchedule(false)
    local dcStatus = AUTO_BINDER.discordEnabled and ('ВКЛ, через ' .. autoBinderTimeLeft(AUTO_BINDER.discordNextAt)) or 'ВЫКЛ'
    chatInfo('Автобиндер: ' .. (AUTO_BINDER.enabled and 'ВКЛ' or 'ВЫКЛ') .. ' | Discord: ' .. dcStatus)
end

local function setAutoBinderEnabled(value)
    value = value == true
    if AUTO_BINDER.enabled == value then
        chatInfo('Автобиндер уже ' .. (value and 'включён.' or 'выключен.'))
        printAutoBinderStatus()
        return
    end
    AUTO_BINDER.enabled = value
    if value then
        initAutoBinderSchedule(true)
        chatInfo('Автобиндер включён.')
        printAutoBinderStatus()
    else
        chatInfo('Автобиндер выключен. Автоматические объявления остановлены.')
    end
end

local function toggleAutoBinder() setAutoBinderEnabled(not AUTO_BINDER.enabled) end

local function setDiscordBinderEnabled(value)
    value = value == true
    AUTO_BINDER.discordEnabled = value
    if value then
        AUTO_BINDER.discordNextAt = nowMs() + math.max(60000, tonumber(CONFIG.discordFirstDelayMs) or 3600000)
        chatInfo('Автобиндер Discord включён.')
    else
        chatInfo('Автобиндер Discord выключен.')
    end
    printAutoBinderStatus()
end

local function autoVoisHandleServerMessage(color, text)
    if not AUTO_VOIS.enabled or autoVoisState.active or autoVoisState.resolving then return end
    local cleanText = (text or ''):gsub('{%x%x%x%x%x%x}', '')
    local okConvert, utf8Text = pcall(function() return u8(cleanText) end)
    if not okConvert or not utf8Text then return end
    local newNick, inviterNick, inviterId = utf8Text:match('Приветствуем нового члена нашей организации%s+([%w_]+),%s+которого пригласил:%s*([%w_]+)%[(%d+)%]')
    if not newNick then return end
    local myId, myNick = autoVoisGetLocalPlayerData()
    if myId == nil or myNick == nil then
        autoVoisChat('Не удалось определить ваш ID.', 0xFF7777)
        return
    end
    local invitedByMe = tonumber(inviterId) == myId or inviterNick:lower() == myNick:lower()
    if not invitedByMe then return end
    autoVoisBeginResolve(newNick)
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if not AUTO_VOIS.enabled or not autoVoisState.active then return end
    if autoVoisState.step == 1 and dialogId == AUTO_VOIS.dialogUnitMain then
        autoVoisChat('Открыт 8772. Нажимаю левую кнопку.')
        autoVoisScheduleDialogResponse(AUTO_VOIS.dialogUnitMain, 2, 0, '', AUTO_VOIS.dialogDelayMs)
        return
    end
    if autoVoisState.step == 2 and dialogId == AUTO_VOIS.dialogUnitMenu then
        autoVoisChat('Открыт 8773. Выбираю «Назначить подразделение игроку».')
        autoVoisScheduleDialogResponse(AUTO_VOIS.dialogUnitMenu, 3, AUTO_VOIS.unitMenuResponseIndex, '', AUTO_VOIS.dialogDelayMs)
        return
    end
    if autoVoisState.step == 3 and dialogId == AUTO_VOIS.dialogWrong then
        autoVoisChat('Открылся 8776 вместо 8777. Ничего не нажимаю; операция остановлена.', 0xFF7777)
        autoVoisCancel()
        return
    end
    if autoVoisState.step == 3 and dialogId == AUTO_VOIS.dialogUnitInput then
        autoVoisChat('Открыт 8777. Отправляю ID ' .. tostring(autoVoisState.playerId) .. '.')
        autoVoisSubmitPlayerId()
        return
    end
end

local function clearSession(reason)
    if reason then debugLog('Session stopped: ' .. reason) end
    session.active = false
    session.stage = 'idle'
    session.targetId = nil
    session.targetName = nil
    session.deadline = 0
    session.answers = {}
    session.q2Retry = false
    session.q2Term = nil
    session.q2FirstTermCode = nil
    session.rpMenuChoices = {}
    session.rpAsked = {}
    session.rpCurrent = nil
    session.warnedDocs = false
    session.warnedPage2 = false
    session.warnedPage4 = false
    session.lastSpeechBody = nil
    session.lastSpeechAt = 0
    session.packetCount = 0
    session.testMode = false
    session.nickCheck = nil
    session.docs = nil
end

local function stopWithMessage(message)
    if message then sendCandidateLine(message) end
    clearSession(message or 'stopped')
end

local function isTargetAvailable()
    if session.testMode then return session.targetId ~= nil end
    return session.targetId ~= nil and sampIsPlayerConnected(session.targetId)
end

local function getNearestPlayerInFront()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local fx, fy, fz = getOffsetFromCharInWorldCoords(PLAYER_PED, 0.0, 1.0, 0.0)
    local fvx, fvy = fx - px, fy - py
    local flen = math.sqrt(fvx * fvx + fvy * fvy)
    if flen < 0.001 then return nil end
    fvx, fvy = fvx / flen, fvy / flen
    local foundId, foundDistance = nil, CONFIG.nearDistance + 0.001
    local selfOk, selfId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local maxId = sampGetMaxPlayerId(true)

    for id = 0, maxId do
        if (not selfOk or id ~= selfId) and sampIsPlayerConnected(id) then
            local streamed, ped = sampGetCharHandleBySampPlayerId(id)
            if streamed and doesCharExist(ped) then
                local x, y, z = getCharCoordinates(ped)
                local dx, dy, dz = x - px, y - py, z - pz
                local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
                if distance > 0.05 and distance <= foundDistance then
                    local horizontal = math.sqrt(dx * dx + dy * dy)
                    if horizontal > 0.001 then
                        local dot = (dx / horizontal) * fvx + (dy / horizontal) * fvy
                        if dot >= CONFIG.frontDot then
                            foundId, foundDistance = id, distance
                        end
                    end
                end
            end
        end
    end
    return foundId, foundDistance
end

local function newDocsState()
    return {
        name = nil, years = nil, law = nil, car = nil, gun = nil, health = nil,
        dependency = nil, medicalExists = nil, gotPassport = false, gotLicenses = false, gotMedical = false,
    }
end

local function validateRpNicknameFormat(nickname)
    nickname = tostring(nickname or '')
    local first, last = nickname:match("^([A-Z][A-Za-z'%-]+)_([A-Z][A-Za-z'%-]+)$")
    if not first or not last then return false, nil, nil, 'ник должен иметь вид Name_Surname латиницей' end
    if #first < 2 or #last < 2 then return false, first, last, 'имя и фамилия слишком короткие' end
    if nickname:find('__', 1, true) then return false, first, last, 'двойное подчёркивание недопустимо' end
    return true, first, last, nil
end

local function urlEncode(textValue)
    return (tostring(textValue or ''):gsub('([^%w%-%._~])', function(ch) return string.format('%%%02X', ch:byte()) end))
end

local function parseNamespediaUsage(html)
    html = tostring(html or '')
    if html == '' then return nil, nil end
    local plain = html:gsub('<script.-</script>', ' '):gsub('<style.-</style>', ' '):gsub('<[^>]+>', ' '):gsub('&nbsp;', ' '):gsub('&#37;', '%%'):gsub('%s+', ' ')
    local firstPct, surnamePct = plain:match('Usage:%s*(%d+)%s*%%%s*firstname,%s*(%d+)%s*%%%s*surname')
    if not firstPct then
        firstPct, surnamePct = plain:match('Nutzung:%s*(%d+)%s*%%%s*Vorname,%s*(%d+)%s*%%%s*Nachname')
    end
    return tonumber(firstPct), tonumber(surnamePct)
end

local nicknameCheckSerial = 0
local function startRpNicknameCheck(nickname, attachToSession)
    nickname = tostring(nickname or '')
    local valid, first, last, reason = validateRpNicknameFormat(nickname)
    local check = { nickname = nickname, localValid = valid, first = first, last = last, onlineDone = false, onlineSuspicious = false }
    if attachToSession then session.nickCheck = check end

    if valid then chatInfo('RP-ник: формат ' .. nickname .. ' корректен. Проверяю, RP он или НРП...')
    else
        chatInfo('RP-ник: ник точно НРП — ' .. tostring(reason) .. '.')
        return check
    end

    if not CONFIG.checkRpNicknameOnline then
        chatInfo('RP-ник: точную онлайн-проверку RP/НРП выполнить нельзя — она отключена в настройках.')
        return check
    end
    if not dlstatus or type(downloadUrlToFile) ~= 'function' then
        chatInfo('RP-ник: не удалось точно определить RP/НРП — онлайн-проверка Namespedia недоступна.')
        return check
    end

    nicknameCheckSerial = nicknameCheckSerial + 1
    local serial = nicknameCheckSerial
    local folder = getDebugLogPath():gsub('[^\\/]+$', '')
    local results = {pending = 2, first = nil, last = nil, finished = false}

    local function stillRelevant()
        if not attachToSession then return true end
        return session.active and session.targetName == nickname and session.nickCheck == check
    end

    local function finalize(force)
        if results.finished then return end
        if not force and results.pending > 0 then return end
        results.finished = true
        check.onlineDone = true
        if not stillRelevant() and attachToSession then return end
        local firstPct = results.first and results.first.firstPct or nil
        local surnamePct = results.last and results.last.surnamePct or nil

        if firstPct == nil or surnamePct == nil then chatInfo('RP-ник: не удалось точно определить RP/НРП — Namespedia не дала полный ответ.')
        elseif firstPct <= 0 or surnamePct <= 0 then
            check.onlineSuspicious = true
            chatInfo('RP-ник: ник точно НРП.')
        else
            check.onlineSuspicious = false
            chatInfo('RP-ник: ник точно RP.')
        end
    end

    local function fetchPart(part, role)
        local safePart = part:gsub('[^%w%-_]', '_')
        local path = folder .. string.format('recruit_namecheck_%d_%d_%s.tmp', os.time(), serial, safePart)
        if doesFileExist(path) then os.remove(path) end
        local url = 'https://www.namespedia.com/details/' .. urlEncode(part)

        local ok, err = pcall(function()
            downloadUrlToFile(url, path, function(id, status, p1, p2)
                if status == dlstatus.STATUSEX_ENDDOWNLOAD then
                    local html = ''
                    local f = io.open(path, 'rb')
                    if f then
                        html = f:read('*a') or ''
                        f:close()
                    end
                    if doesFileExist(path) then os.remove(path) end
                    local fp, sp = parseNamespediaUsage(html)
                    results[role] = {firstPct = fp, surnamePct = sp}
                    results.pending = math.max(0, results.pending - 1)
                    finalize(false)
                end
            end)
        end)
        if not ok then
            debugLog('Namespedia download failed to start: ' .. tostring(err))
            results.pending = math.max(0, results.pending - 1)
            finalize(false)
        end
    end

    fetchPart(first, 'first')
    fetchPart(last, 'last')
    scheduleAction(CONFIG.nicknameCheckTimeoutMs, function() finalize(true) end)
    return check
end

local function startRecruitment(id, options)
    options = options or {}
    id = tonumber(id)
    local isTestMode = options.testMode == true

    if not id then
        chatInfo('Игрок не найден.')
        return
    end

    if not isTestMode and not sampIsPlayerConnected(id) then
        chatInfo('Игрок не найден.')
        return
    end

    clearSession('new session')
    session.active = true
    session.testMode = isTestMode
    session.stage = 'wait_consent'
    session.targetId = id
    session.targetName = options.targetName or sampGetPlayerNickname(id) or (isTestMode and 'Self_Test' or ('Player_' .. tostring(id)))
    session.deadline = 0 
    session.docs = newDocsState()

    if not options.skipNickCheck then
        startRpNicknameCheck(session.targetName, true)
    else
        local valid, first, last, reason = validateRpNicknameFormat(session.targetName)
        session.nickCheck = {nickname = session.targetName, localValid = valid, first = first, last = last, reason = reason}
    end

    sendCandidateLines({
        'Здравия желаю, Вы на призыв?',
        '/b Ответьте да/нет.'
    })
    chatInfo(string.format('%sКандидат: %s[%d]. Ожидаю положительный ответ.', session.testMode and '[TEST] ' or '', session.targetName, id))
end

local function giveFractionRpInRadius()
    local selfOk, selfId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local players = {}
    local maxId = sampGetMaxPlayerId(true)

    for id = 0, maxId do
        if (not selfOk or id ~= selfId) and sampIsPlayerConnected(id) then
            local streamed, ped = sampGetCharHandleBySampPlayerId(id)
            if streamed and doesCharExist(ped) then
                local x, y, z = getCharCoordinates(ped)
                local dist = getDistanceBetweenCoords3d(px, py, pz, x, y, z)
                if dist <= CONFIG.nearDistance then
                    players[#players + 1] = {id = id, distance = dist}
                end
            end
        end
    end

    if #players == 0 then
        chatInfo('В радиусе ' .. tostring(CONFIG.nearDistance) .. ' м. игроков нет.')
        return
    end

    table.sort(players, function(a, b) return a.distance < b.distance end)

    local ids = {}
    for index, player in ipairs(players) do
        ids[#ids + 1] = tostring(player.id)
        scheduleAction((index - 1) * 1500, function()
            sampSendChat('/fractionrp ' .. tostring(player.id))
        end)
    end

    chatInfo('Выдано /fractionrp игрокам: ' .. table.concat(ids, ', ') .. ' | Радиус: ' .. tostring(CONFIG.nearDistance) .. ' м.')
end

local function startNearest()
    local id, distance = getNearestPlayerInFront()
    if not id then
        chatInfo('Перед вами нет подходящего игрока в радиусе ' .. tostring(CONFIG.nearDistance) .. ' м.')
        return
    end
    debugLog(string.format('Nearest player: %s[%d], %.2f m', sampGetPlayerNickname(id), id, distance or -1))
    startRecruitment(id)
end

local function editDistanceAtMostOne(a, b)
    a, b = tostring(a or ''), tostring(b or '')
    local la, lb = #a, #b
    if math.abs(la - lb) > 1 then return false end
    if a == b then return true end
    if la == lb then
        local diff = 0
        for i = 1, la do
            if a:byte(i) ~= b:byte(i) then
                diff = diff + 1
                if diff > 1 then return false end
            end
        end
        return diff <= 1
    end
    local short, long = a, b
    if la > lb then short, long = b, a end
    local i, j, skipped = 1, 1, false
    while i <= #short and j <= #long do
        if short:byte(i) == long:byte(j) then
            i, j = i + 1, j + 1
        elseif not skipped then
            skipped = true
            j = j + 1
        else return false end
    end
    return true
end

local function consentHasTypoPositive(answer)
    local words = splitWords(answer)
    local shortTypos = {cp('нда'), cp('дда'), cp('даа'), cp('ддаа'), cp('дп'), cp('даж'), cp('жа'), cp('дэ'), cp('йа'), cp('дас'), 'yess', 'yees', 'yse', 'ys', 'yep'}
    for _, word in ipairs(words) do
        for _, typo in ipairs(shortTypos) do
            if word == typo then return true end
        end
    end
    local fuzzyPositive = {cp('ага'), cp('угу'), cp('конечно'), cp('готов'), cp('готова'), cp('давай'), cp('погнали'), cp('точно'), cp('согласен'), cp('согласна'), cp('разумеется'), cp('безусловно'), cp('верно'), cp('йес'), 'yes', 'yeah', 'okay', 'affirmative'}
    for _, word in ipairs(words) do
        for _, expected in ipairs(fuzzyPositive) do
            if #expected >= 4 and editDistanceAtMostOne(word, expected) then return true end
        end
    end
    return false
end

local function isPositiveConsent(answer)
    local lower = ruLower(answer)
    local negativeWords = {cp('нет'), cp('не'), cp('неа'), 'no', 'nope', 'nah'}
    for _, word in ipairs(negativeWords) do
        if hasWord(lower, word) then return false end
    end
    if lower:find(cp('отказываюсь'), 1, true) or lower:find(cp('не хочу'), 1, true) then return false end

    local positiveWords = {cp('да'), cp('ага'), cp('угу'), cp('конечно'), cp('готов'), cp('готова'), cp('давай'), cp('погнали'), cp('точно'), cp('есть'), cp('согласен'), cp('согласна'), cp('разумеется'), cp('безусловно'), cp('верно'), cp('ес'), cp('йес'), cp('жа'), cp('дэ'), cp('йа'), cp('дас'), 'yes', 'yeah', 'yep', 'ye', 'y', 'ok', 'okay', 'affirmative'}
    for _, word in ipairs(positiveWords) do
        if hasWord(lower, word) then return true end
    end

    local positivePhrases = {cp('так точно'), cp('готов служить'), cp('готова служить'), cp('готов к призыву'), cp('готова к призыву'), cp('согласен на призыв'), cp('согласна на призыв'), cp('на призыв')}
    for _, phrase in ipairs(positivePhrases) do
        if lower:find(phrase, 1, true) then return true end
    end

    if consentHasTypoPositive(lower) then return true end
    return false
end

local function answerLooksNegative(answer)
    local lower = ruLower(answer)
    local negativeWords = {cp('нет'), cp('неа'), 'no', 'nope', 'nah'}
    for _, word in ipairs(negativeWords) do
        if hasWord(lower, word) then return true end
    end
    return lower:find(cp('отказываюсь'), 1, true) ~= nil or lower:find(cp('не хочу'), 1, true) ~= nil
end

local function sendArizonaCefCommand(text)
    local ok, err = pcall(function()
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, 220)
        raknetBitStreamWriteInt8(bs, 18)
        raknetBitStreamWriteInt32(bs, 0)
        raknetBitStreamWriteInt16(bs, #text)
        raknetBitStreamWriteString(bs, text)
        raknetSendBitStreamEx(bs, 1, 3, 0)
        raknetDeleteBitStream(bs)
    end)
    if not ok then debugLog('CEF send failed: ' .. tostring(err)) else debugLog('CEF send: ' .. text) end
    return ok
end

local function requestDocumentPage(page)
    if not CONFIG.autoSwitchDocumentPages then return end
    if session.testMode then chatInfo('[TEST CEF] documents.changePage|' .. tostring(page)) return end
    scheduleAction(350, function()
        if session.active then sendArizonaCefCommand('documents.changePage|' .. tostring(page)) end
    end)
end

local function parseFirstNumber(value)
    if value == nil then return nil end
    local matched = tostring(value):match('(%d+[%.,]?%d*)')
    if not matched then return nil end
    return tonumber((matched:gsub(',', '.')))
end

local function tableContainsHealthyMark(value, depth)
    depth = depth or 0
    if depth > 6 then return false end
    local valueType = type(value)
    if valueType == 'string' or valueType == 'number' then return containsHealthyMark(value)
    elseif valueType ~= 'table' then return false end
    for _, child in pairs(value) do
        if tableContainsHealthyMark(child, depth + 1) then return true end
    end
    return false
end

local function firstValue(tbl, keys)
    if type(tbl) ~= 'table' then return nil end
    for _, key in ipairs(keys) do
        if tbl[key] ~= nil then return tbl[key] end
    end
    return nil
end

local function valueToBoolean(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'number' then return value ~= 0 end
    if value == nil then return nil end
    local text = ruLower(toCp1251Safe(trim(value)))
    if text == '0' or text == 'false' or text == 'no' or text == cp('нет') or text:find(cp('отсутств'), 1, true) or text:find(cp('не имеется'), 1, true) or text:find(cp('неактив'), 1, true) then return false end
    if text == '1' or text == 'true' or text == 'yes' or text == cp('да') or text == cp('есть') or text:find(cp('имеется'), 1, true) or text:find(cp('актив'), 1, true) then return true end
    return nil
end

local function looksLikeCarLicense(name)
    local text = ruLower(toCp1251Safe(name))
    return text == 'car' or text:find('driv', 1, true) ~= nil or text:find(cp('авто'), 1, true) ~= nil or text:find(cp('водител'), 1, true) ~= nil
end

local function looksLikeGunLicense(name)
    local text = ruLower(toCp1251Safe(name))
    return text == 'gun' or text:find('weapon', 1, true) ~= nil or text:find(cp('оруж'), 1, true) ~= nil
end

local RP_QUESTION_POOL = {
    {id='motivation', short='Причина вступления', text='Почему Вы решили вступить в наши ряды?'},
    {id='before_service', short='До призыва', text='Чем Вы занимались до того, как решили прийти на службу?'},
    {id='strengths', short='Сильные стороны', text='Какие Ваши качества помогут Вам во время службы?'},
    {id='weaknesses', short='Слабые стороны', text='Какие свои слабые стороны Вы можете назвать?'},
    {id='discipline', short='Дисциплина', text='Что для Вас означает дисциплина на службе?'},
    {id='subordination', short='Субординация', text='Как Вы понимаете субординацию и почему она важна?'},
    {id='conflict', short='Конфликт', text='Как Вы поступите, если возникнет конфликт с сослуживцем?'},
    {id='civilian_conflict', short='Конфликт с гражданским', text='Как Вы поведёте себя в конфликтной ситуации с гражданским?'},
    {id='order_disagree', short='Спорный приказ', text='Что Вы будете делать, если получите приказ, с которым не согласны?'},
    {id='order_unclear', short='Непонятный приказ', text='Что Вы сделаете, если не поймёте, как правильно выполнить приказ?'},
    {id='rules_violation', short='Нарушение устава', text='Как Вы поступите, если заметите нарушение устава со стороны сослуживца?'},
    {id='stress', short='Стрессовая ситуация', text='Как Вы обычно действуете в стрессовой ситуации?'},
    {id='teamwork', short='Работа в команде', text='Что для Вас означает хорошая работа в команде?'},
    {id='responsibility', short='Ответственность', text='Как Вы понимаете ответственность военнослужащего?'},
    {id='goals', short='Цели на службе', text='Каких целей Вы хотели бы добиться во время службы?'},
    {id='experience', short='Опыт службы', text='Есть ли у Вас опыт службы или похожей работы? Расскажите о нём.'},
    {id='skills', short='Полезные навыки', text='Какие навыки Вы считаете наиболее полезными для службы?'},
    {id='why_us', short='Почему именно мы', text='Почему Вы выбрали именно нашу организацию?'},
    {id='priorities', short='Приоритеты', text='Что для Вас важнее на службе: личная выгода или интересы подразделения? Почему?'},
    {id='future', short='Планы на будущее', text='Кем Вы видите себя в нашей организации через некоторое время?'},
}

local function refillRpMenuChoices()
    local available = {}
    session.rpAsked = session.rpAsked or {}
    for _, q in ipairs(RP_QUESTION_POOL) do
        if not session.rpAsked[q.id] then available[#available + 1] = q end
    end
    if #available < 5 then
        session.rpAsked = {}
        available = {}
        for _, q in ipairs(RP_QUESTION_POOL) do available[#available + 1] = q end
    end
    for i = #available, 2, -1 do
        local j = math.random(1, i)
        available[i], available[j] = available[j], available[i]
    end
    session.rpMenuChoices = {}
    for i = 1, math.min(5, #available) do session.rpMenuChoices[i] = available[i] end
end

local function openRpQuestionMenu()
    if not session.active then return end
    refillRpMenuChoices()
    session.stage = 'rp_menu'
    session.answers = {}
    session.deadline = 0
    session.rpCurrent = nil
    chatInfo('Выберите RP-вопрос клавишами 1-5 в верхнем ряду клавиатуры. ALT в меню — перейти к проверке терминов.')
end

local function askRpMenuQuestion(index)
    if not session.active or session.stage ~= 'rp_menu' then return end
    index = tonumber(index)
    local q = index and session.rpMenuChoices and session.rpMenuChoices[index] or nil
    if not q then chatInfo('Для этой клавиши сейчас нет вопроса.') return end
    session.rpAsked = session.rpAsked or {}
    session.rpAsked[q.id] = true
    session.rpCurrent = q
    session.stage = 'rp_custom'
    session.answers = {}
    session.deadline = 0
    sendCandidateLine(q.text)
    chatInfo('Задан RP-вопрос: ' .. q.short .. '. Таймера нет. После полного ответа нажмите ALT.')
end

local TERM_QUESTIONS = {
    { code = 'MG', label = 'МГ', first = 'м', second = 'г', forbidden = {'метагейм', 'мета гейм', 'metagaming', 'meta gaming'}, testGood = 'Мирные граждане', testBad = 'Метагейминг', },
    { code = 'PG', label = 'ПГ', first = 'п', second = 'г', forbidden = {'пауэргейм', 'пауэр гейм', 'пауэргейминг', 'пауэр гейминг', 'пауергейм', 'пауер гейм', 'пауергейминг', 'пауер гейминг', 'павергейм', 'павер гейм', 'павергейминг', 'павер гейминг', 'повергейм', 'повер гейм', 'повергейминг', 'повер гейминг', 'powergaming', 'power gaming'}, testGood = 'Полевые госпитали', testBad = 'Пауэр гейминг', },
    { code = 'SK', label = 'СК', first = 'с', second = 'к', forbidden = {'спавнкил', 'спавн кил', 'спаункил', 'спаун кил', 'spawnkill', 'spawn kill'}, testGood = 'Северные корабли', testBad = 'Спавн килл', },
    { code = 'DM', label = 'ДМ', first = 'д', second = 'м', forbidden = {'дезматч', 'дез матч', 'дэсматч', 'дэс матч', 'дэзматч', 'дэз матч', 'deathmatch', 'death match', 'убийство без причины'}, testGood = 'Дорожные машины', testBad = 'Дез матч', },
    { code = 'DB', label = 'ДБ', first = 'д', second = 'б', forbidden = {'драйвбай', 'драйв бай', 'driveby', 'drive by', 'убийство машиной', 'убийство с машины'}, testGood = 'Домашние блюда', testBad = 'Драйв бай', },
}

local function pickTermQuestion(excludeCode)
    local available = {}
    for _, term in ipairs(TERM_QUESTIONS) do
        if not excludeCode or term.code ~= excludeCode then available[#available + 1] = term end
    end
    if #available == 0 then return TERM_QUESTIONS[1] end
    return available[math.random(1, #available)]
end

local function findTermQuestion(code)
    code = tostring(code or ''):upper()
    for _, term in ipairs(TERM_QUESTIONS) do
        if term.code == code then return term end
    end
    return nil
end

local function startSpecificTermQuestion(term)
    if not session.active or type(term) ~= 'table' then return end
    session.stage = 'q2'
    session.answers = {}
    session.deadline = 0 
    session.q2Term = term
    session.q2FirstTermCode = term.code
    sendCandidateLine('Что такое «' .. term.label .. '»?')
    chatInfo('[TEST] Принудительно выбран термин ' .. term.label .. '. Кандидату правило ответа не показывается.')
end

local function beginQuestion(stage)
    if not session.active then return end
    session.stage = stage
    session.answers = {}

    if stage == 'q1' then
        session.deadline = 0
        sendCandidateLine('Расскажите о себе.')
        chatInfo('Ручной режим: таймера нет. Ждите полный ответ и нажмите ALT, когда будете готовы продолжить.')
    elseif stage == 'q2' then
        session.deadline = 0
        session.q2Term = pickTermQuestion(nil)
        session.q2FirstTermCode = session.q2Term.code
        sendCandidateLine('Что такое «' .. session.q2Term.label .. '»?')
        if CONFIG.manualProfessionalCheck then
            chatInfo('Ручная проверка проф.пригодности: термин ' .. session.q2Term.label .. '. Скрипт ответ не оценивает; после вашей проверки нажмите ALT, чтобы принять ответ.')
        else
            chatInfo('Скрытая RP-проверка: термин ' .. session.q2Term.label .. '. Таймера нет; после полного ответа нажмите ALT.')
        end
    elseif stage == 'q2_retry' then
        session.deadline = 0
        session.q2Term = pickTermQuestion(session.q2FirstTermCode)
        local retryCode = session.q2Term.code
        local retryLabel = session.q2Term.label
        local combinedPrompts = {
            'Подумайте ещё. Есть такой бренд «РК» — «Редкие кораллы». Как Вы понимаете сокращение «' .. retryLabel .. '»?',
            'Подумайте ещё. К примеру, есть бренд «БС» — «Белое солнце». Что, по-Вашему, может означать «' .. retryLabel .. '»?',
            'Подумайте ещё. Например, «ЗЛ» — «Золотой лист». С чем у Вас ассоциируется «' .. retryLabel .. '»?',
            'Подумайте ещё. Есть бренд «РК» — «Редкие кораллы». Как бы Вы объяснили значение «' .. retryLabel .. '»?',
            'Подумайте ещё. Например, «БС» — «Белое солнце». Как Вы можете истолковать «' .. retryLabel .. '»?',
        }
        local combinedPrompt = combinedPrompts[math.random(1, #combinedPrompts)]
        session.stage = 'q2_retry_hint'
        sendCandidateLine(combinedPrompt, function()
            if not session.active or session.stage ~= 'q2_retry_hint' then return end
            if not session.q2Term or session.q2Term.code ~= retryCode then return end
            session.stage = 'q2_retry'
            session.answers = {}
            session.deadline = 0
            chatInfo('Задан повторный RP-термин: ' .. retryLabel .. '. Подсказка и вопрос отправлены одной строкой; таймера нет, после полного ответа нажмите ALT.')
        end)
        chatInfo('Первая проверка термина не пройдена. Подсказка и повторный Q2 отправляются кандидату одним сообщением.')
    elseif stage == 'q3' then
        session.deadline = 0
        sendCandidateLine('Что у меня над головой?')
        chatInfo('Таймера нет. После полного ответа нажмите ALT для проверки.')
    end
end

local function joinedAnswers()
    return trim(table.concat(session.answers or {}, ' '))
end

local function validateTermAnswer(answer, term)
    if type(term) ~= 'table' then return false end
    local lower = ruLower(answer)
    for _, bad in ipairs(term.forbidden or {}) do
        local needle = bad
        local hasNonAscii = false
        for i = 1, #needle do
            if needle:byte(i) >= 128 then hasNonAscii = true break end
        end
        if hasNonAscii then needle = cp(needle) end
        if lower:find(ruLower(needle), 1, true) then return false end
    end
    local normalized = toCp1251Safe(answer)
    local words = splitWords(normalized)
    if #words < 2 then return false end
    local firstExpected = ruLower(cp(term.first))
    local secondExpected = ruLower(cp(term.second))
    local function startsWith(word, expected)
        word = ruLower(tostring(word or ''))
        return word ~= '' and word:sub(1, #expected) == expected
    end
    for i = 1, #words - 1 do
        if startsWith(words[i], firstExpected) and startsWith(words[i + 1], secondExpected) then return true end
    end
    for i = 1, #words do
        if startsWith(words[i], firstExpected) then
            local last = math.min(#words, i + 3)
            for j = i + 1, last do
                if startsWith(words[j], secondExpected) then return true end
            end
        end
    end
    return false
end

RECRUIT_ABOVE_HEAD_FORBIDDEN = {
    cp('ник'), cp('никнейм'), cp('имя'), cp('айди'), cp('ид'),
    cp('хп'), cp('брон'), cp('броня'), cp('армор'), cp('здоров'), cp('полос'),
    cp('уровень'), cp('левел'), cp('вип'), 'level', 'vip', 'vip level', 'level vip',
    cp('семья'), cp('семей'), cp('семейка'), cp('семейный тег'), cp('тег семьи'), cp('семейный флаг'), cp('флаг семьи'), cp('флаг'), 'family', 'family tag', 'family flag',
    cp('аддшка'), cp('адд'), cp('адд вип'), cp('аддвип'), 'add', 'add vip', 'addvip',
    cp('сейфзона'), cp('сейф зона'), cp('сейф-зона'), 'safezone', 'safe zone', 'safe-zone',
    cp('бодикамера'), cp('бодикамер'), cp('значок бодикамеры'), cp('значок'), cp('иконка'), cp('икон'), 'bodycam', 'body cam', 'bodycamera', 'icon',
    cp('выключенный звук'), cp('звук выключен'), cp('без звука'), cp('звук'), cp('голосовой чат'), cp('голосовой'), 'sound off', 'soundoff', 'mute', 'muted', 'voice chat', 'voice',
    cp('выключенный микрофон'), cp('микрофон выключен'), cp('микрофон'), cp('микроофф'), cp('микро офф'), cp('микро-off'), cp('микро'), 'microoff', 'mic off', 'micoff', 'mute mic', 'muted mic',
    cp('афк'), cp('пауза'), 'afk', 'pause',
    'nickname', 'name', 'id', 'hp', 'health', 'armor', 'armour'
}

local function validateAboveHead(answer)
    local lower = ruLower(trim(answer))
    if lower == '' then return false end
    for _, word in ipairs(RECRUIT_ABOVE_HEAD_FORBIDDEN) do
        if lower:find(word, 1, true) then return false end
    end
    local selfOk, selfId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if selfOk then
        local selfName = ruLower(sampGetPlayerNickname(selfId) or '')
        if selfName ~= '' then
            if lower:find(selfName, 1, true) or lower:find(selfName:gsub('_', ' '), 1, true) then return false end
        end
    end
    return true
end

function showRecruitExceptions(arg)
    local mode = ruLower(trim(arg or ''))
    if mode == '' then
        chatInfo('Исключения: /rexceptions head | yes | no | all')
        chatInfo('head = «Что у меня над головой?», yes/no = варианты согласия/отказа. Алиас: /rvariants.')
        return
    end

    local function printList(title, values)
        chatInfo(title)
        local line = ''
        for _, value in ipairs(values) do
            local item = tostring(value)
            local candidate = line == '' and item or (line .. ', ' .. item)
            if line ~= '' and #cp(candidate) > 105 then
                chatInfo(line)
                line = item
            else
                line = candidate
            end
        end
        if line ~= '' then chatInfo(line) end
    end

    local showHead = mode == 'head' or mode == 'above' or mode == cp('голова') or mode == cp('надголовой') or mode == cp('над головой') or mode == 'all'
    local showYes = mode == 'yes' or mode == cp('да') or mode == 'all'
    local showNo = mode == 'no' or mode == cp('нет') or mode == 'all'

    if not showHead and not showYes and not showNo then
        chatInfo('Неизвестная группа. Используйте: /rexceptions head | yes | no | all')
        return
    end

    if showHead then
        local values = {
            'ник', 'никнейм', 'имя', 'айди', 'ид', 'id', 'nickname', 'name', 'хп', 'hp', 'health', 'здоровье', 'полоска здоровья', 'броня', 'брон', 'армор', 'armor', 'armour', 'уровень', 'левел', 'level', 'вип', 'vip', 'vip level', 'level vip', 'семья', 'семейка', 'семейный тег', 'тег семьи', 'family', 'family tag', 'семейный флаг', 'флаг семьи', 'флаг', 'family flag', 'аддшка', 'адд', 'адд вип', 'аддвип', 'add', 'add vip', 'addvip', 'сейфзона', 'сейф зона', 'сейф-зона', 'safezone', 'safe zone', 'safe-zone', 'бодикамера', 'бодикамеры', 'значок бодикамеры', 'bodycam', 'body cam', 'bodycamera', 'значок', 'иконка', 'icon', 'выключенный звук', 'звук выключен', 'без звука', 'звук', 'sound off', 'soundoff', 'mute', 'muted', 'голосовой чат', 'voice chat', 'выключенный микрофон', 'микрофон выключен', 'микрофон', 'микроофф', 'микро офф', 'microoff', 'mic off', 'micoff', 'mute mic', 'muted mic', 'афк', 'afk', 'пауза', 'pause'
        }
        printList('Не засчитывается на «Что у меня над головой?»: ', values)
    end
    if showYes then
        local values = {'да', 'ага', 'угу', 'конечно', 'готов', 'готова', 'давай', 'погнали', 'точно', 'есть', 'согласен', 'согласна', 'разумеется', 'безусловно', 'верно', 'ес', 'йес', 'жа', 'дэ', 'йа', 'дас', 'yes', 'yeah', 'yep', 'ye', 'y', 'ok', 'okay', 'affirmative', 'так точно', 'готов служить', 'готова служить', 'готов к призыву', 'готова к призыву', 'согласен на призыв', 'согласна на призыв', 'на призыв', 'нда', 'дда', 'даа', 'ддаа', 'дп', 'даж', 'yess', 'yees', 'yse', 'ys'}
        printList('Варианты, которые засчитываются как «ДА»:', values)
    end
    if showNo then
        local values = {'нет', 'не', 'неа', 'отказываюсь', 'не хочу', 'no', 'nope', 'nah'}
        printList('Варианты, которые блокируют «ДА» / считаются отказом:', values)
    end
end

local function finishSuccess()
    if not isTargetAvailable() then
        chatInfo('Кандидат вышел из игры до завершения проверки.')
        clearSession('target disconnected')
        return
    end

    local id = session.targetId
    local name = session.targetName
    local isTest = session.testMode
    session.stage = 'finished'

    if isTest then
        sendCandidateLine(rpPhrase('success'))
        if CONFIG.autoInvite then enqueueOutbound('/inv ' .. tostring(id), 'local_command', true, ' — реальная команда НЕ отправлена.')
        else chatInfo('[TEST] Автоматический /inv отключён.') end
        clearSession('test success')
        return
    end

    sendCandidateLine(rpPhrase('success'))
    if CONFIG.autoInvite and sampIsPlayerConnected(id) then
        sendLocalCommand('/inv ' .. tostring(id))
        chatInfo(string.format('Локальная команда /inv %d поставлена в очередь для хелпера (%s).', id, name))
    else
        chatInfo(string.format('Проверка %s[%d] завершена. Автоприглашение отключено.', name, id))
    end
    clearSession('success')
end

local function failProfessional(reason)
    debugLog('Professional check failed: ' .. tostring(reason))
    stopWithMessage(rpPhrase('professional_fail'))
end

local function evaluateDocuments()
    if not session.active or not session.docs then return end
    local d = session.docs
    if not (d.gotPassport and d.gotLicenses and d.gotMedical) then return end

    local problems = {}
    local function addProblem(code, privateText, rpText)
        problems[#problems + 1] = {code = code, private = privateText, rp = rpText}
    end

    if session.targetName and d.name and ruLower(d.name) ~= ruLower(session.targetName) then
        addProblem('wrong_owner', 'предъявлены документы другого человека', rpPhrase('wrong_owner'))
    end

    if CONFIG.blockBadNicknameFormat and session.nickCheck and session.nickCheck.localValid == false then
        addProblem('bad_nickname_format', 'ник кандидата не соответствует формату RP Name_Surname', rpPhrase('bad_nickname_format'))
    elseif CONFIG.strictRpNicknameOnline and session.nickCheck and session.nickCheck.onlineSuspicious == true then
        addProblem('bad_nickname_online', 'онлайн-проверка Namespedia пометила имя или фамилию как сомнительные', rpPhrase('bad_nickname_online'))
    end

    if d.years == nil then addProblem('years_unknown', 'не удалось считать количество лет в штате', rpPhrase('years_unknown'))
    elseif d.years < 3 then addProblem('low_years', 'лет в штате: ' .. tostring(d.years) .. ' (требуется минимум 3)', rpPhrase('low_years')) end

    if d.law == nil then addProblem('law_unknown', 'не удалось считать законопослушность', rpPhrase('law_unknown'))
    elseif d.law < 35 then addProblem('low_law', 'законопослушность: ' .. tostring(d.law) .. ' (требуется минимум 35)', rpPhrase('low_law')) end

    if d.car == false then addProblem('no_car_license', 'отсутствует лицензия на вождение автомобиля', rpPhrase('no_car_license'))
    elseif d.car == nil then addProblem('car_unknown', 'не удалось определить наличие лицензии на автомобиль', rpPhrase('car_unknown')) end

    if d.gun == nil then addProblem('gun_unknown', 'не удалось определить наличие лицензии на оружие', rpPhrase('gun_unknown')) end

    if d.medicalExists == false then
        addProblem('no_medical_card', 'медицинская карта отсутствует', rpPhrase('no_medical_card'))
    elseif d.medicalExists == nil then
        addProblem('medical_unknown', 'не удалось определить наличие медицинской карты', rpPhrase('medical_unknown'))
    else
        if d.health ~= true then addProblem('bad_health', 'в медкарте нет пометки «Полностью здоров»', rpPhrase('bad_health')) end
        if d.dependency == nil then addProblem('dependency_unknown', 'не удалось определить показатель зависимости от укропа', rpPhrase('dependency_unknown'))
        elseif d.dependency > 5 then addProblem('high_dependency', 'зависимость от укропа: ' .. tostring(d.dependency) .. ' (допустимо до 5 включительно)', rpPhrase('high_dependency')) end
    end

    if #problems > 0 then
        chatInfo('Кандидат НЕ прошёл проверку документов. Причины видны только вам:')
        local rpLines = {}
        for _, problem in ipairs(problems) do
            chatInfo('• ' .. problem.private .. '.')
            if problem.rp and problem.rp ~= '' then rpLines[#rpLines + 1] = problem.rp end
        end
        sendCandidateLines(rpLines)
        clearSession('documents failed')
        return
    end

    session.stage = 'documents_passed'
    local function continueAfterDocuments()
        if d.gun == false then sendCandidateLine(rpPhrase('no_gun_license')) else sendCandidateLine(rpPhrase('docs_ok')) end
        beginQuestion('q1')
    end
    continueAfterDocuments()
end

local function parseLicenses(data)
    local car = valueToBoolean(firstValue(data, {'car', 'carLicense', 'driverLicense', 'driving'}))
    local gun = valueToBoolean(firstValue(data, {'gun', 'gunLicense', 'weaponLicense', 'weapon'}))
    local list = firstValue(data, {'info', 'licenses', 'license', 'items'})

    if type(list) == 'table' then
        for key, item in pairs(list) do
            local licenseName, available
            if type(item) == 'table' then
                licenseName = firstValue(item, {'license', 'name', 'type', 'title', 'key'}) or key
                available = firstValue(item, {'available', 'status', 'active', 'value', 'has'})
            else
                licenseName = key
                available = item
            end
            if looksLikeCarLicense(licenseName) then
                local parsed = valueToBoolean(available)
                if parsed ~= nil then car = parsed end
            elseif looksLikeGunLicense(licenseName) then
                local parsed = valueToBoolean(available)
                if parsed ~= nil then gun = parsed end
            end
        end
    end
    return car, gun
end

local function cefContextLooksLikeDocuments(context)
    context = context or {}
    if context.documentEvent == true then return true end
    local eventName = ruLower(tostring(context.eventName or ''))
    if eventName ~= '' then
        if eventName:find('document', 1, true) or eventName:find('passport', 1, true) or eventName:find('license', 1, true) or eventName:find('medical', 1, true) then return true end
    end
    return context.rawLooksDocument == true
end

local function documentStageAllows(kind)
    if session.testMode then return true end
    if kind == 'passport' then return session.stage == 'wait_documents' and session.docs and not session.docs.gotPassport
    elseif kind == 'licenses' then return session.stage == 'documents_passport' and session.docs and session.docs.gotPassport and not session.docs.gotLicenses
    elseif kind == 'medical' then return session.stage == 'documents_licenses' and session.docs and session.docs.gotPassport and session.docs.gotLicenses and not session.docs.gotMedical end
    return false
end

local function ignoreDocumentCandidate(reason, docType)
    debugLog('CEF document candidate ignored: ' .. tostring(reason) .. ', type=' .. tostring(docType) .. ', stage=' .. tostring(session.stage))
    return false
end

local function handleDocumentData(data, context)
    if not session.active or type(data) ~= 'table' or not session.docs then return false end
    context = context or {}
    if session.testMode then context.documentEvent = true end

    local docType = tonumber(firstValue(data, {'type', 'documentType', 'docType', 'page'}))
    local yearsValue = firstValue(data, {'level', 'years', 'yearsInState', 'stateYears', 'let'})
    local lawValue = firstValue(data, {'zakono', 'law', 'lawfulness', 'legal', 'zakonoposlushnost'})
    local healthValue = firstValue(data, {'state', 'health', 'healthState', 'healthStatus'})
    local dependencyValue = firstValue(data, {'zavisimost', 'dependency', 'addiction', 'ukrop', 'ukropDependency'})
    local docsContext = cefContextLooksLikeDocuments(context)

    local passportYears = parseFirstNumber(yearsValue)
    local passportLaw = parseFirstNumber(lawValue)
    local strongPassport = passportYears ~= nil and passportLaw ~= nil
    local isPassport = strongPassport

    local hasLicenseContainer = firstValue(data, {'info', 'licenses', 'license', 'items'}) ~= nil
    local parsedCar, parsedGun = parseLicenses(data)
    local strongLicenses = hasLicenseContainer or parsedCar ~= nil or parsedGun ~= nil
    local isLicenses = strongLicenses and not (healthValue ~= nil or dependencyValue ~= nil)

    local explicitMedicalMarker = firstValue(data, {'medicalExists', 'hasMedical', 'hasMedicalCard', 'hasMedCard', 'hasCard'})
    local strongMedical = healthValue ~= nil or dependencyValue ~= nil or explicitMedicalMarker ~= nil
    local isMedical = strongMedical or (docType == 4 and documentStageAllows('medical') and docsContext)

    if docType == 1 and not strongPassport then return ignoreDocumentCandidate('type=1 without passport fields (likely character/inventory CEF)', docType) end

    if isPassport then
        if not documentStageAllows('passport') then return ignoreDocumentCandidate('passport arrived outside wait_documents or already captured', docType) end
        session.docs.name = firstValue(data, {'name', 'nickname', 'playerName', 'fio'})
        session.docs.years = passportYears
        session.docs.law = passportLaw
        session.docs.gotPassport = true
        session.stage = 'documents_passport'
        session.deadline = 0 
        debugLog(string.format('Passport captured: name=%s, years=%s, law=%s, type=%s', tostring(session.docs.name), tostring(session.docs.years), tostring(session.docs.law), tostring(docType)))
        chatInfo(string.format('Паспорт считан: лет в штате — %s, законопослушность — %s.', tostring(session.docs.years or '?'), tostring(session.docs.law or '?')))
        requestDocumentPage(2)
        return true
    end

    if docType == 2 and not strongLicenses then return ignoreDocumentCandidate('type=2 without license fields/container', docType) end

    if isLicenses then
        if not documentStageAllows('licenses') then return ignoreDocumentCandidate('licenses arrived outside documents_passport or already captured', docType) end
        local car, gun = parsedCar, parsedGun
        if docType == 2 and hasLicenseContainer then
            if car == nil then car = false end
            if gun == nil then gun = false end
        end
        session.docs.car = car
        session.docs.gun = gun
        session.docs.gotLicenses = car ~= nil or gun ~= nil or hasLicenseContainer
        if not session.docs.gotLicenses then return ignoreDocumentCandidate('license data contained no recognizable values', docType) end
        session.stage = 'documents_licenses'
        session.deadline = 0 
        debugLog(string.format('Licenses captured: car=%s, gun=%s, type=%s', tostring(car), tostring(gun), tostring(docType)))
        local carLabel = session.docs.car == true and 'есть' or (session.docs.car == false and 'нет' or 'не определено')
        local gunLabel = session.docs.gun == true and 'есть' or (session.docs.gun == false and 'нет' or 'не определено')
        chatInfo('Лицензии считаны: авто — ' .. carLabel .. ', оружие — ' .. gunLabel .. '.')
        requestDocumentPage(4)
        return true
    end

    if docType == 4 and not isMedical then return ignoreDocumentCandidate('type=4 without medical fields and without document CEF context', docType) end

    if isMedical then
        if not documentStageAllows('medical') then return ignoreDocumentCandidate('medical data arrived outside documents_licenses or already captured', docType) end
        local explicitExists = valueToBoolean(firstValue(data, {'medicalExists', 'hasMedical', 'hasMedicalCard', 'hasMedCard', 'hasCard', 'exists', 'available'}))
        local healthText = ruLower(toCp1251Safe(trim(healthValue or '')))
        local parsedHealth, healthCode = parseMedicalHealthStatus(healthValue)
        local explicitMissing = healthCode == -1 or healthText:find(cp('отсутств'), 1, true) ~= nil or healthText:find(cp('не имеется'), 1, true) ~= nil or healthText:find(cp('нет мед'), 1, true) ~= nil or healthText:find('no medical', 1, true) ~= nil

        local medicalExists = explicitExists
        if explicitMissing then medicalExists = false
        elseif medicalExists == nil then
            if healthValue ~= nil or dependencyValue ~= nil then medicalExists = true
            elseif docType == 4 and docsContext then medicalExists = false end
        end

        session.docs.medicalExists = medicalExists
        if medicalExists == false then
            session.docs.health = nil
            session.docs.dependency = nil
        else
            session.docs.health = parsedHealth
            if session.docs.health ~= true and tableContainsHealthyMark(data) then session.docs.health = true end
            session.docs.dependency = parseFirstNumber(dependencyValue)
        end
        session.docs.gotMedical = true
        session.stage = 'documents_complete'
        debugLog(string.format('Medical captured: exists=%s, state=%s, healthCode=%s, healthy=%s, dependency=%s, type=%s', tostring(session.docs.medicalExists), tostring(healthValue), tostring(healthCode), tostring(session.docs.health), tostring(session.docs.dependency), tostring(docType)))
        if session.docs.medicalExists == false then chatInfo('Медкарта: отсутствует.')
        else
            local healthLabel = session.docs.health == true and 'полностью здоров' or 'не подходит'
            chatInfo('Медкарта считана: здоровье — ' .. healthLabel .. ', зависимость — ' .. tostring(session.docs.dependency or '?') .. '.')
        end
        evaluateDocuments()
        return true
    end

    debugLog('CEF JSON received, but document type was not recognized.')
    return false
end

local function extractCefEvent(raw)
    raw = tostring(raw or '')
    local eventName, payload = raw:match("executeEvent%s*%(%s*'([^']+)'%s*,%s*`(.-)`%s*%)")
    if eventName then return eventName, payload end
    eventName, payload = raw:match('executeEvent%s*%(%s*"([^"]+)"%s*,%s*`(.-)`%s*%)')
    if eventName then return eventName, payload end
    eventName, payload = raw:match("executeEvent%s*%(%s*'([^']+)'%s*,%s*'(.-)'%s*%)")
    if eventName then return eventName, payload end
    eventName, payload = raw:match('executeEvent%s*%(%s*"([^"]+)"%s*,%s*"(.-)"%s*%)')
    if eventName then return eventName, payload end
    return nil, nil
end

local function jsUnescapeForJson(text)
    text = tostring(text or '')
    text = text:gsub('\\"', '"')
    text = text:gsub("\\'", "'")
    return text
end

local function balancedJsonAt(text, startPos)
    local stack = {}
    local inString, escaped = false, false
    for i = startPos, #text do
        local ch = text:sub(i, i)
        if inString then
            if escaped then escaped = false elseif ch == '\\' then escaped = true elseif ch == '"' then inString = false end
        else
            if ch == '"' then inString = true
            elseif ch == '{' or ch == '[' then stack[#stack + 1] = ch
            elseif ch == '}' or ch == ']' then
                local expected = ch == '}' and '{' or '['
                if stack[#stack] ~= expected then return nil end
                stack[#stack] = nil
                if #stack == 0 then return text:sub(startPos, i) end
            end
        end
    end
    return nil
end

local function collectJsonCandidates(text)
    local result, seen = {}, {}
    text = tostring(text or '')
    local stripped = trim(text)
    if stripped:sub(1, 1) == '{' or stripped:sub(1, 1) == '[' then
        result[#result + 1] = stripped
        seen[stripped] = true
    end
    local count = 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == '{' or ch == '[' then
            local candidate = balancedJsonAt(text, i)
            if candidate and #candidate <= 131072 and (candidate:find('"type"%s*:') or candidate:find('"documentType"%s*:')) and not seen[candidate] then
                result[#result + 1] = candidate
                seen[candidate] = true
                count = count + 1
                if count >= 16 then break end
            end
        end
    end
    return result
end

local function findDocumentObject(node, depth)
    if type(node) ~= 'table' or (depth or 0) > 6 then return nil end
    local numericType = tonumber(firstValue(node, {'type', 'documentType', 'docType', 'page'}))
    if numericType == 1 or numericType == 2 or numericType == 4 or firstValue(node, {'zakono', 'lawfulness', 'yearsInState', 'zavisimost', 'ukropDependency'}) ~= nil or firstValue(node, {'healthState', 'healthStatus', 'licenses'}) ~= nil then return node end
    for _, key in ipairs({'data', 'payload', 'document', 'documents', 'args', 'result'}) do
        local found = findDocumentObject(node[key], (depth or 0) + 1)
        if found then return found end
    end
    for _, value in pairs(node) do
        if type(value) == 'table' then
            local found = findDocumentObject(value, (depth or 0) + 1)
            if found then return found end
        end
    end
    return nil
end

local function decodeAndHandleJson(candidate, context)
    local ok, decoded = pcall(decodeJson, candidate)
    if not ok or type(decoded) ~= 'table' then return false end
    local data = findDocumentObject(decoded, 0)
    if data then return handleDocumentData(data, context) end
    return false
end

local function handleCefRaw(raw)
    raw = tostring(raw or '')
    if raw == '' then return false end
    local lowerRaw = ruLower(raw)
    local rawLooksDocument = lowerRaw:find('document', 1, true) ~= nil or lowerRaw:find('passport', 1, true) ~= nil or lowerRaw:find('license', 1, true) ~= nil or lowerRaw:find('medical', 1, true) ~= nil
    local eventName, payload = extractCefEvent(raw)
    if eventName then
        debugLog('CEF event: ' .. tostring(eventName))
        local context = {eventName = eventName, rawLooksDocument = rawLooksDocument}
        context.documentEvent = cefContextLooksLikeDocuments(context)
        if payload and decodeAndHandleJson(payload, context) then return true end
        if payload and decodeAndHandleJson(jsUnescapeForJson(payload), context) then return true end
    end
    local context = {rawLooksDocument = rawLooksDocument}
    local variants = {raw, jsUnescapeForJson(raw)}
    for _, variant in ipairs(variants) do
        for _, candidate in ipairs(collectJsonCandidates(variant)) do
            if decodeAndHandleJson(candidate, context) then return true end
        end
    end
    return false
end

local function packetSnippet(raw)
    raw = tostring(raw or ''):sub(1, 1200)
    return (raw:gsub('[%z\1-\8\11\12\14-\31\127-\255]', function(ch) return string.format('\\x%02X', ch:byte()) end))
end

local function getBitstreamBitsUsedSafe(bs)
    local okBits, bits = pcall(function()
        if type(raknetBitStreamGetNumberOfBitsUsed) == 'function' then return raknetBitStreamGetNumberOfBitsUsed(bs) end
        return nil
    end)
    if okBits and type(bits) == 'number' and bits > 0 then return bits end
    local okBytes, bytes = pcall(function() return raknetBitStreamGetNumberOfBytesUsed(bs) end)
    if okBytes and type(bytes) == 'number' and bytes > 0 then return bytes * 8 end
    return nil
end

local function getBitstreamReadOffsetSafe(bs)
    local ok, offset = pcall(function() return raknetBitStreamGetReadOffset(bs) end)
    if ok and type(offset) == 'number' then return offset end
    return nil
end

local function setBitstreamReadOffsetSafe(bs, offset)
    if type(offset) ~= 'number' or offset < 0 then return false end
    local ok = pcall(function() raknetBitStreamSetReadOffset(bs, offset) end)
    return ok
end

local function tryParseArizonaPacket(bs, offset, layout, bitsUsed)
    if type(offset) ~= 'number' or type(bitsUsed) ~= 'number' then return nil end
    if offset < 0 or offset + 8 > bitsUsed then return nil end
    if not setBitstreamReadOffsetSafe(bs, offset) then return nil end
    local function remainingBits()
        local current = getBitstreamReadOffsetSafe(bs)
        if not current then return 0 end
        return math.max(0, bitsUsed - current)
    end
    if remainingBits() < 8 then return nil end
    local subtype = raknetBitStreamReadInt8(bs)
    if subtype ~= 17 then return nil end
    if layout.serverId then
        if remainingBits() < 32 then return nil end
        raknetBitStreamReadInt32(bs)
    end
    local length, encoded
    if layout.encodedFirst then
        if remainingBits() < 8 then return nil end
        encoded = raknetBitStreamReadInt8(bs)
        local lengthBits = layout.length32 and 32 or 16
        if remainingBits() < lengthBits then return nil end
        length = layout.length32 and raknetBitStreamReadInt32(bs) or raknetBitStreamReadInt16(bs)
    else
        local lengthBits = layout.length32 and 32 or 16
        if remainingBits() < lengthBits then return nil end
        length = layout.length32 and raknetBitStreamReadInt32(bs) or raknetBitStreamReadInt16(bs)
        if remainingBits() < 8 then return nil end
        encoded = raknetBitStreamReadInt8(bs)
    end
    local maxPayload = tonumber(CONFIG.maxCefPayloadBytes) or 65536
    if type(length) ~= 'number' or length <= 0 or length > maxPayload then return nil end
    if encoded ~= 1 and remainingBits() < length * 8 then return nil end
    if encoded == 1 then
        if remainingBits() <= 0 then return nil end
        return raknetBitStreamDecodeString(bs, length)
    end
    return raknetBitStreamReadString(bs, length)
end

function onReceivePacket(id, bs)
    if id ~= 220 or not session.active then return end
    local originalOffset = getBitstreamReadOffsetSafe(bs)
    local bitsUsed = getBitstreamBitsUsedSafe(bs)
    if not originalOffset or not bitsUsed or bitsUsed <= 0 then return end
    local maxPayload = tonumber(CONFIG.maxCefPayloadBytes) or 65536
    if bitsUsed > (maxPayload + 64) * 8 then
        debugLog('Packet 220 ignored: bitstream is too large (' .. tostring(bitsUsed) .. ' bits).')
        return
    end
    session.packetCount = (session.packetCount or 0) + 1
    local offsets, seenOffsets = {originalOffset, 0, 8}, {}
    local layouts = {
        {serverId = true, encodedFirst = false, length32 = false},
        {serverId = true, encodedFirst = true,  length32 = false},
        {serverId = true, encodedFirst = false, length32 = true},
        {serverId = false, encodedFirst = false, length32 = false},
    }
    for _, offset in ipairs(offsets) do
        if not seenOffsets[offset] and offset >= 0 and offset < bitsUsed then
            seenOffsets[offset] = true
            for _, layout in ipairs(layouts) do
                local ok, decoded = pcall(tryParseArizonaPacket, bs, offset, layout, bitsUsed)
                if ok and type(decoded) == 'string' and decoded ~= '' then
                    if CONFIG.packetLog and session.packetCount <= (tonumber(CONFIG.packetLogLimit) or 40) then debugLog('Packet 220 decoded: ' .. packetSnippet(decoded)) end
                    local handledOk, handled = pcall(handleCefRaw, decoded)
                    if handledOk and handled then
                        setBitstreamReadOffsetSafe(bs, originalOffset)
                        return
                    elseif not handledOk then
                        debugLog('CEF payload handler failed: ' .. tostring(handled))
                    end
                end
            end
        end
    end
    setBitstreamReadOffsetSafe(bs, originalOffset)
end

local function messageIsFromTarget(clean)
    if not session.targetName then return false end
    local name = session.targetName
    local spaced = name:gsub('_', ' ')
    return clean:find(name, 1, true) ~= nil or clean:find(spaced, 1, true) ~= nil
end

local function extractTargetSpeech(clean)
    local body = clean:match(':%s*(.+)$')
    return trim(body or '')
end

local function appendInterviewAnswer(body)
    if body == '' then return end
    session.answers[#session.answers + 1] = body
    session.deadline = 0
end

local function isNrpChatText(text)
    text = trim(stripColors(tostring(text or '')))
    if text == '' then return false end
    if text:match('^%(%(') then return true end
    return false
end

local function handleTargetSpeech(body)
    body = trim(body or '')
    if body == '' or not session.active then return end
    local now = os.clock()
    if session.lastSpeechBody == body and now - (session.lastSpeechAt or 0) < 0.8 then return end
    session.lastSpeechBody = body
    session.lastSpeechAt = now
    debugLog('Target speech [' .. tostring(session.stage) .. ']: ' .. body)

    if session.stage == 'wait_consent' then
        if answerLooksNegative(body) then stopWithMessage(rpPhrase('consent_negative'))
        elseif isPositiveConsent(body) then
            session.stage = 'wait_offer'
            session.deadline = 0 
            sendCandidateLines({rpPhrase('docs_request')})
            sendShowPassInstruction(1)
            chatInfo('Положительный ответ получен. Ожидаю предложение документов от ' .. session.targetName .. '.')
        end
        return
    end

    if session.stage == 'q1' or session.stage == 'rp_custom' or session.stage == 'q2' or session.stage == 'q2_retry' or session.stage == 'q3' then
        appendInterviewAnswer(body)
    end
end

function sampev.onSendGiveDamage(playerId, damage, weapon, bodypart)
    checkProtectedHit(tonumber(playerId))
end

function sampev.onChatMessage(playerId, text)
    if session.active and tonumber(playerId) == tonumber(session.targetId) then
        if isNrpChatText(text) then debugLog('Ignored target NRP chat: ' .. tostring(text)) return end
        handleTargetSpeech(text)
    end
end

function sampev.onServerMessage(color, text)
    autoVoisHandleServerMessage(color, text)
    if not session.active then return end
    local clean = stripColors(text)
    if isNrpChatText(clean) then
        if messageIsFromTarget(clean) then debugLog('Ignored target NRP server message: ' .. tostring(clean)) end
        return
    end

    if session.stage == 'wait_offer' then
        local lower = ruLower(clean)
        local offerMarker = cp('вам поступило предложение от игрока')
        if lower:find(offerMarker, 1, true) and messageIsFromTarget(clean) then
            session.stage = 'wait_documents'
            session.deadline = 0 
            chatInfo('Предложение документов найдено.')
            if CONFIG.autoAcceptOffer then
                scheduleAction(250, function()
                    if session.active and session.stage == 'wait_documents' then
                        sendGameCommand('/offer')
                        chatInfo('Команда /offer поставлена в очередь. Ожидаю паспорт.')
                    end
                end)
            else chatInfo('Примите предложение командой /offer или клавишей X.') end
            return
        end
    end

    if not messageIsFromTarget(clean) then return end
    local body = extractTargetSpeech(clean)
    if body ~= '' then handleTargetSpeech(body) end
end

local function processCurrentTermAnswer()
    local answer = joinedAnswers()
    if answer == '' then
        chatInfo('Кандидат ещё не дал ответ на термин. Жду ответ; таймера нет.')
        return
    end
    if CONFIG.manualProfessionalCheck then
        chatInfo('Ручной режим: ответ подтверждён вами. Автопроверка отключена; перехожу к финальному вопросу.')
        beginQuestion('q3')
        return
    end
    if validateTermAnswer(answer, session.q2Term) then beginQuestion('q3')
    elseif session.stage == 'q2' then
        session.q2Retry = true
        beginQuestion('q2_retry')
    else
        local code = session.q2Term and session.q2Term.code or 'unknown'
        failProfessional('wrong RP-term answer: ' .. tostring(code))
    end
end

local function manualAdvanceInterview()
    if not session.active then chatInfo('Активной проверки нет.') return end
    local stage = session.stage
    if stage == 'q1' then openRpQuestionMenu()
    elseif stage == 'rp_custom' then openRpQuestionMenu()
    elseif stage == 'rp_menu' then beginQuestion('q2')
    elseif stage == 'q2' or stage == 'q2_retry' then processCurrentTermAnswer()
    elseif stage == 'q2_retry_hint' then chatInfo('Подождите отправки следующего термина после антифлуд-паузы.')
    elseif stage == 'q3' then
        local answer = joinedAnswers()
        if answer == '' then chatInfo('Кандидат ещё не дал ответ на последний вопрос. Жду ответ; таймера нет.')
        elseif validateAboveHead(answer) then finishSuccess()
        else failProfessional('wrong above-head answer') end
    else chatInfo('ALT используется на этапе собеседования после проверки документов.') end
end

local interviewHudFont = nil
local interviewHudFontFailed = false

local function ensureInterviewHudFont()
    if interviewHudFont or interviewHudFontFailed or not CONFIG.interviewHud then return interviewHudFont ~= nil end
    if type(renderCreateFont) ~= 'function' then
        interviewHudFontFailed = true
        debugLog('HUD: renderCreateFont недоступен.')
        return false
    end
    local ok, font = pcall(renderCreateFont, 'Arial', tonumber(CONFIG.interviewHudFontSize) or 10, 5)
    if ok and font then
        interviewHudFont = font
        return true
    end
    interviewHudFontFailed = true
    debugLog('HUD font create failed: ' .. tostring(font))
    return false
end

local function getInterviewHudLines()
    if not session.active then return nil end
    local stage = session.stage
    local lines = {}
    if stage == 'wait_consent' then lines = {'RECRUIT', 'Сейчас: «Здравия желаю, Вы на призыв?»', 'Следующее: дождаться ответа'}
    elseif stage == 'wait_offer' then lines = {'RECRUIT', 'Следующее: кандидат передаёт документы', 'Ожидание без таймера'}
    elseif stage == 'wait_documents' then lines = {'RECRUIT', 'Следующее: паспорт', 'Ожидание CEF без таймера'}
    elseif stage == 'documents_passport' then lines = {'RECRUIT', 'Паспорт проверен', 'Следующее: открыть лицензии'}
    elseif stage == 'documents_licenses' then lines = {'RECRUIT', 'Лицензии проверены', 'Следующее: открыть медкарту'}
    elseif stage == 'q1' then lines = {'СОБЕСЕДОВАНИЕ', 'Сейчас: рассказ о себе', 'ALT: выбрать следующий RP-вопрос'}
    elseif stage == 'rp_menu' then
        lines = {'ВЫБОР RP-ВОПРОСА'}
        for i = 1, 5 do
            local q = session.rpMenuChoices and session.rpMenuChoices[i] or nil
            lines[#lines + 1] = q and (tostring(i) .. ': ' .. q.short) or (tostring(i) .. ': —')
        end
        lines[#lines + 1] = 'ALT: перейти к терминам'
    elseif stage == 'rp_custom' then
        local short = session.rpCurrent and session.rpCurrent.short or 'RP-вопрос'
        lines = {'СОБЕСЕДОВАНИЕ', 'Сейчас: ' .. short, 'Таймера нет', 'ALT: выбор следующего вопроса'}
    elseif stage == 'q2' or stage == 'q2_retry' then
        local label = session.q2Term and session.q2Term.label or 'термин'
        local action = CONFIG.manualProfessionalCheck and 'ALT: принять ответ вручную' or 'ALT: проверить полный ответ'
        lines = {'ПРОВЕРКА ТЕРМИНА', 'Сейчас: «' .. label .. '»', 'Таймера нет', action}
    elseif stage == 'q2_retry_hint' then lines = {'ПРОВЕРКА ТЕРМИНА', 'Подсказка отправлена', 'Следующий термин через антифлуд-паузу'}
    elseif stage == 'q3' then lines = {'ФИНАЛЬНЫЙ ВОПРОС', 'Что у меня над головой?', 'Таймера нет', 'ALT: проверить полный ответ'}
    else return nil end
    lines[#lines + 1] = 'F: принять сразу | G: повторить'
    return lines
end

-- ОПТИМИЗАЦИЯ: Убрали pcall из отрисовки, так как это вызывает просадки FPS при вызове каждый кадр
local sfRenderDrawBox = renderDrawBox
local sfRenderFontDrawText = renderFontDrawText

local function drawInterviewHud()
    if not CONFIG.interviewHud then return end
    local lines = getInterviewHudLines()
    if not lines or #lines == 0 then return end
    if not ensureInterviewHudFont() then return end
    
    local sx, sy = getScreenResolution()
    if not sx or not sy then return end
    
    local width = 390
    local lineHeight = 19
    local height = 18 + (#lines * lineHeight)
    local x = sx - width - 22
    local y = sy - height - 70
    
    if sfRenderDrawBox then sfRenderDrawBox(x - 10, y - 8, width + 16, height + 8, 0xA0000000) end
    for i, line in ipairs(lines) do
        local color = (i == 1) and 0xFF84D7FF or 0xFFFFFFFF
        if sfRenderFontDrawText then sfRenderFontDrawText(interviewHudFont, cp(line), x, y + (i - 1) * lineHeight, color) end
    end
end

local TOP_NUMBER_KEYS = {0x31, 0x32, 0x33, 0x34, 0x35}
local KEY_F = vkeys.VK_F or 0x46
local KEY_G = vkeys.VK_G or 0x47
local KEY_ALT = vkeys.VK_MENU or 0x12

local function forceAcceptCurrentCandidate()
    if not session.active then chatInfo('Активной проверки нет.') return end
    if not isTargetAvailable() then chatInfo('Кандидат недоступен — быстрое принятие отменено.') return end
    chatInfo('F: оставшиеся этапы пропущены. Кандидат будет принят вручную.')
    finishSuccess()
end

local function repeatCurrentStagePrompt()
    if not session.active then return end
    local stage = session.stage

    if stage == 'wait_consent' then
        sendCandidateLines({
            'Здравия желаю, Вы на призыв?',
            '/b Ответьте да/нет.'
        })
        chatInfo('Повторен вопрос о призыве.')
    elseif stage == 'wait_offer' then
        sendCandidateLines({rpPhrase('docs_request')})
        sendShowPassInstruction(1)
        chatInfo('Повторена просьба передать документы.')
    elseif stage == 'q1' then
        sendCandidateLine('Расскажите о себе.')
        chatInfo('Повторен первый вопрос.')
    elseif stage == 'rp_custom' and session.rpCurrent then
        sendCandidateLine(session.rpCurrent.text)
        chatInfo('Повторен RP-вопрос.')
    elseif stage == 'q2' and session.q2Term then
        sendCandidateLine('Что такое «' .. session.q2Term.label .. '»?')
        chatInfo('Повторен вопрос термина.')
    elseif stage == 'q2_retry' and session.q2Term then
        sendCandidateLine('Подумайте ещё. Что означает «' .. session.q2Term.label .. '»?')
        chatInfo('Повторен вопрос термина (вторая попытка).')
    elseif stage == 'q3' then
        sendCandidateLine('Что у меня над головой?')
        chatInfo('Повторен финальный вопрос.')
    else
        chatInfo('На текущем этапе нет текста для повторения кандидату.')
    end
end

local function handleInterviewHotkeys()
    if not session.active or sampIsChatInputActive() or sampIsDialogActive() then return end

    if wasKeyPressed(KEY_F) then
        forceAcceptCurrentCandidate()
        return
    end

    if wasKeyPressed(KEY_G) then
        repeatCurrentStagePrompt()
        return
    end

    if session.stage == 'rp_menu' then
        for i = 1, 5 do
            if wasKeyPressed(TOP_NUMBER_KEYS[i]) then
                askRpMenuQuestion(i)
                return
            end
        end
    end

    if wasKeyPressed(KEY_ALT) then
        manualAdvanceInterview()
        return
    end
end

local function processDeadline()
    if not session.active or session.deadline <= 0 or os.time() < session.deadline then return end
    local stage = session.stage
    session.deadline = 0
    if stage == 'wait_consent' then chatInfo('Ожидаю ответ кандидата на вопрос о призыве. Тайм-аута нет.')
    elseif stage == 'wait_offer' then chatInfo('Ожидаю предложение документов. Тайм-аута нет.')
    elseif stage == 'wait_documents' then chatInfo('Ожидаю появление CEF/паспорта. Тайм-аута нет.')
    elseif stage == 'documents_passport' and not session.docs.gotLicenses then chatInfo('Ожидаю вкладку лицензий. Откройте её вручную, если автопереход не сработал.')
    elseif stage == 'documents_licenses' and not session.docs.gotMedical then chatInfo('Ожидаю медицинскую карту. Откройте её вручную, если автопереход не сработал.')
    elseif stage == 'q1' or stage == 'rp_custom' or stage == 'q2' or stage == 'q2_retry' or stage == 'q3' then chatInfo('На этапе собеседования таймеры отключены. Используйте ALT для перехода/проверки ответа.') end
end

local function printStatus()
    if not session.active then chatInfo('Активной проверки нет.') return end
    if session.deadline <= 0 then chatInfo(string.format('Кандидат: %s[%d], этап: %s, таймер: без ограничения.', tostring(session.targetName), tonumber(session.targetId) or -1, tostring(session.stage)))
    else
        local seconds = math.max(0, session.deadline - os.time())
        chatInfo(string.format('Кандидат: %s[%d], этап: %s, осталось: %d сек.', tostring(session.targetName), tonumber(session.targetId) or -1, tostring(session.stage), seconds))
    end
end

local function getSelfPlayerId()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if ok then return id end
    return nil
end

local function ensureSelfTestSession()
    if session.active and session.testMode then return true end
    local id = getSelfPlayerId()
    if not id then chatInfo('[TEST] Не удалось определить ваш ID.') return false end
    startRecruitment(id, {testMode = true, skipNickCheck = true})
    return true
end

local function ensureTestDocumentsStage(resetDocs)
    if not ensureSelfTestSession() then return false end
    if resetDocs then session.docs = newDocsState() end
    session.stage = 'wait_documents'
    session.deadline = 0
    return true
end

local function testPassport(years, law, name)
    if not ensureTestDocumentsStage(false) then return end
    handleDocumentData({type = 1, name = name or session.targetName, level = tostring(years or 5), zakono = tostring(law or 50)})
end

local function testLicenses(car, gun)
    if not ensureTestDocumentsStage(false) then return end
    if not session.docs.gotPassport then testPassport(5, 50) end
    handleDocumentData({type = 2, info = {{license = 'car', available = car and 1 or 0}, {license = 'gun', available = gun and 1 or 0}}})
end

local function testMedical(mode)
    if not ensureTestDocumentsStage(false) then return end
    if not session.docs.gotPassport then testPassport(5, 50) end
    if not session.docs.gotLicenses then testLicenses(true, true) end
    if mode == 'none' then handleDocumentData({type = 4})
    elseif mode == 'badhealth' then handleDocumentData({type = 4, state = 'Требуется лечение', zavisimost = '0'})
    elseif mode == 'weed' then handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '6'})
    elseif mode == 'uihealthy' then handleDocumentData({type = 4, statusText = 'Полностью здоровый(ая)', zavisimost = '0'})
    elseif mode == 'healthcode' then handleDocumentData({type = 4, state = 3, zavisimost = '0'})
    else handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '0'}) end
end

local function resetTestScenario(targetName)
    local id = getSelfPlayerId()
    if not id then chatInfo('[TEST] Не удалось определить ваш ID.') return false end
    startRecruitment(id, {testMode = true, skipNickCheck = true, targetName = targetName})
    session.docs = newDocsState()
    session.stage = 'wait_documents'
    session.deadline = 0
    return true
end

local function runDocumentTestScenario(kind)
    if not resetTestScenario(kind == 'badnick' and 'BadNick123' or nil) then return end
    local years = kind == 'lowyears' and 2 or (kind == 'allbad' and 1 or 5)
    local law = kind == 'lowlaw' and 20 or (kind == 'allbad' and 10 or 50)
    local car = not (kind == 'nocar' or kind == 'allbad')
    local gun = not (kind == 'nogun' or kind == 'allbad')
    if kind == 'badnick' then session.nickCheck = {nickname = session.targetName, localValid = false} end
    handleDocumentData({type = 1, name = session.targetName, level = tostring(years), zakono = tostring(law)})
    handleDocumentData({type = 2, info = {{license = 'car', available = car and 1 or 0}, {license = 'gun', available = gun and 1 or 0}}})
    if kind == 'nomed' or kind == 'allbad' then handleDocumentData({type = 4})
    elseif kind == 'badhealth' then handleDocumentData({type = 4, state = 'Требуется лечение', zavisimost = '0'})
    elseif kind == 'weed' then handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '6'})
    else handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '0'}) end
end

local function simulateTestOffer()
    if not ensureSelfTestSession() then return end
    session.stage = 'wait_documents'
    session.deadline = 0
    chatInfo('[TEST] Сымитировано предложение документов.')
    if CONFIG.autoAcceptOffer then sendGameCommand('/offer') end
end

local function forceDeadlineNow()
    if not session.active then return end
    session.deadline = os.time()
    processDeadline()
end

local function runTestCommand(arg)
    local action, rest = trim(arg or ''):match('^(%S*)%s*(.-)$')
    action = (action or ''):lower()
    rest = trim(rest or '')

    if action == '' or action == 'help' then
        chatInfo('[TEST] /rtest start | yes | yesvariants | offer | passport | licenses | medical | healthui | healthcode | docsok | phrases | spacing | cefnoise | longmsg')
        chatInfo('[TEST] Ошибки: nomed | badhealth | weed | nocar | nogun | lowyears | lowlaw | badnick | allbad')
        chatInfo('[TEST] Интервью: q1 | menu | pick 1..5 | advance | q2 | term MG/PG/SK/DM/DB | q3 | say ТЕКСТ | fullpass')
        chatInfo('[TEST] Онлайн ник: /rnick Name_Surname. Полный список есть в recruit_assistant_test_commands.txt.')
        return
    end

    if action == 'start' then clearSession('test restart') ensureSelfTestSession() return
    elseif action == 'yes' then if ensureSelfTestSession() then handleTargetSpeech(cp('Да')) end return
    elseif action == 'yesvariants' then
        local variants = {'Да', 'нДа', 'дда', 'даа', 'жа', 'дэ', 'йа', 'дас', 'yes', 'ес', 'йес', 'ага', 'угу', 'конечно', 'готов', 'готоф', 'давай', 'yep', 'yeah', 'ok', 'так точно', 'так точнл генерал', 'так точно товарищ генерал', 'есть', 'согласен', 'соглсен', 'готов служить', 'готов к призыву', 'разумеется'}
        chatInfo('[TEST] Проверяю варианты положительного ответа:')
        for _, value in ipairs(variants) do
            local encoded = cp(value)
            chatInfo(string.format('[TEST] %-10s -> %s', value, isPositiveConsent(encoded) and 'ДА' or 'НЕТ'))
        end
        return
    elseif action == 'say' then
        if rest == '' then chatInfo('[TEST] Использование: /rtest say текст ответа')
        elseif ensureSelfTestSession() then handleTargetSpeech(rest) end
        return
    elseif action == 'offer' then simulateTestOffer() return
    elseif action == 'passport' then testPassport(5, 50) return
    elseif action == 'licenses' then testLicenses(true, true) return
    elseif action == 'medical' then testMedical('good') return
    elseif action == 'healthui' then testMedical('uihealthy') return
    elseif action == 'healthcode' then testMedical('healthcode') return
    elseif action == 'longmsg' then
        if ensureSelfTestSession() then
            sendCandidateLine('В Вашей медицинской карте отсутствует пометка «Полностью здоров». Пройдите обследование в любой больнице штата.')
            chatInfo('[TEST] Длинная реплика поставлена в очередь. Она должна разбиться на короткие сообщения с паузой 3 секунды.')
        end
        return
    elseif action == 'docsok' then runDocumentTestScenario('docsok') return
    elseif action == 'nomed' or action == 'badhealth' or action == 'weed' or action == 'nocar' or action == 'nogun' or action == 'lowyears' or action == 'lowlaw' or action == 'badnick' or action == 'allbad' then
        runDocumentTestScenario(action) return
    elseif action == 'q1' then if ensureSelfTestSession() then beginQuestion('q1') end return
    elseif action == 'menu' then if ensureSelfTestSession() then openRpQuestionMenu() end return
    elseif action == 'pick' or action == 'rp' then
        if ensureSelfTestSession() then
            if session.stage ~= 'rp_menu' then openRpQuestionMenu() end
            local index = tonumber(rest)
            if index and index >= 1 and index <= 5 then askRpMenuQuestion(index) else chatInfo('[TEST] Использование: /rtest pick 1 .. 5') end
        end
        return
    elseif action == 'advance' then if ensureSelfTestSession() then manualAdvanceInterview() end return
    elseif action == 'q2' then if ensureSelfTestSession() then beginQuestion('q2') end return
    elseif action == 'term' then
        if not ensureSelfTestSession() then return end
        local term = findTermQuestion(rest)
        if not term then chatInfo('[TEST] Использование: /rtest term MG | PG | SK | DM | DB') else startSpecificTermQuestion(term) end
        return
    elseif action == 'q3' then if ensureSelfTestSession() then beginQuestion('q3') end return
    elseif action == 'termphrase' then
        if ensureSelfTestSession() then
            local term = findTermQuestion('MG')
            startSpecificTermQuestion(term)
            local answer = 'Две буквы какие-то, Мини Ган может?'
            chatInfo('[TEST] Проверяю разговорный ответ: ' .. answer)
            handleTargetSpeech(cp(answer))
            forceDeadlineNow()
        end
        return
    elseif action == 'termchat' then
        if ensureSelfTestSession() then
            local term = findTermQuestion('DM')
            startSpecificTermQuestion(term)
            chatInfo('[TEST] Проверяю две отдельные реплики для ДМ: «Понятно.» (окно 5 сек) + «Дядя миша?»')
            handleTargetSpeech(cp('Понятно.'))
            handleTargetSpeech(cp('Дядя миша?'))
            forceDeadlineNow()
        end
        return
    elseif action == 'skcommittee' then
        if ensureSelfTestSession() then
            local term = findTermQuestion('SK')
            startSpecificTermQuestion(term)
            local answer = 'Следственный комитет'
            chatInfo('[TEST] Проверяю СК: «' .. answer .. '» должно засчитаться.')
            handleTargetSpeech(cp(answer))
            forceDeadlineNow()
        end
        return
    elseif action == 'termok' or action == 'mgok' then
        if ensureSelfTestSession() then
            if session.stage ~= 'q2' and session.stage ~= 'q2_retry' then beginQuestion('q2') end
            local answer = session.q2Term and session.q2Term.testGood or 'Мирные граждане'
            chatInfo('[TEST] Даю скрыто правильный ответ для ' .. tostring(session.q2Term and session.q2Term.label or 'термина') .. ': ' .. answer)
            handleTargetSpeech(cp(answer))
            forceDeadlineNow()
        end
        return
    elseif action == 'termbad' or action == 'mgbad' then
        if ensureSelfTestSession() then
            beginQuestion('q2')
            local answer = session.q2Term and session.q2Term.testBad or 'Метагейминг'
            chatInfo('[TEST] Даю стандартную игровую расшифровку для ' .. tostring(session.q2Term and session.q2Term.label or 'термина') .. ': ' .. answer)
            handleTargetSpeech(cp(answer))
            forceDeadlineNow()
        end
        return
    elseif action == 'termbad2' or action == 'mgbad2' then
        if ensureSelfTestSession() then
            beginQuestion('q2_retry')
            local answer = session.q2Term and session.q2Term.testBad or 'Метагейминг'
            scheduleAction(CONFIG.retryQuestionDelayMs + 100, function()
                if session.active and session.stage == 'q2_retry' then
                    chatInfo('[TEST] Повторно даю стандартную игровую расшифровку: ' .. answer)
                    handleTargetSpeech(cp(answer))
                    forceDeadlineNow()
                end
            end)
        end
        return
    elseif action == 'headok' then
        if ensureSelfTestSession() then
            beginQuestion('q3')
            handleTargetSpeech(cp('Потолок'))
            forceDeadlineNow()
        end
        return
    elseif action == 'headbad' then
        if ensureSelfTestSession() then
            beginQuestion('q3')
            handleTargetSpeech(cp('Ник'))
            forceDeadlineNow()
        end
        return
    elseif action == 'spacing' then
        chatInfo('[TEST] Проверка общей очереди: ниже 4 тестовые отправки должны появляться с интервалом не менее 3 секунд.')
        enqueueOutbound('Проверка очереди: сообщение №1.', 'message', true)
        enqueueOutbound('/b Проверка очереди: сообщение №2.', 'message', true)
        enqueueOutbound('Проверка очереди: сообщение №3.', 'message', true)
        enqueueOutbound('/offer', 'command', true, ' — только тест, на сервер НЕ отправлено.')
        return
    elseif action == 'cefnoise' then
        if not resetTestScenario(nil) then return end
        chatInfo('[TEST] Имитирую посторонний CEF меню персонажа: type=1 без полей паспорта.')
        local before = session.docs.gotPassport
        handleDocumentData({type = 1, inventory = true, character = true}, {eventName = 'event.character.initializeData'})
        if session.docs.gotPassport == before and not session.docs.gotPassport then chatInfo('[TEST] OK: посторонний type=1 проигнорирован, «Паспорт считан» появиться не должен.') else chatInfo('[TEST] ОШИБКА: посторонний CEF был принят за паспорт.') end
        return
    elseif action == 'phrases' then
        chatInfo('[TEST] Случайные RP-формулировки:')
        local keys = {'success', 'professional_fail', 'low_years', 'low_law', 'no_car_license', 'no_gun_license', 'no_medical_card', 'bad_health', 'high_dependency', 'docs_ok'}
        for _, key in ipairs(keys) do chatInfo('[TEST -> кандидату] [' .. key .. '] ' .. rpPhrase(key)) end
        return
    elseif action == 'fullpass' then
        if not resetTestScenario(nil) then return end
        chatInfo('[TEST] Полный успешный сценарий.')
        session.stage = 'wait_consent'
        handleTargetSpeech(cp('Да'))
        simulateTestOffer()
        handleDocumentData({type = 1, name = session.targetName, level = '5', zakono = '50'})
        handleDocumentData({type = 2, info = {{license = 'car', available = 1}, {license = 'gun', available = 1}}})
        handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '0'})
        handleTargetSpeech(cp('Я проживаю в штате давно и готов проходить службу'))
        manualAdvanceInterview()
        manualAdvanceInterview()
        local termAnswer = session.q2Term and session.q2Term.testGood or 'Мирные граждане'
        handleTargetSpeech(cp(termAnswer))
        manualAdvanceInterview()
        handleTargetSpeech(cp('Потолок'))
        manualAdvanceInterview()
        return
    end

    chatInfo('[TEST] Неизвестная команда. Используйте /rtest help.')
end

local STROY_TIMER = {
    active = false,
    testMode = false,
    minutesLeft = 0,
    nextTickAt = 0,
}

local stroyHudFont = nil
local stroyHudFontFailed = false

local function ensureStroyHudFont()
    if stroyHudFont then return true end
    if stroyHudFontFailed then return false end
    if type(renderCreateFont) ~= 'function' then
        stroyHudFontFailed = true
        return false
    end
    local ok, font = pcall(renderCreateFont, 'Arial', 10, 5)
    if ok and font then
        stroyHudFont = font
        return true
    end
    stroyHudFontFailed = true
    debugLog('Stroy HUD font create failed: ' .. tostring(font))
    return false
end

local function stroyChatInfo(text)
    sampAddChatMessage(cp('{84D7FF}[Строй]{FFFFFF} ' .. tostring(text or '')), -1)
end

local function stroyTestInfo(text)
    sampAddChatMessage(cp('{F5B642}[STR TEST]{FFFFFF} ' .. tostring(text or '')), -1)
end

local function stroyMinuteWord(value)
    local n = math.abs(math.floor(tonumber(value) or 0))
    local last100 = n % 100
    local last10 = n % 10
    if last100 >= 11 and last100 <= 14 then return 'минут'
    elseif last10 == 1 then return 'минута'
    elseif last10 >= 2 and last10 <= 4 then return 'минуты' end
    return 'минут'
end

local function stroyCountdownText(minutes)
    return 'Строй для всех бойцов, всем на плац! Время на построение ' .. tostring(minutes) .. ' ' .. stroyMinuteWord(minutes) .. '.'
end

local function resetStroyTimer()
    STROY_TIMER.active = false
    STROY_TIMER.testMode = false
    STROY_TIMER.minutesLeft = 0
    STROY_TIMER.nextTickAt = 0
end

local function sendStroyTimerMessage()
    if STROY_TIMER.minutesLeft <= 0 then
        if STROY_TIMER.testMode then stroyTestInfo('/r Время на построение окончено.') else sampSendChat(cp('/r Время на построение окончено.')) end
        resetStroyTimer()
        return
    end
    local text = stroyCountdownText(STROY_TIMER.minutesLeft)
    if STROY_TIMER.testMode then stroyTestInfo('/r ' .. text) else sampSendChat(cp('/r ' .. text)) end
end

local function parseStroyMinutes(arg)
    local value = tonumber(tostring(arg or ''):match('^%s*(%d+)%s*$'))
    if not value then return nil end
    value = math.floor(value)
    if value < 1 or value > 180 then return nil end
    return value
end

local function startStroyTimer(arg, testMode)
    local minutes = parseStroyMinutes(arg)
    if not minutes then
        if testMode then stroyChatInfo('Использование: /strtest [минуты]. Допустимо: 1-180.') else stroyChatInfo('Использование: /str [минуты]. Допустимо: 1-180.') end
        return
    end
    resetStroyTimer()
    STROY_TIMER.active = true
    STROY_TIMER.testMode = testMode == true
    STROY_TIMER.minutesLeft = minutes
    STROY_TIMER.nextTickAt = nowMs() + 60000
    sendStroyTimerMessage()
    if STROY_TIMER.testMode then stroyChatInfo('Тест запущен. /strskip — пропустить минуту, /nostr — отменить.')
    else stroyChatInfo('Таймер построения запущен на ' .. tostring(minutes) .. ' ' .. stroyMinuteWord(minutes) .. '.') end
end

local function cancelStroyTimer()
    if not STROY_TIMER.active then stroyChatInfo('Активного построения нет.') return end
    local wasTest = STROY_TIMER.testMode
    resetStroyTimer()
    if wasTest then stroyChatInfo('Тест построения отменён.') else stroyChatInfo('Построение отменено.') end
end

local function skipStroyTestMinute()
    if not STROY_TIMER.active then stroyChatInfo('Активного построения нет.') return end
    if not STROY_TIMER.testMode then stroyChatInfo('/strskip доступна только во время /strtest.') return end
    STROY_TIMER.minutesLeft = STROY_TIMER.minutesLeft - 1
    STROY_TIMER.nextTickAt = nowMs() + 60000
    sendStroyTimerMessage()
end

local function showStroyStatus()
    if not STROY_TIMER.active then stroyChatInfo('Статус: построение не запущено.') return end
    local leftMs = math.max(0, STROY_TIMER.nextTickAt - nowMs())
    local seconds = math.ceil(leftMs / 1000)
    stroyChatInfo('Статус: ' .. (STROY_TIMER.testMode and 'ТЕСТ' or 'РЕАЛЬНЫЙ СТРОЙ') .. ', осталось по счётчику: ' .. tostring(STROY_TIMER.minutesLeft) .. ' ' .. stroyMinuteWord(STROY_TIMER.minutesLeft) .. ', следующее сообщение через ~' .. tostring(seconds) .. ' сек.')
end

local function processStroyTimer()
    if not STROY_TIMER.active or STROY_TIMER.nextTickAt <= 0 then return end
    local now = nowMs()
    if now >= STROY_TIMER.nextTickAt then
        STROY_TIMER.minutesLeft = STROY_TIMER.minutesLeft - 1
        STROY_TIMER.nextTickAt = STROY_TIMER.nextTickAt + 60000
        sendStroyTimerMessage()
    end
end

-- ОПТИМИЗАЦИЯ: Убрали pcall из отрисовки 
local function drawStroyHud()
    if not STROY_TIMER.active then return end
    if not ensureStroyHudFont() then return end
    
    local sx, sy = getScreenResolution()
    if not sx or not sy then return end
    
    local leftMs = math.max(0, STROY_TIMER.nextTickAt - nowMs())
    local seconds = math.ceil(leftMs / 1000)
    local mode = STROY_TIMER.testMode and 'ТЕСТ' or 'РЕАЛЬНЫЙ СТРОЙ'
    local lines = {
        'СТРОЙ • ' .. mode,
        'Осталось: ' .. tostring(STROY_TIMER.minutesLeft) .. ' ' .. stroyMinuteWord(STROY_TIMER.minutesLeft) .. ' | Следующее: ~' .. tostring(seconds) .. ' сек.',
    }
    local width = 380
    local lineHeight = 18
    local height = 38
    local x = sx - width - 22
    local y = sy - height - 16
    
    if sfRenderDrawBox then sfRenderDrawBox(x - 10, y - 7, width + 16, height + 10, 0xA0000000) end
    for i, line in ipairs(lines) do
        local color = (i == 1) and 0xFFF5B642 or 0xFFFFFFFF
        if sfRenderFontDrawText then sfRenderFontDrawText(stroyHudFont, cp(line), x, y + (i - 1) * lineHeight, color) end
    end
end

local showAnime = false
local animeTexture = nil
local sfRenderDrawTexture = renderDrawTexture

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    math.random(); math.random(); math.random()

    sampRegisterChatCommand('autovois', function()
        AUTO_VOIS.enabled = not AUTO_VOIS.enabled
        if not AUTO_VOIS.enabled then
            autoVoisCancel()
            autoVoisChat('Автоматизация выключена.', 0xFFB45C)
        else autoVoisChat('Автоматизация включена.') end
    end)

    sampRegisterChatCommand('avstate', function()
        autoVoisChat('enabled=' .. tostring(AUTO_VOIS.enabled) .. ', active=' .. tostring(autoVoisState.active) .. ', resolving=' .. tostring(autoVoisState.resolving) .. ', step=' .. tostring(autoVoisState.step) .. ', ID=' .. tostring(autoVoisState.playerId))
    end)

    sampRegisterChatCommand('anime', function()
        if not animeTexture then
            local path = getWorkingDirectory() .. '\\anime.png'
            if doesFileExist(path) then
                local ok, tex = pcall(renderLoadTextureFromFile, path)
                if ok and tex then
                    animeTexture = tex
                else
                    chatInfo('Не удалось загрузить картинку. Убедитесь, что формат anime.png корректный!')
                    return
                end
            else
                chatInfo('Файл anime.png не найден! Поместите картинку в папку moonloader.')
                return
            end
        end
        showAnime = not showAnime
        chatInfo('Аниме тяночка ' .. (showAnime and 'появилась на экране!' or 'скрыта.'))
    end)

    local function showDiagnostics()
        local memoryKb = -1
        local okMemory, memoryValue = pcall(function() return collectgarbage('count') end)
        if okMemory and type(memoryValue) == 'number' then memoryKb = math.floor(memoryValue) end
        local recruitStage = 'unknown'
        if type(session) == 'table' then recruitStage = tostring(session.stage or 'idle') end
        local voisStep = 'unknown'
        local voisActive = false
        if type(autoVoisState) == 'table' then
            voisStep = tostring(autoVoisState.step or 0)
            voisActive = autoVoisState.active == true
        end
        local outboundCount = type(outboundQueue) == 'table' and #outboundQueue or -1
        local scheduledCount = type(scheduledActions) == 'table' and #scheduledActions or -1
        local message = 'v6.7 | Lua: ' .. (memoryKb >= 0 and (tostring(memoryKb) .. ' KB') or 'N/A') .. ' | Queue: ' .. tostring(outboundCount) .. ' | Tasks: ' .. tostring(scheduledCount) .. ' | Recruit: ' .. recruitStage .. ' | VOiS: ' .. (voisActive and 'ON/' or 'OFF/') .. voisStep
        local okChat, chatErr = pcall(function() chatInfo(message) end)
        consolePrint('[Recruit DIAG] ' .. message)
        debugLog('DIAG: ' .. message)
        if not okChat then consolePrint('[Recruit DIAG] chat output failed: ' .. tostring(chatErr)) end
    end

local UPDATE_STATE = { busy = false, manifestPath = nil, scriptTempPath = nil, }

local function updateConfigured()
    return type(CONFIG.updateManifestUrl) == 'string' and CONFIG.updateManifestUrl ~= '' and type(CONFIG.updateScriptUrl) == 'string' and CONFIG.updateScriptUrl ~= ''
end

local function compareVersionParts(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or ''):gmatch('%d+') do t[#t + 1] = tonumber(n) or 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    local maxLen = math.max(#pa, #pb)
    for i = 1, maxLen do
        local av, bv = pa[i] or 0, pb[i] or 0
        if av < bv then return -1 end
        if av > bv then return 1 end
    end
    return 0
end

local function currentScriptVersion() return '6.7' end

local function updaterDownload(url, path, callback)
    local callbackDone = false
    local function downloadedFileExists()
        local f = io.open(path, 'rb')
        if not f then return false end
        local size = f:seek('end') or 0
        f:close()
        return tonumber(size) ~= nil and tonumber(size) > 0
    end
    local function finish(ok, err)
        if callbackDone then return end
        callbackDone = true
        callback(ok, err)
    end
    local function systemFallback(reason)
        if callbackDone then return end
        pcall(os.remove, path)
        local safeUrl = tostring(url or ''):gsub('"', '')
        local safePath = tostring(path or ''):gsub('"', '')
        local curlCommand = 'curl.exe -L --fail --silent --show-error --connect-timeout 15 --max-time 60 -o "' .. safePath .. '" "' .. safeUrl .. '" >nul 2>nul'
        pcall(os.execute, curlCommand)
        if downloadedFileExists() then finish(true) return end
        pcall(os.remove, path)
        local psUrl = tostring(url or ''):gsub("'", "''")
        local psPath = tostring(path or ''):gsub("'", "''")
        local psCommand = 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ProgressPreference=\'SilentlyContinue\'; try { Invoke-WebRequest -UseBasicParsing -Uri \'' .. psUrl .. '\' -OutFile \'' .. psPath .. '\'; exit 0 } catch { exit 1 }" >nul 2>nul'
        pcall(os.execute, psCommand)
        if downloadedFileExists() then finish(true) return end
        finish(false, tostring(reason or 'загрузка не удалась') .. '; fallback curl/PowerShell тоже не создал файл')
    end

    pcall(os.remove, path)
    if type(downloadUrlToFile) ~= 'function' then systemFallback('downloadUrlToFile недоступен') return end

    local moonloaderFinished = false
    local function waitForDownloadedFile(attempt)
        if callbackDone then return end
        attempt = tonumber(attempt) or 1
        if downloadedFileExists() then finish(true) return end
        if attempt >= 20 then systemFallback('MoonLoader сообщил завершение, но файл после загрузки не найден: ' .. tostring(path)) return end
        scheduleAction(250, function() waitForDownloadedFile(attempt + 1) end)
    end

    local ok, err = pcall(function()
        downloadUrlToFile(url, path, function(id, status, p1, p2)
            if callbackDone or moonloaderFinished then return end
            if dlstatus then
                if status == dlstatus.STATUSEX_ENDDOWNLOAD then
                    moonloaderFinished = true
                    scheduleAction(250, function() waitForDownloadedFile(1) end)
                elseif status == dlstatus.STATUS_ERROR or status == dlstatus.STATUSEX_ERROR or status == dlstatus.STATUS_ABORT then
                    moonloaderFinished = true
                    scheduleAction(0, function() systemFallback('ошибка downloadUrlToFile, status=' .. tostring(status)) end)
                end
            else
                if status == 6 then
                    moonloaderFinished = true
                    scheduleAction(250, function() waitForDownloadedFile(1) end)
                end
            end
        end)
    end)
    if not ok then
        moonloaderFinished = true
        systemFallback('не удалось запустить downloadUrlToFile: ' .. tostring(err))
    end
end

local function fileSizeBytes(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local size = f:seek('end')
    f:close()
    return tonumber(size)
end

local function isValidMp3File(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    local head = f:read(3) or ''
    local size = f:seek('end') or 0
    f:close()
    if tonumber(size) == nil or tonumber(size) < 64 then return false end
    if head:sub(1, 3) == 'ID3' then return true end
    local b1, b2 = head:byte(1, 2)
    if b1 == 0xFF and b2 and b2 >= 0xE0 then return true end
    return false
end

local function ensureDirectory(path)
    path = tostring(path or '')
    if path == '' then return false end
    if type(doesDirectoryExist) == 'function' then
        local okExists, exists = pcall(doesDirectoryExist, path)
        if okExists and exists then return true end
    end
    if type(createDirectory) == 'function' then
        pcall(createDirectory, path)
        if type(doesDirectoryExist) == 'function' then
            local okExists, exists = pcall(doesDirectoryExist, path)
            if okExists and exists then return true end
        end
    end
    local safePath = path:gsub('"', '')
    pcall(os.execute, 'mkdir "' .. safePath .. '" >nul 2>nul')
    if type(doesDirectoryExist) == 'function' then
        local okExists, exists = pcall(doesDirectoryExist, path)
        return okExists and exists == true
    end
    return true
end

local function installDownloadedAsset(tempPath, destinationPath)
    local input = io.open(tempPath, 'rb')
    if not input then return false, 'не удалось открыть скачанный ресурс' end
    local data = input:read('*a')
    input:close()
    if type(data) ~= 'string' or #data < 64 then return false, 'скачанный ресурс слишком маленький или пустой' end
    local h1, h2 = data:byte(1, 2)
    local hasId3 = data:sub(1, 3) == 'ID3'
    local hasMpegSync = h1 == 0xFF and h2 ~= nil and h2 >= 0xE0
    if not hasId3 and not hasMpegSync then return false, 'скачанный файл не похож на MP3' end
    local folder = destinationPath:match('^(.*[\\/])')
    if folder and folder ~= '' then
        folder = folder:gsub('[\\/]$', '')
        if not ensureDirectory(folder) then return false, 'не удалось создать папку: ' .. tostring(folder) end
    end
    local backupPath = destinationPath .. '.bak'
    pcall(os.remove, backupPath)
    if doesFileExist(destinationPath) then pcall(os.rename, destinationPath, backupPath) end
    local output = io.open(destinationPath, 'wb')
    if not output then
        if doesFileExist(backupPath) then pcall(os.rename, backupPath, destinationPath) end
        return false, 'не удалось записать ресурс: ' .. tostring(destinationPath)
    end
    output:write(data)
    output:close()
    pcall(os.remove, backupPath)
    return true
end

local function syncUpdateAssets(base, forceDownload, callback)
    local assets = CONFIG.updateAssets
    if type(assets) ~= 'table' or #assets == 0 then callback(true, nil, false) return end
    local index = 1
    local changed = false
    local errors = {}

    local function addError(message)
        errors[#errors + 1] = tostring(message or 'неизвестная ошибка ресурса')
        debugLog('Updater asset error: ' .. tostring(message))
    end

    local function nextAsset()
        if index > #assets then
            if #errors > 0 then callback(false, table.concat(errors, ' | '), changed) else callback(true, nil, changed) end
            return
        end
        local asset = assets[index]
        index = index + 1
        if type(asset) ~= 'table' or type(asset.url) ~= 'string' or asset.url == '' or type(asset.relativePath) ~= 'string' or asset.relativePath == '' then
            addError('некорректная запись ресурса автообновления #' .. tostring(index - 1))
            nextAsset()
            return
        end
        local destinationPath = base .. asset.relativePath
        if not forceDownload and isValidMp3File(destinationPath) then nextAsset() return end
        local folder = destinationPath:match('^(.*[\\/])')
        if folder and folder ~= '' then
            folder = folder:gsub('[\\/]$', '')
            if not ensureDirectory(folder) then addError('не удалось создать папку для ' .. tostring(asset.name or asset.relativePath)) nextAsset() return end
        end
        local safeTempName = tostring(asset.name or ('asset_' .. tostring(index))):gsub('[^%w%._%-]', '_')
        local tempPath = base .. 'recruit_update_' .. safeTempName .. '.tmp'
        pcall(os.remove, tempPath)
        chatInfo('Ресурс: скачиваю ' .. tostring(asset.name or asset.relativePath) .. '...')
        updaterDownload(asset.url, tempPath, function(okDownload, downloadErr)
            if not okDownload then
                pcall(os.remove, tempPath)
                addError('не удалось скачать ' .. tostring(asset.name or asset.relativePath) .. ': ' .. tostring(downloadErr))
                nextAsset()
                return
            end
            local installed, installErr = installDownloadedAsset(tempPath, destinationPath)
            pcall(os.remove, tempPath)
            if not installed then
                addError('не удалось установить ' .. tostring(asset.name or asset.relativePath) .. ': ' .. tostring(installErr))
                nextAsset()
                return
            end
            changed = true
            chatInfo('Ресурс установлен: ' .. tostring(asset.name or asset.relativePath) .. '.')
            debugLog('Updater asset installed: ' .. tostring(asset.relativePath))
            nextAsset()
        end)
    end
    nextAsset()
end

local function installDownloadedScript(tempPath)
    local thisPath = thisScript().path
    if not thisPath or thisPath == '' then return false, 'не удалось определить путь текущего скрипта' end
    local input = io.open(tempPath, 'rb')
    if not input then return false, 'не удалось открыть скачанный файл' end
    local data = input:read('*a')
    input:close()
    if type(data) ~= 'string' or #data < 1000 then return false, 'скачанный файл слишком маленький или пустой' end
    if not data:find("script_name", 1, true) or not data:find("Recruit Helper", 1, true) then return false, 'скачанный файл не похож на Recruit Helper' end
    local backupPath = thisPath .. '.bak'
    pcall(os.remove, backupPath)
    pcall(os.rename, thisPath, backupPath)
    local output = io.open(thisPath, 'wb')
    if not output then
        pcall(os.rename, backupPath, thisPath)
        return false, 'не удалось открыть текущий .lua для записи'
    end
    output:write(data)
    output:close()
    return true
end

local function checkForUpdate(manual)
    if UPDATE_STATE.busy then
        if manual then chatInfo('Проверка обновления уже выполняется.') end
        return
    end
    if not updateConfigured() then
        chatInfo('Сервер обновлений не настроен. Нужны updateManifestUrl и updateScriptUrl.')
        chatInfo('Локальный файл нельзя раздать другим игрокам без общего HTTP/HTTPS-хостинга.')
        return
    end
    UPDATE_STATE.busy = true
    local thisPath = thisScript() and thisScript().path or ''
    local base = thisPath:match('^(.*[\\/])')
    if not base or base == '' then
        base = tostring(getWorkingDirectory() or '')
        if base:sub(-1) ~= '\\' and base:sub(-1) ~= '/' then base = base .. '\\' end
    end
    local manifestPath = base .. 'recruit_helper_update_version.tmp'
    local scriptTempPath = base .. 'recruit_helper_update_script.tmp'
    UPDATE_STATE.manifestPath = manifestPath
    UPDATE_STATE.scriptTempPath = scriptTempPath
    if manual then chatInfo('Проверяю обновление Recruit Helper...') end
    updaterDownload(CONFIG.updateManifestUrl, manifestPath, function(ok, err)
        if not ok then
            UPDATE_STATE.busy = false
            chatInfo('Не удалось проверить обновление: ' .. tostring(err))
            return
        end
        local f = io.open(manifestPath, 'rb')
        if not f then
            UPDATE_STATE.busy = false
            chatInfo('Не удалось прочитать файл версии.')
            return
        end
        local remoteVersion = trim(f:read('*a') or '')
        f:close()
        pcall(os.remove, manifestPath)
        if remoteVersion == '' then
            UPDATE_STATE.busy = false
            chatInfo('Сервер обновлений вернул пустую версию.')
            return
        end
        local localVersion = currentScriptVersion()
        if compareVersionParts(localVersion, remoteVersion) >= 0 then
            chatInfo('Установлена актуальная версия v' .. localVersion .. '.')
            syncUpdateAssets(base, false, function(okAssets, assetErr, changedAssets)
                UPDATE_STATE.busy = false
                if not okAssets then
                    chatInfo('Версия актуальна, но ресурсы не восстановлены: ' .. tostring(assetErr))
                    return
                end
                if changedAssets then chatInfo('Отсутствующие файлы hit-warnings восстановлены.') end
            end)
            return
        end
        chatInfo('Найдена новая версия v' .. remoteVersion .. '. Скачиваю скрипт...')
        updaterDownload(CONFIG.updateScriptUrl, scriptTempPath, function(okScript, errScript)
            if not okScript then
                UPDATE_STATE.busy = false
                chatInfo('Не удалось скачать обновление: ' .. tostring(errScript))
                return
            end
            local installed, installErr = installDownloadedScript(scriptTempPath)
            pcall(os.remove, scriptTempPath)
            UPDATE_STATE.busy = false
            if not installed then
                chatInfo('Ошибка установки обновления: ' .. tostring(installErr))
                return
            end
            chatInfo('Скрипт обновлён. Перезапустите MoonLoader для применения.')
            debugLog('Updater installed remote version ' .. tostring(remoteVersion) .. '; reload disabled to prevent update loop')
        end)
    end)
end

    sampRegisterChatCommand('rdiag', showDiagnostics)
    sampRegisterChatCommand('diag', showDiagnostics)
    sampRegisterChatCommand('update', function() checkForUpdate(true) end)
    sampRegisterChatCommand('autobinder', toggleAutoBinder)
    sampRegisterChatCommand('bindon', function() setAutoBinderEnabled(true) end)
    sampRegisterChatCommand('bindoff', function() setAutoBinderEnabled(false) end)
    sampRegisterChatCommand('dcon', function() setDiscordBinderEnabled(true) end)
    sampRegisterChatCommand('dcoff', function() setDiscordBinderEnabled(false) end)
    sampRegisterChatCommand('bindstatus', printAutoBinderStatus)
    sampRegisterChatCommand('discordls', function()
        if sendDiscordBinderNow(false) then AUTO_BINDER.discordNextAt = autoBinderNowMs() + discordBinderInterval() end
    end)

local function showRecruitHelp()
    chatInfo('========== Recruit Helper 6.7 ==========')
    chatInfo('Основные команды:')
    chatInfo('/near')
    chatInfo('/rrp')
    chatInfo('/anime')
    chatInfo('')
    chatInfo('Строй:')
    chatInfo('/str [минуты]')
    chatInfo('/nostr')
    chatInfo('/strtest [минуты]')
    chatInfo('/strskip')
    chatInfo('/strstatus')
    chatInfo('/update')
    chatInfo('')
    chatInfo('Призыв:')
    chatInfo('/recruit')
    chatInfo('/raccept')
    chatInfo('/rnext')
    chatInfo('/rskip')
    chatInfo('/rstop')
    chatInfo('/rstatus')
    chatInfo('/rnick')
    chatInfo('/rmanual — ручная проверка проф.пригодности')
    chatInfo('/rexceptions [head|yes|no|all]')
    chatInfo('/rvariants [head|yes|no|all]')
    chatInfo('/roff')
    chatInfo('')
    chatInfo('Auto VOiS:')
    chatInfo('/autovois')
    chatInfo('/avstate')
    chatInfo('')
    chatInfo('Автобиндер:')
    chatInfo('/bindon')
    chatInfo('/bindoff')
    chatInfo('/bindstatus')
    chatInfo('/autobinder')
    chatInfo('')
    chatInfo('Объявления:')
    chatInfo('/discordls')
    chatInfo('/dcon')
    chatInfo('/dcoff')
    chatInfo('')
    chatInfo('Диагностика:')
    chatInfo('/diag')
    chatInfo('/rdiag')
    chatInfo('/rlog')
    chatInfo('/rtest')
    chatInfo('')
    chatInfo('Помощь:')
    chatInfo('/rhelp')
    chatInfo('==========================================')
end

    sampRegisterChatCommand('near', startNearest)
    sampRegisterChatCommand('rrp', giveFractionRpInRadius)
    sampRegisterChatCommand('str', function(arg) startStroyTimer(arg, false) end)
    sampRegisterChatCommand('nostr', cancelStroyTimer)
    sampRegisterChatCommand('strtest', function(arg) startStroyTimer(arg, true) end)
    sampRegisterChatCommand('strskip', skipStroyTestMinute)
    sampRegisterChatCommand('strstatus', showStroyStatus)
    sampRegisterChatCommand('rhelp', showRecruitHelp)
    sampRegisterChatCommand('recruit', function(arg)
        local id = tonumber(trim(arg))
        if id then startRecruitment(id) else chatInfo('Использование: /recruit ID') end
    end)
    sampRegisterChatCommand('rstop', function() clearSession('manual stop') chatInfo('Проверка остановлена.') end)
    sampRegisterChatCommand('rstatus', printStatus)
    sampRegisterChatCommand('raccept', forceAcceptCurrentCandidate)
    sampRegisterChatCommand('klakson', function()
        klaksonDisabled = not klaksonDisabled
        if klaksonDisabled and protectedHitAudio then
            if type(setAudioStreamState) == 'function' then pcall(setAudioStreamState, protectedHitAudio, 0) end
            if type(releaseAudioStream) == 'function' then pcall(releaseAudioStream, protectedHitAudio) end
            protectedHitAudio = nil
        end
        chatInfo('Звук удара для Jensen_Ackles: ' .. (klaksonDisabled and 'ВЫКЛЮЧЕН' or 'включён'))
    end)
    sampRegisterChatCommand('rmanual', function()
        CONFIG.manualProfessionalCheck = not CONFIG.manualProfessionalCheck
        if CONFIG.manualProfessionalCheck then
            chatInfo('Ручной режим проверки проф.пригодности ВКЛЮЧЁН: скрипт не оценивает ответ; ALT подтверждает ответ и продолжает проверку.')
        else
            chatInfo('Ручной режим проверки проф.пригодности выключен: ответ снова проверяет скрипт.')
        end
    end)

    local function skipActiveTimer()
        if not session.active then chatInfo('Активной проверки нет.') return end
        if session.stage == 'q1' or session.stage == 'rp_menu' or session.stage == 'rp_custom' or session.stage == 'q2' or session.stage == 'q2_retry' or session.stage == 'q2_retry_hint' or session.stage == 'q3' then
            manualAdvanceInterview()
            return
        end
        if session.deadline <= 0 then chatInfo('Сейчас активного таймера нет. Ожидаю действие кандидата или открытие документов.') return end
        local seconds = math.max(0, session.deadline - os.time())
        session.deadline = os.time()
        chatInfo(string.format('Таймер пропущен%s.', seconds > 0 and (' (оставалось ' .. tostring(seconds) .. ' сек.)') or ''))
    end

    sampRegisterChatCommand('rskip', skipActiveTimer)
    sampRegisterChatCommand('rnext', skipActiveTimer)
    sampRegisterChatCommand('roff', function()
        CONFIG.autoInvite = not CONFIG.autoInvite
        chatInfo('Автоматический /inv: ' .. (CONFIG.autoInvite and 'включён' or 'выключен') .. '.')
    end)
    sampRegisterChatCommand('rlog', function() chatInfo('Лог диагностики: ' .. getDebugLogPath()) end)
    sampRegisterChatCommand('rtest', runTestCommand)
    sampRegisterChatCommand('rexceptions', showRecruitExceptions)
    sampRegisterChatCommand('rexcl', showRecruitExceptions)
    sampRegisterChatCommand('rvariants', showRecruitExceptions)
    sampRegisterChatCommand('rnick', function(arg)
        local nick = trim(arg or '')
        if nick == '' then chatInfo('Использование: /rnick Name_Surname') return end
        startRpNicknameCheck(nick, false)
    end)

    debugLog('Recruit Helper 6.7 loaded. Safe CEF mode enabled; FFI packet scan removed.')
    initAutoBinderSchedule(true)
    chatInfo('Recruit Helper 6.7 загружен.')
    chatInfo('Используйте /rhelp для списка команд.')
    printAutoBinderStatus()
    autoVoisChat('Встроенный Auto VOiS v2 активен. Команды: /autovois, /avstate')
    
    if CONFIG.updateCheckOnStart then
        scheduleAction(3000, function()
            checkForUpdate(false)
        end)
    end

    local lastLogicTick = 0

    while true do
        wait(0)
        local currentTick = nowMs()
        
        -- Отрисовка интерфейса и проверка кнопок (вызываются каждый кадр для плавности)
        drawInterviewHud()
        drawStroyHud()
        handleInterviewHotkeys()

        if showAnime and animeTexture then
            local sx, sy = getScreenResolution()
            if sx and sy and sfRenderDrawTexture then
                sfRenderDrawTexture(animeTexture, sx - 450, sy - 550, 400, 500, 0, 0xFFFFFFFF)
            end
        end

        if CONFIG.hotkeyAltN and not sampIsChatInputActive() and not sampIsDialogActive() and isKeyDown(vkeys.VK_MENU) and wasKeyPressed(0x31) then
            startNearest()
        end

        -- ОПТИМИЗАЦИЯ: Внутренние процессы выполняются раз в 50 мс, чтобы не нагружать процессор (увеличивает FPS)
        if currentTick - lastLogicTick >= 50 then
            processScheduledActions()
            processOutboundQueue()
            processAutoVois()
            processAutoBinder()
            processMaintenance()
            processStroyTimer()

            if session.active and not session.testMode and session.targetId and not sampIsPlayerConnected(session.targetId) then
                chatInfo('Кандидат вышел из игры. Проверка остановлена.')
                clearSession('target disconnected')
            else
                processDeadline()
            end
            
            lastLogicTick = currentTick
        end
    end
end
