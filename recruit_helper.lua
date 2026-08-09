script_name('Recruit Helper')
script_author('OpenAI')
script_version('2.0.8')
script_description('Recruit Helper 2.0.8: призыв + Auto VOiS, безопасный CEF, ручное RP-собеседование и /inv.')

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
    nearDistance = 6.0,           -- максимальная дистанция поиска игрока
    frontDot = 0.25,              -- ширина сектора перед персонажем; меньше = шире
    autoAcceptOffer = true,       -- автоматически вводить /offer
    autoSwitchDocumentPages = true,
    autoInvite = true,            -- автоматически вводить /inv ID после успешной проверки
    outboundDelayMs = 3000,      -- единая пауза между ЛЮБЫМИ сообщениями/чат-командами, отправляемыми на сервер
    chatDelayMs = 3000,          -- совместимость со старой логикой; фактический минимум задаёт outboundDelayMs
    retryQuestionDelayMs = 5000, -- пауза между RP-примером (брендом) и повторным вопросом Q2
    hotkeyAltN = true,            -- Alt + 1 запускает то же, что /near
    debug = true,
    fileLog = true,              -- писать обычную диагностику и health-check в файл
    packetLog = false,            -- v2.0.4: сырое логирование пакетов выключено по умолчанию
    packetLogLimit = 40,          -- лимит диагностических записей CEF на одну проверку
    maxCefPayloadBytes = 65536,   -- защита от повреждённых/аномально больших CEF-пакетов
    maxOutboundQueue = 120,       -- защита от бесконечного роста очереди исходящих сообщений
    maxScheduledActions = 120,    -- защита от бесконечного роста очереди отложенных действий
    gcIntervalMs = 60000,         -- мягкий шаг сборщика мусора раз в минуту
    healthLogIntervalMs = 600000, -- раз в 10 минут писать краткое состояние в debug-log
    maxCandidateMessageBytes = 92, -- длинные RP-сообщения автоматически дробятся на короткие строки
    checkRpNicknameOnline = true, -- проверять имя/фамилию через Namespedia
    strictRpNicknameOnline = false, -- онлайн-проверка только подсказка; true = считать её причиной отказа
    blockBadNicknameFormat = true,  -- некорректный формат Name_Surname является причиной отказа
    nicknameCheckTimeoutMs = 6000,
    interviewHud = true,          -- мини-панель справа снизу
    interviewHudFontSize = 10,
    manualInterview = true,       -- с «Расскажите о себе» никаких авто-таймеров

    -- Обновление Recruit Helper.
    -- Нужен внешний HTTP/HTTPS адрес. Пока URL пустые, /update честно сообщит,
    -- что сервер обновлений не настроен.
    updateManifestUrl = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/version.txt',        -- пример: https://site.example/recruit-helper/version.txt
    updateScriptUrl = 'https://raw.githubusercontent.com/wsspmaster-eng/recuit-helper/refs/heads/main/recruit_helper.lua',          -- пример: https://site.example/recruit-helper/recruit_helper.lua
    updateCheckOnStart = true,    -- автоматическая проверка при входе

    -- Автобиндер.
    autoBinderEnabled = true,          -- общий мастер-переключатель автобиндера
    battlePassBinderEnabled = true,    -- Battle Pass включён
    discordBinderEnabled = true,       -- Discord включён
    autoBinderIntervalMs = 3600000,    -- Battle Pass: каждые 60 минут
    discordBinderIntervalMs = 3600000, -- Discord: каждые 60 минут
    autoBinderRetryMs = 60000,         -- если идёт призыв/VOiS/очередь занята — повтор через минуту
    battlePassFirstDelayMs = 3600000,  -- первый Battle Pass через 60 минут после запуска
    discordFirstDelayMs = 3600000,     -- первый Discord через 60 минут
}

local PREFIX = '{84D7FF}[Recruit]{FFFFFF} '


-- v2.0.7: защита создателя и его друга от случайных ударов
local CREATOR_WARN_COOLDOWN = 0

local function playAnnoyingWarningSound()
    -- тихий короткий неприятный звук через встроенный звук SA-MP
    pcall(function()
        sampPlaySound(1085, 0, 0)
    end)
end

local function checkProtectedHit(playerId)
    local now = os.clock() * 1000
    if now - CREATOR_WARN_COOLDOWN < 1500 then
        return
    end

    local nick = sampGetPlayerNickname(playerId)
    if not nick then return end

    if nick == 'Suleyman_Kanuni' then
        CREATOR_WARN_COOLDOWN = now
        sampAddChatMessage(
            'НЕ БЕЙТЕ СОЗДАТЕЛЯ СКРИПТА :goblin::goblin::goblin::goblin:!!!!!!',
            0xFF4444
        )
        playAnnoyingWarningSound()
    elseif nick == 'Jensen_Ackles' then
        CREATOR_WARN_COOLDOWN = now
        sampAddChatMessage(
            'НЕ БЕЙТЕ ДРУГА СОЗДАТЕЛЯ:goblin::goblin:!!',
            0xFFCC44
        )
        playAnnoyingWarningSound()
    end
end

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

-- MoonLoader console на большинстве сборок ожидает CP1251.
-- Исходник скрипта хранится в UTF-8, поэтому обычный print() русских строк
-- может показывать кракозябры. При этом данные из SA-MP уже могут быть CP1251,
-- поэтому нельзя слепо декодировать любую строку.
local function consoleIsValidUtf8(text)
    text = tostring(text or '')
    local i, n = 1, #text

    while i <= n do
        local b1 = text:byte(i)

        if b1 < 0x80 then
            i = i + 1

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
            if b2 < 0x80 or b2 > 0xBF
                or b3 < 0x80 or b3 > 0xBF
                or b4 < 0x80 or b4 > 0xBF then
                return false
            end
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

    -- UTF-8 литералы из этого файла переводим в CP1251.
    if consoleIsValidUtf8(text) then
        local ok, converted = pcall(cp, text)
        if ok and type(converted) == 'string' then
            return converted
        end
    end

    -- Строки, уже пришедшие из SA-MP в CP1251, оставляем как есть.
    return text
end

local function consolePrint(text)
    local value = consoleText(text)
    local ok = pcall(print, value)

    -- Последний fallback: выводим ASCII-сообщение, чтобы print сам не уронил скрипт.
    if not ok then
        pcall(print, '[Recruit Helper] console print error')
    end
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
    -- Нижний регистр для CP1251: А..Я -> а..я, Ё -> ё.
    return (tostring(text or ''):gsub('.', function(ch)
        local byte = ch:byte()
        if byte >= 0xC0 and byte <= 0xDF then
            return string.char(byte + 0x20)
        elseif byte == 0xA8 then
            return string.char(0xB8)
        elseif byte >= 0x41 and byte <= 0x5A then
            return string.char(byte + 0x20)
        end
        return ch
    end))
end

local function splitWords(text)
    local cleaned = ruLower(trim(text)):gsub('[%p%c]+', ' ')
    local words = {}
    for word in cleaned:gmatch('%S+') do
        words[#words + 1] = word
    end
    return words
end

local function hasWord(text, expected)
    for _, word in ipairs(splitWords(text)) do
        if word == expected then
            return true
        end
    end
    return false
end

-- ЕДИНАЯ очередь исходящего чата.
-- v1.3.14: без lua_thread/coroutine. Очередь обслуживается из main(), поэтому
-- исключение "cannot resume non-suspended coroutine" в отправке чата исключено.
-- Между любыми двумя сообщениями/чат-командами сохраняется минимум 3 секунды.
local outboundQueue = {}
local outboundNextSendAt = 0
local scheduledActions = {}

local function nowMs()
    if type(getGameTimer) == 'function' then
        local ok, value = pcall(getGameTimer)
        if ok and type(value) == 'number' then
            return value
        end
    end
    return os.time() * 1000
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
            if not ok then
                debugLog('Scheduled action failed: ' .. tostring(err))
            end
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
            if item.kind == 'local_command' then
                chatInfo('[TEST локальная команда] ' .. item.text .. (item.testSuffix or ''))
            elseif item.kind == 'command' then
                chatInfo('[TEST команда] ' .. item.text .. (item.testSuffix or ''))
            else
                chatInfo('[TEST -> кандидату] ' .. item.text)
            end
        else
            if item.kind == 'local_command' then
                -- Пропускаем строку через локальный обработчик ввода SA-MP.
                -- Это позволяет другим MoonLoader/SAMPFUNCS-хелперам перехватить /inv,
                -- выполнить свои RP-отыгровки и уже затем отправить настоящую команду.
                sampProcessChatInput(item.text)
            elseif item.kind == 'command' then
                -- Серверные команды (/offer и т.п.) по-прежнему отправляются напрямую.
                sampSendChat(item.text)
            else
                sampSendChat(cp(item.text))
            end
        end
    end)

    outboundNextSendAt = now + (tonumber(CONFIG.outboundDelayMs) or 3000)

    if not ok then
        debugLog('Outbound send failed: ' .. tostring(err))
    end

    if type(item.onSent) == 'function' then
        local callbackOk, callbackErr = pcall(item.onSent)
        if not callbackOk then
            debugLog('Outbound callback failed: ' .. tostring(callbackErr))
        end
    end
end

local lastGcStepAt = 0
local lastHealthLogAt = 0

local function processMaintenance()
    local interval = tonumber(CONFIG.gcIntervalMs) or 60000
    local now = nowMs()

    if lastGcStepAt == 0 or now < lastGcStepAt or now - lastGcStepAt >= interval then
        lastGcStepAt = now
        local ok, err = pcall(function()
            collectgarbage('step', 200)
        end)
        if not ok then
            debugLog('GC step failed: ' .. tostring(err))
        end
    end

    local healthInterval = tonumber(CONFIG.healthLogIntervalMs) or 600000
    if lastHealthLogAt == 0 or now < lastHealthLogAt or now - lastHealthLogAt >= healthInterval then
        lastHealthLogAt = now
        local memoryKb = 0
        local okMemory, value = pcall(function()
            return collectgarbage('count')
        end)
        if okMemory and type(value) == 'number' then
            memoryKb = math.floor(value)
        end

        debugLog(
            'Health: luaKB=' .. tostring(memoryKb)
            .. ', outbound=' .. tostring(#outboundQueue)
            .. ', scheduled=' .. tostring(#scheduledActions)
            .. ', recruit=' .. tostring(session and session.stage or 'n/a')
        )
    end
end

local function outboundEncodedLength(text)
    local ok, converted = pcall(cp, tostring(text or ''))
    if ok and type(converted) == 'string' then
        return #converted
    end
    return #tostring(text or '')
end

-- SA-MP/сервер может обрезать слишком длинные реплики. Если RP-текст длиннее
-- безопасного лимита, делим его по словам. Для длинных многофразовых сообщений
-- стараемся сначала закончить текущую фразу на точке/!/?, чтобы разбиение выглядело естественно.
local function splitCandidateText(text)
    text = trim(tostring(text or ''))
    if text == '' then return {} end

    local maxBytes = tonumber(CONFIG.maxCandidateMessageBytes) or 92
    if outboundEncodedLength(text) <= maxBytes then
        return {text}
    end

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
            else
                current = candidate
            end
        end
    end
    if current ~= '' then
        chunks[#chunks + 1] = current
    end
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
    -- delayMs оставлен в сигнатуре для совместимости. Глобальный антифлуд всегда >= 3 сек.
    for _, line in ipairs(lines or {}) do
        if type(line) == 'string' and line ~= '' then
            enqueueCandidateText(line)
        end
    end
end

-- Всё, что должен видеть кандидат, проходит через эти функции.
-- В тестовом режиме строки также идут через очередь, чтобы визуально проверять реальные интервалы.
local function sendCandidateLine(text, onSent)
    if type(text) ~= 'string' or text == '' then return end
    enqueueCandidateText(text, onSent)
end

local function sendCandidateLines(lines, delayMs)
    sendChatLines(lines, delayMs)
end

-- Наборы RP-реплик. Смысл каждой группы одинаковый, формулировка выбирается случайно.
-- Последний вариант по каждой группе не повторяется два раза подряд.
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
    if type(list) ~= 'table' or #list == 0 then
        return tostring(key or '')
    end

    local index = 1
    if #list > 1 then
        index = math.random(1, #list)
        local previous = lastRpPhraseIndex[key]
        if previous and index == previous then
            index = (index % #list) + 1
        end
    end
    lastRpPhraseIndex[key] = index
    return list[index]
end

local function getSelfIdForShowPass()
    local okCall, okPlayer, selfId = pcall(function()
        local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        return ok, id
    end)

    if okCall and okPlayer and selfId ~= nil then
        return tonumber(selfId)
    end

    return nil
end

local function sendShowPassInstruction(attempt)
    attempt = tonumber(attempt) or 1

    local selfId = getSelfIdForShowPass()
    if selfId ~= nil then
        local line = '/b Передача документов ПО РП!!! Используйте /showpass ' .. tostring(selfId)

        -- /b — серверная команда. Переводим кириллицу в CP1251 заранее,
        -- а затем отправляем именно как command, чтобы строка не потерялась
        -- среди обычных сообщений и не разбивалась функцией splitCandidateText().
        local encoded = line
        local okEncode, converted = pcall(cp, line)
        if okEncode and type(converted) == 'string' then
            encoded = converted
        end

        enqueueOutbound(encoded, 'command', session.testMode)
        debugLog('ShowPass instruction queued. selfId=' .. tostring(selfId))
        return true
    end

    -- Никогда не пишем кандидату текст "мой ID".
    -- Если SA-MP ещё не отдал локальный ID, ждём и пробуем снова.
    if attempt < 10 then
        scheduleAction(500, function()
            sendShowPassInstruction(attempt + 1)
        end)
    else
        chatInfo('Не удалось определить ваш игровой ID для /showpass. Используйте /showpass вручную.')
        debugLog('ShowPass instruction failed: local player ID unavailable after 10 attempts.')
    end

    return false
end


local function russianMinuteWord(value)
    local n = math.abs(math.floor(tonumber(value) or 0))
    local last100 = n % 100
    local last10 = n % 10

    if last100 >= 11 and last100 <= 14 then
        return 'минут'
    end
    if last10 == 1 then
        return 'минута'
    end
    if last10 >= 2 and last10 <= 4 then
        return 'минуты'
    end
    return 'минут'
end

local function sendStroyAnnouncement(arg)
    local minutes = tonumber(tostring(arg or ''):match('^%s*(%d+)%s*$'))

    if not minutes then
        chatInfo('Использование: /str [время в минутах]. Например: /str 5')
        return
    end

    minutes = math.floor(minutes)
    if minutes < 1 or minutes > 180 then
        chatInfo('Время построения должно быть от 1 до 180 минут.')
        return
    end

    local minuteWord = russianMinuteWord(minutes)
    local line = '/r Построение на плацу! Явка обязательна для всего состава. Время на прибытие - '
        .. tostring(minutes) .. ' ' .. minuteWord .. '.'

    local encoded = line
    local okEncode, converted = pcall(cp, line)
    if okEncode and type(converted) == 'string' then
        encoded = converted
    end

    if enqueueOutbound(encoded, 'command', false) then
        chatInfo('Построение объявлено: ' .. tostring(minutes) .. ' ' .. minuteWord .. '.')
        debugLog('Stroy announcement queued: ' .. tostring(minutes) .. ' ' .. minuteWord)
    else
        chatInfo('Не удалось поставить объявление о построении в очередь.')
    end
end

local function sendGameCommand(command)
    if type(command) ~= 'string' or command == '' then return end
    enqueueOutbound(command, 'command', session.testMode)
end

-- Ввод локальной команды так, будто пользователь напечатал её в чат.
-- Нужен для команд сторонних хелперов, например локального /inv с RP-отыгровками.
local function sendLocalCommand(command)
    if type(command) ~= 'string' or command == '' then return end
    enqueueOutbound(command, 'local_command', session.testMode)
end


-- ============================================================================
-- AUTO VOiS — встроено в Recruit Helper 2.0.5
-- ============================================================================
local AUTO_VOIS = {
    enabled = true,

    dialogUnitMain = 8772,
    dialogUnitMenu = 8773,
    dialogWrong = 8776,
    dialogUnitInput = 8777,

    unitMenuResponseIndex = 3, -- визуальный пункт №4
    dialogDelayMs = 300,
    inputSubmitDelayMs = 500,
    setTagDelayMs = 3000,

    searchTries = 20,
    searchDelayMs = 250,
    workflowTimeoutMs = 30000,
}

local AUTO_VOIS_TAG = cp('ВОиС')

local autoVoisState = {
    active = false,
    step = 0,
    token = 0,
    playerId = nil,
    playerNick = nil,

    resolving = false,
    resolveNick = nil,
    resolveTries = 0,
    nextResolveAt = 0,

    deadlineAt = 0,
}

local function autoVoisChat(message, color)
    local line = '[Auto VOiS] ' .. tostring(message)
    consolePrint(line)

    if isSampAvailable() then
        local ok, err = pcall(function()
            sampAddChatMessage(cp(line), color or 0x6EDC6E)
        end)
        if not ok then
            debugLog('Auto VOiS chat failed: ' .. tostring(err))
        end
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

    local okMax, currentMax = pcall(function()
        return sampGetMaxPlayerId(true)
    end)
    if okMax and type(currentMax) == 'number' and currentMax >= 0 then
        maxId = math.min(999, currentMax)
    end

    for playerId = 0, maxId do
        if sampIsPlayerConnected(playerId) then
            local currentNickname = sampGetPlayerNickname(playerId)
            if currentNickname and currentNickname:lower() == target then
                return playerId
            end
        end
    end

    return nil
end

local function autoVoisGetCurrentDialogIdSafe()
    local okActive, active = pcall(function()
        return sampIsDialogActive()
    end)
    if not okActive or not active then return nil end

    local okId, dialogId = pcall(function()
        return sampGetCurrentDialogId()
    end)
    if not okId then return nil end

    return dialogId
end

local function autoVoisSendDialogResponseSafe(dialogId, button, listItem, inputText)
    local currentDialogId = autoVoisGetCurrentDialogIdSafe()
    if currentDialogId ~= dialogId then
        return false, 'текущий диалог: ' .. tostring(currentDialogId)
            .. ', ожидался: ' .. tostring(dialogId)
    end

    local ok, err = pcall(function()
        sampSendDialogResponse(
            dialogId,
            button or 1,
            listItem or 0,
            inputText or ''
        )
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function autoVoisScheduleDialogResponse(dialogId, nextStep, listItem, inputText, delayMs)
    local token = autoVoisState.token
    autoVoisState.step = nextStep

    scheduleAction(delayMs or AUTO_VOIS.dialogDelayMs, function()
        if not AUTO_VOIS.enabled
            or not autoVoisState.active
            or autoVoisState.token ~= token then
            return
        end

        local ok, err = autoVoisSendDialogResponseSafe(
            dialogId,
            1,
            listItem or 0,
            inputText or ''
        )

        if not ok then
            autoVoisChat(
                'Ответ диалогу ' .. tostring(dialogId)
                .. ' отменён: ' .. tostring(err),
                0xFF7777
            )
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
        if not AUTO_VOIS.enabled
            or not autoVoisState.active
            or autoVoisState.token ~= token then
            return
        end

        local okDialog, dialogError = autoVoisSendDialogResponseSafe(
            AUTO_VOIS.dialogUnitInput,
            1,
            0,
            idText
        )

        if not okDialog then
            autoVoisChat('Отправка ID отменена: ' .. tostring(dialogError), 0xFF7777)
            autoVoisCancel()
            return
        end

        autoVoisChat('ID ' .. idText .. ' отправлен. Жду перед выдачей тега...')

        scheduleAction(AUTO_VOIS.setTagDelayMs, function()
            if not AUTO_VOIS.enabled
                or not autoVoisState.active
                or autoVoisState.token ~= token then
                return
            end

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
        if not AUTO_VOIS.enabled
            or not autoVoisState.active
            or autoVoisState.token ~= token then
            return
        end

        autoVoisChat('Найден ' .. playerNick .. '[' .. tostring(playerId) .. ']. Открываю /unit...')
        enqueueOutbound('/unit', 'command', false)
    end)
end

local function autoVoisBeginResolve(newNick)
    if not AUTO_VOIS.enabled or autoVoisState.active or autoVoisState.resolving then
        return
    end

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

    if autoVoisState.active
        and autoVoisState.deadlineAt > 0
        and now >= autoVoisState.deadlineAt then
        autoVoisChat('Тайм-аут на шаге ' .. tostring(autoVoisState.step) .. '.', 0xFF7777)
        autoVoisCancel()
    end
end


-- ============================================================================
-- АВТОБИНДЕР: BATTLE PASS (60 МИН) + DISCORD (60 МИН)
-- ============================================================================
-- Оба блока повторяются каждый час, но сдвинуты друг относительно друга
-- на 30 минут, чтобы не отправлять два длинных объявления подряд.
--
-- ВАЖНО:
--  * сообщения идут через общую outboundQueue;
--  * между строками сохраняется общий антифлуд CONFIG.outboundDelayMs;
--  * во время активного призыва / Auto VOiS автобиндер ждёт;
--  * если очередь уже занята, объявление не вклинивается посередине.
local AUTO_BINDER = {
    enabled = CONFIG.autoBinderEnabled == true,
    battlePassEnabled = CONFIG.battlePassBinderEnabled ~= false,
    discordEnabled = CONFIG.discordBinderEnabled ~= false,
    initialized = false,
    startedAt = 0,
    battlePassNextAt = 0,
    discordNextAt = 0,
}

-- Отдельный стабильный таймер для автобиндера.
-- Не используем getGameTimer(): при входе/перезагрузке его состояние может
-- отличаться от момента инициализации скрипта. Это могло давать мгновенную
-- первую отправку. os.time() здесь достаточно: интервалы измеряются минутами.
local function autoBinderNowMs()
    return os.time() * 1000
end

local BATTLE_PASS_BIND = {
    '/r Уважаемые военнослужащие Армии г. Лос-Сантос.',
    '/r Спешу сообщить, что на Офф.Портале нашего штата появился Баттл Пасс.',
    '/r Выполняйте интересные задания и получайте приятные призы.',
    '/r Успейте принять участие!',
    '/rb https://forum.arizona-rp.com/threads/11293745/',
}

local DISCORD_BIND = {
    '/rb Уважаемые военнослужащие Армии г. Лос-Сантос.',
    '/rb Напоминаю о Discord-сервере нашего штата.',
    '/rb Получите роль "Военнослужащий ЛСа" и заходите в канал "Общение ЛСа".',
    '/rb Общайтесь с сослуживцами, задавайте вопросы и следите за важной информацией.',
    '/rb https://discord.gg/arzspace',
}

local function autoBinderInterval()
    return math.max(60000, tonumber(CONFIG.autoBinderIntervalMs) or 3600000)
end

local function discordBinderInterval()
    return math.max(60000, tonumber(CONFIG.discordBinderIntervalMs) or 3600000)
end

local function autoBinderRetry()
    return math.max(10000, tonumber(CONFIG.autoBinderRetryMs) or 60000)
end

local function initAutoBinderSchedule(resetAll)
    local now = autoBinderNowMs()

    if AUTO_BINDER.initialized and not resetAll then
        return
    end

    AUTO_BINDER.initialized = true
    AUTO_BINDER.startedAt = now

    -- ВАЖНО: после входа никакой мгновенной рекламы.
    -- Сначала всегда проходит полный firstDelay.
    AUTO_BINDER.battlePassNextAt =
        now + math.max(60000, tonumber(CONFIG.battlePassFirstDelayMs) or 3600000)

    AUTO_BINDER.discordNextAt =
        now + math.max(60000, tonumber(CONFIG.discordFirstDelayMs) or 3600000)
end

local function autoBinderIsBusy()
    -- Не мешаем проведению призыва.
    if session and session.active then
        return true, 'идёт призыв'
    end

    -- Не мешаем автоматическому назначению подразделения/тега.
    if autoVoisState
        and (autoVoisState.active or autoVoisState.resolving) then
        return true, 'работает Auto VOiS'
    end

    -- Не вклиниваемся в уже существующую очередь.
    if #outboundQueue > 0 then
        return true, 'очередь сообщений занята'
    end

    if nowMs() < outboundNextSendAt then
        return true, 'действует антифлуд-пауза'
    end

    return false, nil
end

local function enqueueRadioBinder(lines, title)
    if type(lines) ~= 'table' or #lines == 0 then
        return false
    end

    -- Радиокоманды содержат кириллицу. sampSendChat в ветке kind='command'
    -- получает строку напрямую, поэтому переводим UTF-8 литералы в CP1251 заранее.
    for _, line in ipairs(lines) do
        local encoded = line
        local okEncode, converted = pcall(cp, line)
        if okEncode and type(converted) == 'string' then
            encoded = converted
        end

        if not enqueueOutbound(encoded, 'command', false) then
            debugLog('AutoBinder: не удалось поставить строку в очередь: ' .. tostring(line))
            return false
        end
    end

    chatInfo('Автобиндер: «' .. tostring(title) .. '» поставлен в очередь.')
    debugLog('AutoBinder queued: ' .. tostring(title))
    return true
end

local function sendBattlePassBinderNow(ignoreBusy)
    local busy, reason = autoBinderIsBusy()

    if busy and not ignoreBusy then
        chatInfo('Battle Pass сейчас не отправлен: ' .. tostring(reason) .. '.')
        return false
    end

    return enqueueRadioBinder(BATTLE_PASS_BIND, 'Battle Pass')
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
    if not AUTO_BINDER.enabled then
        return
    end

    initAutoBinderSchedule(false)

    local now = autoBinderNowMs()

    -- Дополнительная защита от первой отправки сразу после входа.
    -- Даже если timestamp каким-либо образом повреждён, до первого полного
    -- интервала автобиндер ничего автоматически не отправляет.
    local minFirstDelay = math.min(
        math.max(60000, tonumber(CONFIG.battlePassFirstDelayMs) or 3600000),
        math.max(60000, tonumber(CONFIG.discordFirstDelayMs) or 3600000)
    )
    if AUTO_BINDER.startedAt <= 0 or (now - AUTO_BINDER.startedAt) < minFirstDelay then
        return
    end

    -- Battle Pass.
    if AUTO_BINDER.battlePassEnabled
        and now >= AUTO_BINDER.battlePassNextAt then
        local busy = autoBinderIsBusy()

        if busy then
            AUTO_BINDER.battlePassNextAt = now + autoBinderRetry()
        else
            if sendBattlePassBinderNow(true) then
                AUTO_BINDER.battlePassNextAt = now + autoBinderInterval()
            else
                AUTO_BINDER.battlePassNextAt = now + autoBinderRetry()
            end
        end

        -- После постановки одного длинного блока очередь уже занята.
        -- Второй блок в этот же кадр не запускаем.
        return
    end

    -- Discord.
    if AUTO_BINDER.discordEnabled
        and now >= AUTO_BINDER.discordNextAt then
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
    if not AUTO_BINDER.initialized then
        return '?'
    end

    local left = math.max(0, tonumber(targetAt or 0) - autoBinderNowMs())

    -- Для тестовой версии удобно видеть секунды.
    if left < 120000 then
        return '~' .. tostring(math.ceil(left / 1000)) .. ' сек.'
    end

    return '~' .. tostring(math.ceil(left / 60000)) .. ' мин.'
end

local function printAutoBinderStatus()
    initAutoBinderSchedule(false)

    local bpStatus
    if AUTO_BINDER.battlePassEnabled then
        bpStatus = 'ВКЛ, через ' .. autoBinderTimeLeft(AUTO_BINDER.battlePassNextAt)
    else
        bpStatus = 'ВЫКЛ'
    end

    local dcStatus
    if AUTO_BINDER.discordEnabled then
        dcStatus = 'ВКЛ, через ' .. autoBinderTimeLeft(AUTO_BINDER.discordNextAt)
    else
        dcStatus = 'ВЫКЛ'
    end

    chatInfo(
        'Автобиндер: ' .. (AUTO_BINDER.enabled and 'ВКЛ' or 'ВЫКЛ')
        .. ' | Battle Pass: ' .. bpStatus
        .. ' | Discord: ' .. dcStatus
    )
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

local function toggleAutoBinder()
    setAutoBinderEnabled(not AUTO_BINDER.enabled)
end

local function setBattlePassBinderEnabled(value)
    value = value == true
    AUTO_BINDER.battlePassEnabled = value

    if value then
        AUTO_BINDER.battlePassNextAt =
            autoBinderNowMs() + math.max(60000, tonumber(CONFIG.battlePassFirstDelayMs) or 3600000)
        chatInfo('Автобиндер Battle Pass включён.')
    else
        chatInfo('Автобиндер Battle Pass выключен.')
    end

    printAutoBinderStatus()
end

local function setDiscordBinderEnabled(value)
    value = value == true
    AUTO_BINDER.discordEnabled = value

    if value then
        AUTO_BINDER.discordNextAt =
            autoBinderNowMs() + math.max(60000, tonumber(CONFIG.discordFirstDelayMs) or 3600000)
        chatInfo('Автобиндер Discord включён.')
    else
        chatInfo('Автобиндер Discord выключен.')
    end

    printAutoBinderStatus()
end

local function autoVoisHandleServerMessage(color, text)
    if not AUTO_VOIS.enabled or autoVoisState.active or autoVoisState.resolving then
        return
    end

    local cleanText = (text or ''):gsub('{%x%x%x%x%x%x}', '')

    local okConvert, utf8Text = pcall(function()
        return u8(cleanText)
    end)
    if not okConvert or not utf8Text then return end

    local newNick, inviterNick, inviterId = utf8Text:match(
        'Приветствуем нового члена нашей организации%s+([%w_]+),%s+которого пригласил:%s*([%w_]+)%[(%d+)%]'
    )

    if not newNick then return end

    local myId, myNick = autoVoisGetLocalPlayerData()
    if myId == nil or myNick == nil then
        autoVoisChat('Не удалось определить ваш ID.', 0xFF7777)
        return
    end

    local invitedByMe = tonumber(inviterId) == myId
        or inviterNick:lower() == myNick:lower()

    if not invitedByMe then return end

    autoVoisBeginResolve(newNick)
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if not AUTO_VOIS.enabled or not autoVoisState.active then
        return
    end

    if autoVoisState.step == 1 and dialogId == AUTO_VOIS.dialogUnitMain then
        autoVoisChat('Открыт 8772. Нажимаю левую кнопку.')
        autoVoisScheduleDialogResponse(
            AUTO_VOIS.dialogUnitMain,
            2,
            0,
            '',
            AUTO_VOIS.dialogDelayMs
        )
        return
    end

    if autoVoisState.step == 2 and dialogId == AUTO_VOIS.dialogUnitMenu then
        autoVoisChat('Открыт 8773. Выбираю «Назначить подразделение игроку».')
        autoVoisScheduleDialogResponse(
            AUTO_VOIS.dialogUnitMenu,
            3,
            AUTO_VOIS.unitMenuResponseIndex,
            '',
            AUTO_VOIS.dialogDelayMs
        )
        return
    end

    if autoVoisState.step == 3 and dialogId == AUTO_VOIS.dialogWrong then
        autoVoisChat(
            'Открылся 8776 вместо 8777. Ничего не нажимаю; операция остановлена.',
            0xFF7777
        )
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
    if reason then
        debugLog('Session stopped: ' .. reason)
    end
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
    if message then
        sendCandidateLine(message)
    end
    clearSession(message or 'stopped')
end

local function isTargetAvailable()
    if session.testMode then
        return session.targetId ~= nil
    end
    return session.targetId ~= nil
        and sampIsPlayerConnected(session.targetId)
end

local function getNearestPlayerInFront()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local fx, fy, fz = getOffsetFromCharInWorldCoords(PLAYER_PED, 0.0, 1.0, 0.0)
    local fvx, fvy = fx - px, fy - py
    local flen = math.sqrt(fvx * fvx + fvy * fvy)
    if flen < 0.001 then
        return nil
    end
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
        name = nil,
        years = nil,
        law = nil,
        car = nil,
        gun = nil,
        health = nil,
        dependency = nil,
        medicalExists = nil,
        gotPassport = false,
        gotLicenses = false,
        gotMedical = false,
    }
end

local function validateRpNicknameFormat(nickname)
    nickname = tostring(nickname or '')
    local first, last = nickname:match("^([A-Z][A-Za-z'%-]+)_([A-Z][A-Za-z'%-]+)$")
    if not first or not last then
        return false, nil, nil, 'ник должен иметь вид Name_Surname латиницей'
    end
    if #first < 2 or #last < 2 then
        return false, first, last, 'имя и фамилия слишком короткие'
    end
    if nickname:find('__', 1, true) then
        return false, first, last, 'двойное подчёркивание недопустимо'
    end
    return true, first, last, nil
end

local function urlEncode(textValue)
    return (tostring(textValue or ''):gsub('([^%w%-%._~])', function(ch)
        return string.format('%%%02X', ch:byte())
    end))
end

local function parseNamespediaUsage(html)
    html = tostring(html or '')
    if html == '' then return nil, nil end
    local plain = html
        :gsub('<script.-</script>', ' ')
        :gsub('<style.-</style>', ' ')
        :gsub('<[^>]+>', ' ')
        :gsub('&nbsp;', ' ')
        :gsub('&#37;', '%%')
        :gsub('%s+', ' ')

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
    local check = {
        nickname = nickname,
        localValid = valid,
        first = first,
        last = last,
        onlineDone = false,
        onlineSuspicious = false,
    }

    if attachToSession then
        session.nickCheck = check
    end

    if valid then
        chatInfo('RP-ник: формат ' .. nickname .. ' выглядит корректно (Name_Surname).')
    else
        chatInfo('RP-ник: формат ' .. nickname .. ' сомнительный — ' .. tostring(reason) .. '.')
        return check
    end

    if not CONFIG.checkRpNicknameOnline then
        return check
    end
    if not dlstatus or type(downloadUrlToFile) ~= 'function' then
        chatInfo('RP-ник: онлайн-проверка Namespedia недоступна в этой сборке MoonLoader.')
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
        local firstText = firstPct ~= nil and string.format('%d%% как имя', firstPct) or 'нет данных'
        local lastText = surnamePct ~= nil and string.format('%d%% как фамилия', surnamePct) or 'нет данных'

        chatInfo(string.format('Namespedia: %s — %s; %s — %s.', first, firstText, last, lastText))
        if firstPct == nil or surnamePct == nil then
            chatInfo('RP-ник: Namespedia не дала полный ответ; оставляю решение за вами.')
        elseif firstPct <= 0 or surnamePct <= 0 then
            chatInfo('RP-ник: онлайн-проверка пометила ник как сомнительный. Это подсказка, а не автоматический отказ.')
            check.onlineSuspicious = true
        else
            chatInfo('RP-ник: имя и фамилия найдены в базе Namespedia.')
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

    scheduleAction(CONFIG.nicknameCheckTimeoutMs, function()
        finalize(true)
    end)

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

    -- Для собственного playerId sampIsPlayerConnected(id) на некоторых сборках
    -- возвращает false. В локальном /rtest это нормально: цель виртуальная и
    -- все действия идут только в локальный чат, без команд на сервер.
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
    session.deadline = 0 -- без таймера: ждём ответ на «Здравия желаю, Вы на призыв?» сколько потребуется
    session.docs = newDocsState()

    if not options.skipNickCheck then
        startRpNicknameCheck(session.targetName, true)
    else
        local valid, first, last, reason = validateRpNicknameFormat(session.targetName)
        session.nickCheck = {nickname = session.targetName, localValid = valid, first = first, last = last, reason = reason}
    end

    sendCandidateLine('Здравия желаю, Вы на призыв?')
    chatInfo(string.format('%sКандидат: %s[%d]. Ожидаю положительный ответ.',
        session.testMode and '[TEST] ' or '', session.targetName, id))
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
                    players[#players + 1] = {
                        id = id,
                        distance = dist
                    }
                end
            end
        end
    end

    if #players == 0 then
        chatInfo('В радиусе ' .. tostring(CONFIG.nearDistance) .. ' м. игроков нет.')
        return
    end

    table.sort(players, function(a, b)
        return a.distance < b.distance
    end)

    local ids = {}

    for index, player in ipairs(players) do
        ids[#ids + 1] = tostring(player.id)

        scheduleAction((index - 1) * 300, function()
            sampSendChat('/fractionrp ' .. tostring(player.id))
        end)
    end

    chatInfo('Выдано /fractionrp игрокам: ' .. table.concat(ids, ', ') ..
        ' | Радиус: ' .. tostring(CONFIG.nearDistance) .. ' м.')
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

-- Небольшая дистанция Левенштейна для CP1251/ASCII-слов.
-- В CP1251 русская буква занимает один байт, поэтому побайтового сравнения здесь достаточно.
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

    -- Одна лишняя/пропущенная буква.
    local short, long = a, b
    if la > lb then short, long = b, a end
    local i, j, skipped = 1, 1, false
    while i <= #short and j <= #long do
        if short:byte(i) == long:byte(j) then
            i, j = i + 1, j + 1
        elseif not skipped then
            skipped = true
            j = j + 1
        else
            return false
        end
    end
    return true
end

local function consentHasTypoPositive(answer)
    local words = splitWords(answer)

    -- Короткое «да» нельзя проверять общим fuzzy-сравнением: иначе слова
    -- вроде «на»/«за» могли бы стать ложным согласием. Поэтому частые
    -- реальные опечатки перечислены отдельно.
    local shortTypos = {
        cp('нда'), cp('дда'), cp('даа'), cp('ддаа'), cp('дп'), cp('даж'),
        'yess', 'yees', 'yse', 'ys', 'yep'
    }
    for _, word in ipairs(words) do
        for _, typo in ipairs(shortTypos) do
            if word == typo then return true end
        end
    end

    -- Для более длинных слов допускаем одну ошибку: пропуск, лишнюю букву
    -- или замену буквы. Это покрывает «соглсен», «точнл», «готоф» и т.п.
    local fuzzyPositive = {
        cp('ага'), cp('угу'), cp('конечно'),
        cp('готов'), cp('готова'), cp('давай'), cp('погнали'),
        cp('точно'), cp('согласен'), cp('согласна'),
        cp('разумеется'), cp('безусловно'), cp('верно'),
        cp('йес'),
        'yes', 'yeah', 'okay', 'affirmative'
    }
    for _, word in ipairs(words) do
        for _, expected in ipairs(fuzzyPositive) do
            if #expected >= 4 and editDistanceAtMostOne(word, expected) then
                return true
            end
        end
    end

    return false
end

local function isPositiveConsent(answer)
    local lower = ruLower(answer)

    -- Сначала отсеиваем явный отказ, чтобы фразы вроде «не готов»
    -- не засчитались как положительный ответ из-за слова «готов».
    local negativeWords = {
        cp('нет'), cp('не'), cp('неа'),
        'no', 'nope', 'nah'
    }
    for _, word in ipairs(negativeWords) do
        if hasWord(lower, word) then
            return false
        end
    end
    if lower:find(cp('отказываюсь'), 1, true)
        or lower:find(cp('не хочу'), 1, true) then
        return false
    end

    -- Принимаем обычные, разговорные и строевые варианты согласия.
    -- В частности: «так точно», «так точно, генерал», «есть»,
    -- «согласен», «готов служить», а также yes/ес/йес и т.п.
    local positiveWords = {
        cp('да'), cp('ага'), cp('угу'), cp('конечно'),
        cp('готов'), cp('готова'), cp('давай'), cp('погнали'),
        cp('точно'), cp('есть'), cp('согласен'), cp('согласна'),
        cp('разумеется'), cp('безусловно'), cp('верно'),
        cp('ес'), cp('йес'),
        'yes', 'yeah', 'yep', 'ye', 'y', 'ok', 'okay', 'affirmative'
    }
    for _, word in ipairs(positiveWords) do
        if hasWord(lower, word) then
            return true
        end
    end

    local positivePhrases = {
        cp('так точно'),
        cp('готов служить'), cp('готова служить'),
        cp('готов к призыву'), cp('готова к призыву'),
        cp('согласен на призыв'), cp('согласна на призыв'),
        cp('на призыв'),
    }
    for _, phrase in ipairs(positivePhrases) do
        if lower:find(phrase, 1, true) then
            return true
        end
    end

    -- Последний слой: допускаем небольшие опечатки в положительном ответе.
    if consentHasTypoPositive(lower) then
        return true
    end

    return false
end

local function answerLooksNegative(answer)
    local lower = ruLower(answer)
    local negativeWords = {
        cp('нет'), cp('неа'),
        'no', 'nope', 'nah'
    }
    for _, word in ipairs(negativeWords) do
        if hasWord(lower, word) then
            return true
        end
    end
    return lower:find(cp('отказываюсь'), 1, true) ~= nil
        or lower:find(cp('не хочу'), 1, true) ~= nil
end

-- Отправка CEF-команды клиентом. Формат восстановлен по приложенному логу:
-- packet 220 -> subtype 18 -> server_id 0 -> int16 length -> text.
local function sendArizonaCefCommand(text)
    local ok, err = pcall(function()
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, 220)
        raknetBitStreamWriteInt8(bs, 18)
        raknetBitStreamWriteInt32(bs, 0)
        raknetBitStreamWriteInt16(bs, #text)
        raknetBitStreamWriteString(bs, text)
        raknetSendBitStreamEx(bs, 1, 3, 0) -- HIGH_PRIORITY, RELIABLE_ORDERED
        raknetDeleteBitStream(bs)
    end)
    if not ok then
        debugLog('CEF send failed: ' .. tostring(err))
    else
        debugLog('CEF send: ' .. text)
    end
    return ok
end

local function requestDocumentPage(page)
    if not CONFIG.autoSwitchDocumentPages then
        return
    end
    if session.testMode then
        chatInfo('[TEST CEF] documents.changePage|' .. tostring(page))
        return
    end
    scheduleAction(350, function()
        if session.active then
            sendArizonaCefCommand('documents.changePage|' .. tostring(page))
        end
    end)
end

local function parseFirstNumber(value)
    if value == nil then return nil end
    local matched = tostring(value):match('(%d+[%.,]?%d*)')
    if not matched then return nil end
    return tonumber((matched:gsub(',', '.')))
end

local function isValidUtf8(text)
    text = tostring(text or '')
    local i, n = 1, #text
    while i <= n do
        local b1 = text:byte(i)
        if b1 < 0x80 then
            i = i + 1
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

local function toCp1251Safe(value)
    local text = tostring(value or '')
    if text == '' then return text end

    -- SA-MP chat is normally already CP1251. Decode ONLY strings that are
    -- actually valid UTF-8 (CEF/JSON). Re-decoding CP1251 was corrupting
    -- Russian initials, e.g. «Следственный комитет» for СК.
    if not isValidUtf8(text) then
        return text
    end

    local ok, converted = pcall(function()
        return u8:decode(text)
    end)
    if ok and type(converted) == 'string' then
        return converted
    end
    return text
end

local function containsHealthyMark(value)
    local original = tostring(value or '')
    if original == '' then return false end

    -- В разных сборках Arizona статус медкарты может приходить как текст
    -- ИЛИ отдельным числовым кодом. Текст проверяем сразу в нескольких
    -- представлениях, потому что CEF обычно UTF-8, а MoonLoader-чат CP1251.
    local cpText = ruLower(toCp1251Safe(original))
    local originalLower = original:lower()

    return cpText:find(cp('полностью здоров'), 1, true) ~= nil
        or original:find('Полностью здоров', 1, true) ~= nil
        or original:find('полностью здоров', 1, true) ~= nil
        or original:find(cp('Полностью здоров'), 1, true) ~= nil
        or original:find(cp('полностью здоров'), 1, true) ~= nil
        or originalLower:find('fully healthy', 1, true) ~= nil
end

local function parseMedicalHealthStatus(value)
    if value == nil then return nil, nil end

    -- Классическая серверная шкала медкарты Arizona:
    -- -1 = карты нет, 0 = не определено, 1/2 = нездоров, 3 = полностью здоров.
    -- Это особенно важно для CEF: интерфейс может рисовать текст
    -- «Полностью здоровый(ая)», получая от сервера только число 3.
    local numeric = tonumber(value)
    if numeric ~= nil then
        if numeric == -1 then
            return nil, -1
        elseif numeric == 3 then
            return true, 3
        elseif numeric == 0 or numeric == 1 or numeric == 2 then
            return false, numeric
        end
    end

    if type(value) == 'boolean' then
        return value, nil
    end

    return containsHealthyMark(value), nil
end

local function tableContainsHealthyMark(value, depth)
    depth = depth or 0
    if depth > 6 then return false end

    local valueType = type(value)
    if valueType == 'string' or valueType == 'number' then
        return containsHealthyMark(value)
    elseif valueType ~= 'table' then
        return false
    end

    for _, child in pairs(value) do
        if tableContainsHealthyMark(child, depth + 1) then
            return true
        end
    end
    return false
end

local function firstValue(tbl, keys)
    if type(tbl) ~= 'table' then return nil end
    for _, key in ipairs(keys) do
        if tbl[key] ~= nil then
            return tbl[key]
        end
    end
    return nil
end

local function valueToBoolean(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'number' then return value ~= 0 end
    if value == nil then return nil end

    local text = ruLower(toCp1251Safe(trim(value)))

    -- Сначала отрицания: иначе строка «не имеется» совпадёт со словом «имеется».
    if text == '0' or text == 'false' or text == 'no'
        or text == cp('нет') or text:find(cp('отсутств'), 1, true)
        or text:find(cp('не имеется'), 1, true)
        or text:find(cp('неактив'), 1, true) then
        return false
    end
    if text == '1' or text == 'true' or text == 'yes'
        or text == cp('да') or text == cp('есть')
        or text:find(cp('имеется'), 1, true)
        or text:find(cp('актив'), 1, true) then
        return true
    end
    return nil
end

local function looksLikeCarLicense(name)
    local text = ruLower(toCp1251Safe(name))
    return text == 'car' or text:find('driv', 1, true) ~= nil
        or text:find(cp('авто'), 1, true) ~= nil
        or text:find(cp('водител'), 1, true) ~= nil
end

local function looksLikeGunLicense(name)
    local text = ruLower(toCp1251Safe(name))
    return text == 'gun' or text:find('weapon', 1, true) ~= nil
        or text:find(cp('оруж'), 1, true) ~= nil
end

-- Термины для скрытой RP-проверки. Кандидату НЕ сообщается правило ответа.
-- Правильный ответ: в реплике должна находиться подходящая пара слов по буквам сокращения,
-- Дополнительные RP-вопросы для ручного собеседования.
-- Справа снизу показывается только краткая суть, а кандидату уходит полный вопрос.
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
        if not session.rpAsked[q.id] then
            available[#available + 1] = q
        end
    end

    -- Если все вопросы уже использовали, начинаем новый круг без повторов внутри одной пятёрки.
    if #available < 5 then
        session.rpAsked = {}
        available = {}
        for _, q in ipairs(RP_QUESTION_POOL) do
            available[#available + 1] = q
        end
    end

    -- Перемешиваем локально и берём первые пять.
    for i = #available, 2, -1 do
        local j = math.random(1, i)
        available[i], available[j] = available[j], available[i]
    end

    session.rpMenuChoices = {}
    for i = 1, math.min(5, #available) do
        session.rpMenuChoices[i] = available[i]
    end
end

local function openRpQuestionMenu()
    if not session.active then return end
    refillRpMenuChoices()
    session.stage = 'rp_menu'
    session.answers = {}
    session.deadline = 0
    session.rpCurrent = nil
    chatInfo('Выберите RP-вопрос цифрами 1-5 в верхнем ряду клавиатуры. 2 в меню — перейти к проверке терминов.')
end

local function askRpMenuQuestion(index)
    if not session.active or session.stage ~= 'rp_menu' then return end
    index = tonumber(index)
    local q = index and session.rpMenuChoices and session.rpMenuChoices[index] or nil
    if not q then
        chatInfo('Для этой клавиши сейчас нет вопроса.')
        return
    end

    session.rpAsked = session.rpAsked or {}
    session.rpAsked[q.id] = true
    session.rpCurrent = q
    session.stage = 'rp_custom'
    session.answers = {}
    session.deadline = 0
    sendCandidateLine(q.text)
    chatInfo('Задан RP-вопрос: ' .. q.short .. '. Таймера нет. После полного ответа нажмите 2.')
end

-- но не стандартная OOC/RP-расшифровка игрового термина.
local TERM_QUESTIONS = {
    {
        code = 'MG', label = 'МГ', first = 'м', second = 'г',
        forbidden = {'метагейм', 'мета гейм', 'metagaming', 'meta gaming'},
        testGood = 'Мирные граждане',
        testBad = 'Метагейминг',
    },
    {
        code = 'PG', label = 'ПГ', first = 'п', second = 'г',
        forbidden = {'пауэргейм', 'пауэр гейм', 'пауер гейм', 'повергейм', 'повер гейм', 'powergaming', 'power gaming'},
        testGood = 'Полевые госпитали',
        testBad = 'Пауэр гейминг',
    },
    {
        code = 'SK', label = 'СК', first = 'с', second = 'к',
        forbidden = {'спавнкил', 'спавн кил', 'спаункил', 'спаун кил', 'spawnkill', 'spawn kill'},
        testGood = 'Северные корабли',
        testBad = 'Спавн килл',
    },
    {
        code = 'DM', label = 'ДМ', first = 'д', second = 'м',
        forbidden = {'дезматч', 'дез матч', 'дэсматч', 'дэс матч', 'дэзматч', 'дэз матч', 'deathmatch', 'death match', 'убийство без причины'},
        testGood = 'Дорожные машины',
        testBad = 'Дез матч',
    },
    {
        code = 'DB', label = 'ДБ', first = 'д', second = 'б',
        forbidden = {'драйвбай', 'драйв бай', 'driveby', 'drive by', 'убийство машиной', 'убийство с машины'},
        testGood = 'Домашние блюда',
        testBad = 'Драйв бай',
    },
}

local function pickTermQuestion(excludeCode)
    local available = {}
    for _, term in ipairs(TERM_QUESTIONS) do
        if not excludeCode or term.code ~= excludeCode then
            available[#available + 1] = term
        end
    end
    if #available == 0 then
        return TERM_QUESTIONS[1]
    end
    return available[math.random(1, #available)]
end

local function findTermQuestion(code)
    code = tostring(code or ''):upper()
    for _, term in ipairs(TERM_QUESTIONS) do
        if term.code == code then
            return term
        end
    end
    return nil
end

local function startSpecificTermQuestion(term)
    if not session.active or type(term) ~= 'table' then return end
    session.stage = 'q2'
    session.answers = {}
    session.deadline = 0 -- ждём первую реплику без ограничения времени
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
        chatInfo('Ручной режим: таймера нет. Ждите полный ответ и нажмите 2, когда будете готовы продолжить.')
    elseif stage == 'q2' then
        session.deadline = 0
        session.q2Term = pickTermQuestion(nil)
        session.q2FirstTermCode = session.q2Term.code
        sendCandidateLine('Что такое «' .. session.q2Term.label .. '»?')
        chatInfo('Скрытая RP-проверка: термин ' .. session.q2Term.label .. '. Таймера нет; после полного ответа нажмите 2.')
    elseif stage == 'q2_retry' then
        session.deadline = 0
        session.q2Term = pickTermQuestion(session.q2FirstTermCode)

        -- После первой ошибки подсказка и новый Q2 отправляются ОДНИМ сообщением.
        -- Это специально сделано для серверов с жёстким антифлудом: второй отправки
        -- после бренда больше нет вообще.
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
            if not session.active or session.stage ~= 'q2_retry_hint' then
                return
            end
            if not session.q2Term or session.q2Term.code ~= retryCode then
                return
            end

            session.stage = 'q2_retry'
            session.answers = {}
            session.deadline = 0
            chatInfo('Задан повторный RP-термин: ' .. retryLabel .. '. Подсказка и вопрос отправлены одной строкой; таймера нет, после полного ответа нажмите 2.')
        end)

        chatInfo('Первая проверка термина не пройдена. Подсказка и повторный Q2 отправляются кандидату одним сообщением.')
    elseif stage == 'q3' then
        session.deadline = 0
        sendCandidateLine('Что у меня над головой?')
        chatInfo('Таймера нет. После полного ответа нажмите 2 для проверки.')
    end
end

local function joinedAnswers()
    return trim(table.concat(session.answers or {}, ' '))
end

local function validateTermAnswer(answer, term)
    if type(term) ~= 'table' then
        return false
    end

    local lower = ruLower(answer)
    for _, bad in ipairs(term.forbidden or {}) do
        local needle = bad
        local hasNonAscii = false
        for i = 1, #needle do
            if needle:byte(i) >= 128 then
                hasNonAscii = true
                break
            end
        end
        if hasNonAscii then
            needle = cp(needle)
        end
        if lower:find(ruLower(needle), 1, true) then
            return false
        end
    end

    -- Ответ может быть разговорным и состоять из нескольких реплик. Например:
    --   «Понятно.»
    --   «Дядя миша?»
    -- для ДМ должен засчитываться. joinedAnswers() склеивает реплики, а здесь
    -- дополнительно нормализуем кодировку в CP1251, чтобы первые русские буквы
    -- одинаково работали и для UTF-8, и для обычного SA-MP-чата.
    local normalized = toCp1251Safe(answer)
    local words = splitWords(normalized)
    if #words < 2 then
        debugLog('Term answer rejected: too few words; term=' .. tostring(term.code) .. ', answer=' .. tostring(answer))
        return false
    end

    local firstExpected = ruLower(cp(term.first))
    local secondExpected = ruLower(cp(term.second))

    local function startsWith(word, expected)
        word = ruLower(tostring(word or ''))
        return word ~= '' and word:sub(1, #expected) == expected
    end

    -- Сначала ищем естественную соседнюю пару («Дядя Миша»).
    for i = 1, #words - 1 do
        if startsWith(words[i], firstExpected)
            and startsWith(words[i + 1], secondExpected) then
            return true
        end
    end

    -- Разрешаем максимум два промежуточных слова: это покрывает разговорные
    -- ответы вроде «Дядя, ну, Миша», не требуя от кандидата идеальной фразы.
    for i = 1, #words do
        if startsWith(words[i], firstExpected) then
            local last = math.min(#words, i + 3)
            for j = i + 1, last do
                if startsWith(words[j], secondExpected) then
                    return true
                end
            end
        end
    end

    debugLog('Term answer rejected: initials not found; term=' .. tostring(term.code)
        .. ', answer=' .. tostring(answer) .. ', words=' .. table.concat(words, '|'))
    return false
end

local function validateAboveHead(answer)
    local lower = ruLower(trim(answer))
    if lower == '' then return false end

    local forbidden = {
        cp('ник'), cp('никнейм'), cp('имя'), cp('айди'),
        'nickname', 'name', 'id'
    }
    for _, word in ipairs(forbidden) do
        if lower:find(word, 1, true) then
            return false
        end
    end

    local selfOk, selfId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if selfOk then
        local selfName = ruLower(sampGetPlayerNickname(selfId) or '')
        if selfName ~= '' then
            if lower:find(selfName, 1, true)
                or lower:find(selfName:gsub('_', ' '), 1, true) then
                return false
            end
        end
    end

    return true
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
        if CONFIG.autoInvite then
            enqueueOutbound('/inv ' .. tostring(id), 'local_command', true, ' — реальная команда НЕ отправлена.')
        else
            chatInfo('[TEST] Автоматический /inv отключён.')
        end
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
    if not (d.gotPassport and d.gotLicenses and d.gotMedical) then
        return
    end

    local problems = {}
    local function addProblem(code, privateText, rpText)
        problems[#problems + 1] = {code = code, private = privateText, rp = rpText}
    end

    if session.targetName and d.name and ruLower(d.name) ~= ruLower(session.targetName) then
        addProblem('wrong_owner',
            'предъявлены документы другого человека',
            rpPhrase('wrong_owner'))
    end

    if CONFIG.blockBadNicknameFormat and session.nickCheck and session.nickCheck.localValid == false then
        addProblem('bad_nickname_format',
            'ник кандидата не соответствует формату RP Name_Surname',
            rpPhrase('bad_nickname_format'))
    elseif CONFIG.strictRpNicknameOnline and session.nickCheck and session.nickCheck.onlineSuspicious == true then
        addProblem('bad_nickname_online',
            'онлайн-проверка Namespedia пометила имя или фамилию как сомнительные',
            rpPhrase('bad_nickname_online'))
    end

    if d.years == nil then
        addProblem('years_unknown',
            'не удалось считать количество лет в штате',
            rpPhrase('years_unknown'))
    elseif d.years < 3 then
        addProblem('low_years',
            'лет в штате: ' .. tostring(d.years) .. ' (требуется минимум 3)',
            rpPhrase('low_years'))
    end

    if d.law == nil then
        addProblem('law_unknown',
            'не удалось считать законопослушность',
            rpPhrase('law_unknown'))
    elseif d.law < 35 then
        addProblem('low_law',
            'законопослушность: ' .. tostring(d.law) .. ' (требуется минимум 35)',
            rpPhrase('low_law'))
    end

    if d.car == false then
        addProblem('no_car_license',
            'отсутствует лицензия на вождение автомобиля',
            rpPhrase('no_car_license'))
    elseif d.car == nil then
        addProblem('car_unknown',
            'не удалось определить наличие лицензии на автомобиль',
            rpPhrase('car_unknown'))
    end

    if d.gun == nil then
        addProblem('gun_unknown',
            'не удалось определить наличие лицензии на оружие',
            rpPhrase('gun_unknown'))
    end

    if d.medicalExists == false then
        -- Если медкарты нет вообще, НЕ добавляем отдельные ошибки здоровья/зависимости.
        addProblem('no_medical_card',
            'медицинская карта отсутствует',
            rpPhrase('no_medical_card'))
    elseif d.medicalExists == nil then
        addProblem('medical_unknown',
            'не удалось определить наличие медицинской карты',
            rpPhrase('medical_unknown'))
    else
        if d.health ~= true then
            addProblem('bad_health',
                'в медкарте нет пометки «Полностью здоров»',
                rpPhrase('bad_health'))
        end
        if d.dependency == nil then
            addProblem('dependency_unknown',
                'не удалось определить показатель зависимости от укропа',
                rpPhrase('dependency_unknown'))
        elseif d.dependency > 5 then
            addProblem('high_dependency',
                'зависимость от укропа: ' .. tostring(d.dependency) .. ' (допустимо до 5 включительно)',
                rpPhrase('high_dependency'))
        end
    end

    if #problems > 0 then
        chatInfo('Кандидат НЕ прошёл проверку документов. Причины видны только вам:')
        local rpLines = {}
        for _, problem in ipairs(problems) do
            chatInfo('• ' .. problem.private .. '.')
            if problem.rp and problem.rp ~= '' then
                rpLines[#rpLines + 1] = problem.rp
            end
        end
        sendCandidateLines(rpLines)
        clearSession('documents failed')
        return
    end

    session.stage = 'documents_passed'
    local function continueAfterDocuments()
        if d.gun == false then
            sendCandidateLine(rpPhrase('no_gun_license'))
        else
            sendCandidateLine(rpPhrase('docs_ok'))
        end
        beginQuestion('q1')
    end

    -- Сообщение о документах и следующий вопрос проходят через общую очередь,
    -- поэтому между ними автоматически будет минимум 3 секунды.
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
        if eventName:find('document', 1, true)
            or eventName:find('passport', 1, true)
            or eventName:find('license', 1, true)
            or eventName:find('medical', 1, true) then
            return true
        end
    end

    return context.rawLooksDocument == true
end

local function documentStageAllows(kind)
    if session.testMode then return true end

    if kind == 'passport' then
        return session.stage == 'wait_documents'
            and session.docs
            and not session.docs.gotPassport
    elseif kind == 'licenses' then
        return session.stage == 'documents_passport'
            and session.docs
            and session.docs.gotPassport
            and not session.docs.gotLicenses
    elseif kind == 'medical' then
        return session.stage == 'documents_licenses'
            and session.docs
            and session.docs.gotPassport
            and session.docs.gotLicenses
            and not session.docs.gotMedical
    end
    return false
end

local function ignoreDocumentCandidate(reason, docType)
    debugLog('CEF document candidate ignored: ' .. tostring(reason)
        .. ', type=' .. tostring(docType)
        .. ', stage=' .. tostring(session.stage))
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

    -- В меню персонажа Arizona тоже встречаются объекты с type=1/2/4.
    -- Поэтому одного номера type недостаточно: принимаем страницу только на ожидаемом этапе
    -- и только при наличии характерных полей документа.
    local passportYears = parseFirstNumber(yearsValue)
    local passportLaw = parseFirstNumber(lawValue)
    local strongPassport = passportYears ~= nil and passportLaw ~= nil
    local isPassport = strongPassport

    local hasLicenseContainer = firstValue(data, {'info', 'licenses', 'license', 'items'}) ~= nil
    local parsedCar, parsedGun = parseLicenses(data)
    local strongLicenses = hasLicenseContainer or parsedCar ~= nil or parsedGun ~= nil
    local isLicenses = strongLicenses and not (healthValue ~= nil or dependencyValue ~= nil)

    local explicitMedicalMarker = firstValue(data, {
        'medicalExists', 'hasMedical', 'hasMedicalCard', 'hasMedCard', 'hasCard'
    })
    local strongMedical = healthValue ~= nil or dependencyValue ~= nil or explicitMedicalMarker ~= nil
    -- Пустой type=4 используется сервером для отсутствующей медкарты. Его разрешаем только
    -- когда мы действительно ждём медкарту И CEF-событие/сырой пакет относится к documents.
    local isMedical = strongMedical
        or (docType == 4 and documentStageAllows('medical') and docsContext)

    if docType == 1 and not strongPassport then
        return ignoreDocumentCandidate('type=1 without passport fields (likely character/inventory CEF)', docType)
    end

    if isPassport then
        if not documentStageAllows('passport') then
            return ignoreDocumentCandidate('passport arrived outside wait_documents or already captured', docType)
        end

        session.docs.name = firstValue(data, {'name', 'nickname', 'playerName', 'fio'})
        session.docs.years = passportYears
        session.docs.law = passportLaw
        session.docs.gotPassport = true
        session.stage = 'documents_passport'
        session.deadline = 0 -- ждём вкладку лицензий столько, сколько потребуется
        debugLog(string.format('Passport captured: name=%s, years=%s, law=%s, type=%s',
            tostring(session.docs.name), tostring(session.docs.years), tostring(session.docs.law), tostring(docType)))
        chatInfo(string.format('Паспорт считан: лет в штате — %s, законопослушность — %s.',
            tostring(session.docs.years or '?'), tostring(session.docs.law or '?')))
        requestDocumentPage(2)
        return true
    end

    if docType == 2 and not strongLicenses then
        return ignoreDocumentCandidate('type=2 without license fields/container', docType)
    end

    if isLicenses then
        if not documentStageAllows('licenses') then
            return ignoreDocumentCandidate('licenses arrived outside documents_passport or already captured', docType)
        end

        local car, gun = parsedCar, parsedGun
        if docType == 2 and hasLicenseContainer then
            if car == nil then car = false end
            if gun == nil then gun = false end
        end
        session.docs.car = car
        session.docs.gun = gun
        session.docs.gotLicenses = car ~= nil or gun ~= nil or hasLicenseContainer
        if not session.docs.gotLicenses then
            return ignoreDocumentCandidate('license data contained no recognizable values', docType)
        end
        session.stage = 'documents_licenses'
        session.deadline = 0 -- ждём медкарту столько, сколько потребуется
        debugLog(string.format('Licenses captured: car=%s, gun=%s, type=%s',
            tostring(car), tostring(gun), tostring(docType)))
        local carLabel = session.docs.car == true and 'есть' or (session.docs.car == false and 'нет' or 'не определено')
        local gunLabel = session.docs.gun == true and 'есть' or (session.docs.gun == false and 'нет' or 'не определено')
        chatInfo('Лицензии считаны: авто — ' .. carLabel .. ', оружие — ' .. gunLabel .. '.')
        requestDocumentPage(4)
        return true
    end

    if docType == 4 and not isMedical then
        return ignoreDocumentCandidate('type=4 without medical fields and without document CEF context', docType)
    end

    if isMedical then
        if not documentStageAllows('medical') then
            return ignoreDocumentCandidate('medical data arrived outside documents_licenses or already captured', docType)
        end

        local explicitExists = valueToBoolean(firstValue(data, {
            'medicalExists', 'hasMedical', 'hasMedicalCard', 'hasMedCard', 'hasCard', 'exists', 'available'
        }))
        local healthText = ruLower(toCp1251Safe(trim(healthValue or '')))
        local parsedHealth, healthCode = parseMedicalHealthStatus(healthValue)
        local explicitMissing = healthCode == -1
            or healthText:find(cp('отсутств'), 1, true) ~= nil
            or healthText:find(cp('не имеется'), 1, true) ~= nil
            or healthText:find(cp('нет мед'), 1, true) ~= nil
            or healthText:find('no medical', 1, true) ~= nil

        local medicalExists = explicitExists
        if explicitMissing then
            medicalExists = false
        elseif medicalExists == nil then
            if healthValue ~= nil or dependencyValue ~= nil then
                medicalExists = true
            elseif docType == 4 and docsContext then
                -- На Arizona отсутствие медкарты часто приходит как пустой документ type=4.
                medicalExists = false
            end
        end

        session.docs.medicalExists = medicalExists
        if medicalExists == false then
            session.docs.health = nil
            session.docs.dependency = nil
        else
            -- Сначала доверяем специальному полю/коду состояния.
            -- Если сервер прислал текст состояния в другом вложенном поле,
            -- дополнительно ищем «Полностью здоров...» во всём объекте документа.
            session.docs.health = parsedHealth
            if session.docs.health ~= true and tableContainsHealthyMark(data) then
                session.docs.health = true
            end
            session.docs.dependency = parseFirstNumber(dependencyValue)
        end
        session.docs.gotMedical = true
        session.stage = 'documents_complete'
        debugLog(string.format('Medical captured: exists=%s, state=%s, healthCode=%s, healthy=%s, dependency=%s, type=%s',
            tostring(session.docs.medicalExists), tostring(healthValue), tostring(healthCode), tostring(session.docs.health), tostring(session.docs.dependency), tostring(docType)))
        if session.docs.health ~= true then
            local okJson, rawMedical = pcall(encodeJson, data)
            if okJson then
                debugLog('Medical health mark not found; raw data=' .. tostring(rawMedical))
            end
        end

        if session.docs.medicalExists == false then
            chatInfo('Медкарта: отсутствует.')
        else
            local healthLabel = session.docs.health == true and 'полностью здоров' or 'не подходит'
            chatInfo('Медкарта считана: здоровье — ' .. healthLabel
                .. ', зависимость — ' .. tostring(session.docs.dependency or '?') .. '.')
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
            if escaped then
                escaped = false
            elseif ch == '\\' then
                escaped = true
            elseif ch == '"' then
                inString = false
            end
        else
            if ch == '"' then
                inString = true
            elseif ch == '{' or ch == '[' then
                stack[#stack + 1] = ch
            elseif ch == '}' or ch == ']' then
                local expected = ch == '}' and '{' or '['
                if stack[#stack] ~= expected then return nil end
                stack[#stack] = nil
                if #stack == 0 then
                    return text:sub(startPos, i)
                end
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
            if candidate and #candidate <= 131072
                and (candidate:find('"type"%s*:') or candidate:find('"documentType"%s*:'))
                and not seen[candidate] then
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
    if numericType == 1 or numericType == 2 or numericType == 4
        or firstValue(node, {'zakono', 'lawfulness', 'yearsInState', 'zavisimost', 'ukropDependency'}) ~= nil
        or firstValue(node, {'healthState', 'healthStatus', 'licenses'}) ~= nil then
        return node
    end

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
    if data then
        return handleDocumentData(data, context)
    end
    return false
end

local function handleCefRaw(raw)
    raw = tostring(raw or '')
    if raw == '' then return false end

    local lowerRaw = ruLower(raw)
    local rawLooksDocument = lowerRaw:find('document', 1, true) ~= nil
        or lowerRaw:find('passport', 1, true) ~= nil
        or lowerRaw:find('license', 1, true) ~= nil
        or lowerRaw:find('medical', 1, true) ~= nil

    local eventName, payload = extractCefEvent(raw)
    if eventName then
        debugLog('CEF event: ' .. tostring(eventName))
        local context = {
            eventName = eventName,
            rawLooksDocument = rawLooksDocument,
        }
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
    return (raw:gsub('[%z\1-\8\11\12\14-\31\127-\255]', function(ch)
        return string.format('\\x%02X', ch:byte())
    end))
end

local function getBitstreamBitsUsedSafe(bs)
    local okBits, bits = pcall(function()
        if type(raknetBitStreamGetNumberOfBitsUsed) == 'function' then
            return raknetBitStreamGetNumberOfBitsUsed(bs)
        end
        return nil
    end)
    if okBits and type(bits) == 'number' and bits > 0 then
        return bits
    end

    local okBytes, bytes = pcall(function()
        return raknetBitStreamGetNumberOfBytesUsed(bs)
    end)
    if okBytes and type(bytes) == 'number' and bytes > 0 then
        return bytes * 8
    end

    return nil
end

local function getBitstreamReadOffsetSafe(bs)
    local ok, offset = pcall(function()
        return raknetBitStreamGetReadOffset(bs)
    end)
    if ok and type(offset) == 'number' then
        return offset
    end
    return nil
end

local function setBitstreamReadOffsetSafe(bs, offset)
    if type(offset) ~= 'number' or offset < 0 then return false end
    local ok = pcall(function()
        raknetBitStreamSetReadOffset(bs, offset)
    end)
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
    if type(length) ~= 'number' or length <= 0 or length > maxPayload then
        return nil
    end

    -- Для обычной строки можем строго проверить, что declared length помещается
    -- в оставшуюся часть bitstream. Это защищает нативные RakNet-функции от
    -- чтения за пределами повреждённого пакета.
    if encoded ~= 1 and remainingBits() < length * 8 then
        return nil
    end

    if encoded == 1 then
        -- Сжатая строка имеет переменный размер, поэтому ограничиваем только
        -- заявленную длину и наличие данных после заголовка.
        if remainingBits() <= 0 then return nil end
        return raknetBitStreamDecodeString(bs, length)
    end

    return raknetBitStreamReadString(bs, length)
end

-- v2.0.4: FFI-доступ к внутреннему указателю RakNet полностью удалён.
-- Документы разбираются только через ограниченные чтения BitStream.
-- Это снижает риск нативного access violation при долгой игровой сессии.
function onReceivePacket(id, bs)
    if id ~= 220 or not session.active then return end

    local originalOffset = getBitstreamReadOffsetSafe(bs)
    local bitsUsed = getBitstreamBitsUsedSafe(bs)
    if not originalOffset or not bitsUsed or bitsUsed <= 0 then
        return
    end

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
                    if CONFIG.packetLog and session.packetCount <= (tonumber(CONFIG.packetLogLimit) or 40) then
                        debugLog('Packet 220 decoded: ' .. packetSnippet(decoded))
                    end

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
    return clean:find(name, 1, true) ~= nil
        or clean:find(spaced, 1, true) ~= nil
end

local function extractTargetSpeech(clean)
    -- Обычно Arizona выводит: Nick_Name[id] говорит: текст
    local body = clean:match(':%s*(.+)$')
    return trim(body or '')
end

local function appendInterviewAnswer(body)
    if body == '' then return end
    session.answers[#session.answers + 1] = body

    -- v1.4.0: с этапа «Расскажите о себе» интервью полностью ручное.
    -- Никаких таймеров после первой/последующих реплик больше не запускаем.
    session.deadline = 0
end

local function handleTargetSpeech(body)
    body = trim(body or '')
    if body == '' or not session.active then return end

    local now = os.clock()
    if session.lastSpeechBody == body and now - (session.lastSpeechAt or 0) < 0.8 then
        return
    end
    session.lastSpeechBody = body
    session.lastSpeechAt = now
    debugLog('Target speech [' .. tostring(session.stage) .. ']: ' .. body)

    if session.stage == 'wait_consent' then
        if answerLooksNegative(body) then
            stopWithMessage(rpPhrase('consent_negative'))
        elseif isPositiveConsent(body) then
            session.stage = 'wait_offer'
            session.deadline = 0 -- ждём предложение документов без тайм-аута
            -- Сначала RP-просьба о документах, затем отдельная OOC-команда
            -- с реальным текущим ID локального игрока.
            sendCandidateLines({
                rpPhrase('docs_request')
            })
            sendShowPassInstruction(1)
            chatInfo('Положительный ответ получен. Ожидаю предложение документов от ' .. session.targetName .. '.')
        end
        return
    end

    if session.stage == 'q1'
        or session.stage == 'rp_custom'
        or session.stage == 'q2'
        or session.stage == 'q2_retry'
        or session.stage == 'q3' then
        appendInterviewAnswer(body)
    end
end

-- Обычный SA-MP чат приходит именно этим RPC, без ника внутри текста.
-- v2.0.7: срабатывает когда игрок наносит урон другому игроку
function sampev.onSendGiveDamage(playerId, damage, weapon, bodypart)
    checkProtectedHit(tonumber(playerId))
end

function sampev.onChatMessage(playerId, text)
    if session.active and tonumber(playerId) == tonumber(session.targetId) then
        handleTargetSpeech(text)
    end
end

function sampev.onServerMessage(color, text)
    autoVoisHandleServerMessage(color, text)

    if not session.active then return end
    local clean = stripColors(text)

    -- Предложение документов.
    if session.stage == 'wait_offer' then
        local lower = ruLower(clean)
        local offerMarker = cp('вам поступило предложение от игрока')
        if lower:find(offerMarker, 1, true) and messageIsFromTarget(clean) then
            session.stage = 'wait_documents'
            session.deadline = 0 -- CEF/паспорт ждём без ограничения времени
            chatInfo('Предложение документов найдено.')
            if CONFIG.autoAcceptOffer then
                scheduleAction(250, function()
                    if session.active and session.stage == 'wait_documents' then
                        sendGameCommand('/offer')
                        chatInfo('Команда /offer поставлена в очередь. Ожидаю паспорт.')
                    end
                end)
            else
                chatInfo('Примите предложение командой /offer или клавишей X.')
            end
            return
        end
    end

    if not messageIsFromTarget(clean) then
        return
    end

    local body = extractTargetSpeech(clean)
    if body ~= '' then
        handleTargetSpeech(body)
    end
end

local function processCurrentTermAnswer()
    local answer = joinedAnswers()
    if answer == '' then
        chatInfo('Кандидат ещё не дал ответ на термин. Жду ответ; таймера нет.')
        return
    end

    if validateTermAnswer(answer, session.q2Term) then
        beginQuestion('q3')
    elseif session.stage == 'q2' then
        session.q2Retry = true
        beginQuestion('q2_retry')
    else
        local code = session.q2Term and session.q2Term.code or 'unknown'
        failProfessional('wrong RP-term answer: ' .. tostring(code))
    end
end

local function manualAdvanceInterview()
    if not session.active then
        chatInfo('Активной проверки нет.')
        return
    end

    local stage = session.stage
    if stage == 'q1' then
        -- Рассказ не оцениваем автоматически: пользователь сам решает, когда ответа достаточно.
        openRpQuestionMenu()

    elseif stage == 'rp_custom' then
        -- После любого дополнительного RP-вопроса возвращаем выбор. Можно задать ещё один.
        openRpQuestionMenu()

    elseif stage == 'rp_menu' then
        -- 2 прямо в меню означает «RP-вопросов достаточно, перейти к терминам».
        beginQuestion('q2')

    elseif stage == 'q2' or stage == 'q2_retry' then
        processCurrentTermAnswer()

    elseif stage == 'q2_retry_hint' then
        chatInfo('Подождите отправки следующего термина после антифлуд-паузы.')

    elseif stage == 'q3' then
        local answer = joinedAnswers()
        if answer == '' then
            chatInfo('Кандидат ещё не дал ответ на последний вопрос. Жду ответ; таймера нет.')
        elseif validateAboveHead(answer) then
            finishSuccess()
        else
            failProfessional('wrong above-head answer')
        end

    else
        chatInfo('2 используется на этапе собеседования после проверки документов.')
    end
end

-- --------------------------------------------------------------------------
-- HUD интервью справа снизу
-- --------------------------------------------------------------------------
local interviewHudFont = nil
local interviewHudFontFailed = false

local function ensureInterviewHudFont()
    if interviewHudFont or interviewHudFontFailed or not CONFIG.interviewHud then
        return interviewHudFont ~= nil
    end
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

    if stage == 'wait_consent' then
        lines = {'RECRUIT', 'Сейчас: «Здравия желаю, Вы на призыв?»', 'Следующее: дождаться ответа'}
    elseif stage == 'wait_offer' then
        lines = {'RECRUIT', 'Следующее: кандидат передаёт документы', 'Ожидание без таймера'}
    elseif stage == 'wait_documents' then
        lines = {'RECRUIT', 'Следующее: паспорт', 'Ожидание CEF без таймера'}
    elseif stage == 'documents_passport' then
        lines = {'RECRUIT', 'Паспорт проверен', 'Следующее: открыть лицензии'}
    elseif stage == 'documents_licenses' then
        lines = {'RECRUIT', 'Лицензии проверены', 'Следующее: открыть медкарту'}
    elseif stage == 'q1' then
        lines = {'СОБЕСЕДОВАНИЕ', 'Сейчас: рассказ о себе', '2: выбрать следующий RP-вопрос'}
    elseif stage == 'rp_menu' then
        lines = {'ВЫБОР RP-ВОПРОСА'}
        for i = 1, 5 do
            local q = session.rpMenuChoices and session.rpMenuChoices[i] or nil
            lines[#lines + 1] = q and (tostring(i) .. ': ' .. q.short) or (tostring(i) .. ': —')
        end
        lines[#lines + 1] = '2: перейти к терминам'
    elseif stage == 'rp_custom' then
        local short = session.rpCurrent and session.rpCurrent.short or 'RP-вопрос'
        lines = {'СОБЕСЕДОВАНИЕ', 'Сейчас: ' .. short, 'Таймера нет', '2: выбор следующего вопроса'}
    elseif stage == 'q2' or stage == 'q2_retry' then
        local label = session.q2Term and session.q2Term.label or 'термин'
        lines = {'ПРОВЕРКА ТЕРМИНА', 'Сейчас: «' .. label .. '»', 'Таймера нет', '2: проверить полный ответ'}
    elseif stage == 'q2_retry_hint' then
        lines = {'ПРОВЕРКА ТЕРМИНА', 'Подсказка отправлена', 'Следующий термин через антифлуд-паузу'}
    elseif stage == 'q3' then
        lines = {'ФИНАЛЬНЫЙ ВОПРОС', 'Что у меня над головой?', 'Таймера нет', '2: проверить полный ответ'}
    else
        return nil
    end

    -- Быстрое ручное принятие доступно на любом активном этапе.
    lines[#lines + 1] = 'F: принять сразу'
    return lines
end

local function drawInterviewHud()
    if not CONFIG.interviewHud then return end
    local lines = getInterviewHudLines()
    if not lines or #lines == 0 then return end
    if not ensureInterviewHudFont() then return end
    if type(getScreenResolution) ~= 'function' or type(renderFontDrawText) ~= 'function' then return end

    local ok, sx, sy = pcall(getScreenResolution)
    if not ok or not sx or not sy then return end

    local width = 390
    local lineHeight = 19
    local height = 18 + (#lines * lineHeight)
    local x = sx - width - 22
    local y = sy - height - 70

    if type(renderDrawBox) == 'function' then
        pcall(renderDrawBox, x - 10, y - 8, width + 16, height + 8, 0xA0000000)
    end

    for i, line in ipairs(lines) do
        local color = (i == 1) and 0xFF84D7FF or 0xFFFFFFFF
        pcall(renderFontDrawText, interviewHudFont, cp(line), x, y + (i - 1) * lineHeight, color)
    end
end

-- Выбор RP-вопросов только цифрами верхнего ряда клавиатуры (1-5).
-- NumPad намеренно не используется.
local TOP_NUMBER_KEYS = {0x31, 0x32, 0x33, 0x34, 0x35}

local KEY_2 = 0x32 -- верхний ряд цифр, не NumPad
local KEY_F = vkeys.VK_F or 0x46

local function forceAcceptCurrentCandidate()
    if not session.active then
        chatInfo('Активной проверки нет.')
        return
    end

    if not isTargetAvailable() then
        chatInfo('Кандидат недоступен — быстрое принятие отменено.')
        return
    end

    chatInfo('F: оставшиеся этапы пропущены. Кандидат будет принят вручную.')
    finishSuccess()
end

local function handleInterviewHotkeys()
    if not session.active or sampIsChatInputActive() or sampIsDialogActive() then return end

    -- F: мгновенно завершить текущую проверку успешным принятием.
    if wasKeyPressed(KEY_F) then
        forceAcceptCurrentCandidate()
        return
    end

    if wasKeyPressed(KEY_2) then
        manualAdvanceInterview()
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
end

local function processDeadline()
    if not session.active or session.deadline <= 0 or os.time() < session.deadline then
        return
    end

    local stage = session.stage
    session.deadline = 0

    -- На этапах ожидания до первого действия таймеров нет. Эти ветки могут
    -- сработать только при ручном /rnext; тогда просто оставляем этап активным.
    if stage == 'wait_consent' then
        chatInfo('Ожидаю ответ кандидата на вопрос о призыве. Тайм-аута нет.')

    elseif stage == 'wait_offer' then
        chatInfo('Ожидаю предложение документов. Тайм-аута нет.')

    elseif stage == 'wait_documents' then
        chatInfo('Ожидаю появление CEF/паспорта. Тайм-аута нет.')

    elseif stage == 'documents_passport' and not session.docs.gotLicenses then
        chatInfo('Ожидаю вкладку лицензий. Откройте её вручную, если автопереход не сработал.')

    elseif stage == 'documents_licenses' and not session.docs.gotMedical then
        chatInfo('Ожидаю медицинскую карту. Откройте её вручную, если автопереход не сработал.')

    elseif stage == 'q1' or stage == 'rp_custom' or stage == 'q2' or stage == 'q2_retry' or stage == 'q3' then
        -- v1.4.0: интервью полностью ручное. Даже принудительный дедлайн не двигает этап.
        chatInfo('На этапе собеседования таймеры отключены. Используйте 2 для перехода/проверки ответа.')
    end
end

local function printStatus()
    if not session.active then
        chatInfo('Активной проверки нет.')
        return
    end
    if session.deadline <= 0 then
        chatInfo(string.format('Кандидат: %s[%d], этап: %s, таймер: без ограничения.',
            tostring(session.targetName), tonumber(session.targetId) or -1,
            tostring(session.stage)))
    else
        local seconds = math.max(0, session.deadline - os.time())
        chatInfo(string.format('Кандидат: %s[%d], этап: %s, осталось: %d сек.',
            tostring(session.targetName), tonumber(session.targetId) or -1,
            tostring(session.stage), seconds))
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
    if not id then
        chatInfo('[TEST] Не удалось определить ваш ID.')
        return false
    end
    startRecruitment(id, {testMode = true, skipNickCheck = true})
    return true
end

local function ensureTestDocumentsStage(resetDocs)
    if not ensureSelfTestSession() then return false end
    if resetDocs then
        session.docs = newDocsState()
    end
    session.stage = 'wait_documents'
    session.deadline = 0
    return true
end

local function testPassport(years, law, name)
    if not ensureTestDocumentsStage(false) then return end
    handleDocumentData({
        type = 1,
        name = name or session.targetName,
        level = tostring(years or 5),
        zakono = tostring(law or 50),
    })
end

local function testLicenses(car, gun)
    if not ensureTestDocumentsStage(false) then return end
    if not session.docs.gotPassport then testPassport(5, 50) end
    handleDocumentData({
        type = 2,
        info = {
            {license = 'car', available = car and 1 or 0},
            {license = 'gun', available = gun and 1 or 0},
        }
    })
end

local function testMedical(mode)
    if not ensureTestDocumentsStage(false) then return end
    if not session.docs.gotPassport then testPassport(5, 50) end
    if not session.docs.gotLicenses then testLicenses(true, true) end

    if mode == 'none' then
        handleDocumentData({type = 4})
    elseif mode == 'badhealth' then
        handleDocumentData({type = 4, state = 'Требуется лечение', zavisimost = '0'})
    elseif mode == 'weed' then
        handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '6'})
    elseif mode == 'uihealthy' then
        -- Имитирует вариант интерфейса, где текст здоровья лежит не в стандартном поле state.
        handleDocumentData({type = 4, statusText = 'Полностью здоровый(ая)', zavisimost = '0'})
    elseif mode == 'healthcode' then
        -- Реальный CEF может передавать состояние числом: 3 = «Полностью здоровый(ая)».
        handleDocumentData({type = 4, state = 3, zavisimost = '0'})
    else
        handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '0'})
    end
end

local function resetTestScenario(targetName)
    local id = getSelfPlayerId()
    if not id then
        chatInfo('[TEST] Не удалось определить ваш ID.')
        return false
    end
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

    if kind == 'badnick' then
        session.nickCheck = {nickname = session.targetName, localValid = false}
    end

    handleDocumentData({type = 1, name = session.targetName, level = tostring(years), zakono = tostring(law)})
    handleDocumentData({
        type = 2,
        info = {
            {license = 'car', available = car and 1 or 0},
            {license = 'gun', available = gun and 1 or 0},
        }
    })

    if kind == 'nomed' or kind == 'allbad' then
        handleDocumentData({type = 4})
    elseif kind == 'badhealth' then
        handleDocumentData({type = 4, state = 'Требуется лечение', zavisimost = '0'})
    elseif kind == 'weed' then
        handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '6'})
    else
        handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '0'})
    end
end

local function simulateTestOffer()
    if not ensureSelfTestSession() then return end
    session.stage = 'wait_documents'
    session.deadline = 0
    chatInfo('[TEST] Сымитировано предложение документов.')
    if CONFIG.autoAcceptOffer then
        sendGameCommand('/offer')
    end
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

    if action == 'start' then
        clearSession('test restart')
        ensureSelfTestSession()
        return
    elseif action == 'yes' then
        if ensureSelfTestSession() then handleTargetSpeech(cp('Да')) end
        return
    elseif action == 'yesvariants' then
        local variants = {'Да', 'нДа', 'дда', 'даа', 'yes', 'ес', 'йес', 'ага', 'угу', 'конечно', 'готов', 'готоф', 'давай', 'yep', 'yeah', 'ok', 'так точно', 'так точнл генерал', 'так точно товарищ генерал', 'есть', 'согласен', 'соглсен', 'готов служить', 'готов к призыву', 'разумеется'}
        chatInfo('[TEST] Проверяю варианты положительного ответа:')
        for _, value in ipairs(variants) do
            local encoded = cp(value)
            chatInfo(string.format('[TEST] %-10s -> %s', value, isPositiveConsent(encoded) and 'ДА' or 'НЕТ'))
        end
        return
    elseif action == 'say' then
        if rest == '' then
            chatInfo('[TEST] Использование: /rtest say текст ответа')
        elseif ensureSelfTestSession() then
            handleTargetSpeech(rest)
        end
        return
    elseif action == 'offer' then
        simulateTestOffer()
        return
    elseif action == 'passport' then
        testPassport(5, 50)
        return
    elseif action == 'licenses' then
        testLicenses(true, true)
        return
    elseif action == 'medical' then
        testMedical('good')
        return
    elseif action == 'healthui' then
        testMedical('uihealthy')
        return
    elseif action == 'healthcode' then
        testMedical('healthcode')
        return
    elseif action == 'longmsg' then
        if ensureSelfTestSession() then
            sendCandidateLine('В Вашей медицинской карте отсутствует пометка «Полностью здоров». Пройдите обследование в любой больнице штата.')
            chatInfo('[TEST] Длинная реплика поставлена в очередь. Она должна разбиться на короткие сообщения с паузой 3 секунды.')
        end
        return
    elseif action == 'docsok' then
        runDocumentTestScenario('docsok')
        return
    elseif action == 'nomed' or action == 'badhealth' or action == 'weed'
        or action == 'nocar' or action == 'nogun' or action == 'lowyears'
        or action == 'lowlaw' or action == 'badnick' or action == 'allbad' then
        runDocumentTestScenario(action)
        return
    elseif action == 'q1' then
        if ensureSelfTestSession() then beginQuestion('q1') end
        return
    elseif action == 'menu' then
        if ensureSelfTestSession() then openRpQuestionMenu() end
        return

    elseif action == 'pick' or action == 'rp' then
        if ensureSelfTestSession() then
            if session.stage ~= 'rp_menu' then openRpQuestionMenu() end
            local index = tonumber(rest)
            if index and index >= 1 and index <= 5 then
                askRpMenuQuestion(index)
            else
                chatInfo('[TEST] Использование: /rtest pick 1 .. 5')
            end
        end
        return

    elseif action == 'advance' then
        if ensureSelfTestSession() then manualAdvanceInterview() end
        return
    elseif action == 'q2' then
        if ensureSelfTestSession() then beginQuestion('q2') end
        return
    elseif action == 'term' then
        if not ensureSelfTestSession() then return end
        local term = findTermQuestion(rest)
        if not term then
            chatInfo('[TEST] Использование: /rtest term MG | PG | SK | DM | DB')
        else
            startSpecificTermQuestion(term)
        end
        return
    elseif action == 'q3' then
        if ensureSelfTestSession() then beginQuestion('q3') end
        return
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
        if session.docs.gotPassport == before and not session.docs.gotPassport then
            chatInfo('[TEST] OK: посторонний type=1 проигнорирован, «Паспорт считан» появиться не должен.')
        else
            chatInfo('[TEST] ОШИБКА: посторонний CEF был принят за паспорт.')
        end
        return
    elseif action == 'phrases' then
        chatInfo('[TEST] Случайные RP-формулировки:')
        local keys = {
            'success', 'professional_fail', 'low_years', 'low_law',
            'no_car_license', 'no_gun_license', 'no_medical_card',
            'bad_health', 'high_dependency', 'docs_ok'
        }
        for _, key in ipairs(keys) do
            chatInfo('[TEST -> кандидату] [' .. key .. '] ' .. rpPhrase(key))
        end
        return
    elseif action == 'fullpass' then
        if not resetTestScenario(nil) then return end
        chatInfo('[TEST] Полный успешный сценарий.')
        session.stage = 'wait_consent'
        handleTargetSpeech(cp('Да'))
        simulateTestOffer()
        handleDocumentData({type = 1, name = session.targetName, level = '5', zakono = '50'})
        handleDocumentData({type = 2, info = {
            {license = 'car', available = 1},
            {license = 'gun', available = 1},
        }})
        handleDocumentData({type = 4, state = 'Полностью здоров', zavisimost = '0'})
        handleTargetSpeech(cp('Я проживаю в штате давно и готов проходить службу'))
        manualAdvanceInterview() -- q1 -> меню
        manualAdvanceInterview() -- меню -> термин
        local termAnswer = session.q2Term and session.q2Term.testGood or 'Мирные граждане'
        handleTargetSpeech(cp(termAnswer))
        manualAdvanceInterview() -- термин -> последний вопрос
        handleTargetSpeech(cp('Потолок'))
        manualAdvanceInterview() -- завершение
        return
    end

    chatInfo('[TEST] Неизвестная команда. Используйте /rtest help.')
end

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
        else
            autoVoisChat('Автоматизация включена.')
        end
    end)

    sampRegisterChatCommand('avstate', function()
        autoVoisChat(
            'enabled=' .. tostring(AUTO_VOIS.enabled)
            .. ', active=' .. tostring(autoVoisState.active)
            .. ', resolving=' .. tostring(autoVoisState.resolving)
            .. ', step=' .. tostring(autoVoisState.step)
            .. ', ID=' .. tostring(autoVoisState.playerId)
        )
    end)

    local function showDiagnostics()
        local memoryKb = -1

        local okMemory, memoryValue = pcall(function()
            return collectgarbage('count')
        end)

        if okMemory and type(memoryValue) == 'number' then
            memoryKb = math.floor(memoryValue)
        end

        local recruitStage = 'unknown'
        if type(session) == 'table' then
            recruitStage = tostring(session.stage or 'idle')
        end

        local voisStep = 'unknown'
        local voisActive = false
        if type(autoVoisState) == 'table' then
            voisStep = tostring(autoVoisState.step or 0)
            voisActive = autoVoisState.active == true
        end

        local outboundCount = type(outboundQueue) == 'table' and #outboundQueue or -1
        local scheduledCount = type(scheduledActions) == 'table' and #scheduledActions or -1

        local message =
            'v2.0.8 | Lua: ' .. (memoryKb >= 0 and (tostring(memoryKb) .. ' KB') or 'N/A')
            .. ' | Queue: ' .. tostring(outboundCount)
            .. ' | Tasks: ' .. tostring(scheduledCount)
            .. ' | Recruit: ' .. recruitStage
            .. ' | VOiS: ' .. (voisActive and 'ON/' or 'OFF/') .. voisStep

        -- В чат.
        local okChat, chatErr = pcall(function()
            chatInfo(message)
        end)

        -- И в консоль/лог, чтобы диагностика осталась даже если SA-MP чат недоступен.
        consolePrint('[Recruit DIAG] ' .. message)
        debugLog('DIAG: ' .. message)

        if not okChat then
            consolePrint('[Recruit DIAG] chat output failed: ' .. tostring(chatErr))
        end
    end


-- ============================================================================
-- ОБНОВЛЕНИЕ СКРИПТА
-- ============================================================================
local UPDATE_STATE = {
    busy = false,
    manifestPath = nil,
    scriptTempPath = nil,
}

local function updateConfigured()
    return type(CONFIG.updateManifestUrl) == 'string'
        and CONFIG.updateManifestUrl ~= ''
        and type(CONFIG.updateScriptUrl) == 'string'
        and CONFIG.updateScriptUrl ~= ''
end

local function compareVersionParts(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or ''):gmatch('%d+') do
            t[#t + 1] = tonumber(n) or 0
        end
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

local function currentScriptVersion()
    return '2.0.8'
end

local function updaterDownload(url, path, callback)
    if type(downloadUrlToFile) ~= 'function' then
        callback(false, 'downloadUrlToFile недоступен')
        return
    end

    -- Удаляем старый временный файл, чтобы не прочитать остаток прошлой загрузки.
    if doesFileExist(path) then
        pcall(os.remove, path)
    end

    local finished = false

    local ok, err = pcall(function()
        downloadUrlToFile(url, path, function(id, status, p1, p2)
            if finished then return end

            if dlstatus then
                -- STATUS_ENDDOWNLOADDATA может прийти до окончательной записи файла на диск.
                -- Продолжаем только после полного завершения загрузки.
                if status == dlstatus.STATUSEX_ENDDOWNLOAD then
                    finished = true

                    scheduleAction(200, function()
                        if doesFileExist(path) then
                            callback(true)
                        else
                            callback(false, 'файл после загрузки не найден: ' .. tostring(path))
                        end
                    end)

                elseif status == dlstatus.STATUS_ERROR
                    or status == dlstatus.STATUSEX_ERROR
                    or status == dlstatus.STATUS_ABORT then

                    finished = true
                    callback(false, 'ошибка загрузки, status=' .. tostring(status))
                end
            else
                -- Fallback для сборок MoonLoader без download_status.
                if status == 6 then
                    finished = true

                    scheduleAction(300, function()
                        if doesFileExist(path) then
                            callback(true)
                        else
                            callback(false, 'файл после загрузки не найден: ' .. tostring(path))
                        end
                    end)
                end
            end
        end)
    end)

    if not ok then
        finished = true
        callback(false, 'не удалось запустить загрузку: ' .. tostring(err))
    end
end

local function installDownloadedScript(tempPath)
    local thisPath = thisScript().path
    if not thisPath or thisPath == '' then
        return false, 'не удалось определить путь текущего скрипта'
    end

    local input = io.open(tempPath, 'rb')
    if not input then
        return false, 'не удалось открыть скачанный файл'
    end
    local data = input:read('*a')
    input:close()

    if type(data) ~= 'string' or #data < 1000 then
        return false, 'скачанный файл слишком маленький или пустой'
    end

    if not data:find("script_name", 1, true)
        or not data:find("Recruit Helper", 1, true) then
        return false, 'скачанный файл не похож на Recruit Helper'
    end

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

    -- Временные файлы обновления создаём рядом с текущим скриптом.
    -- Это важно для Arizona Launcher: getWorkingDirectory() в некоторых сборках
    -- уже может указывать на папку moonloader, поэтому дописывание \\moonloader\\
    -- давало ошибочный путь ...\\moonloader\\moonloader\\...
    local thisPath = thisScript() and thisScript().path or ''
    local base = thisPath:match('^(.*[\\/])')

    if not base or base == '' then
        base = tostring(getWorkingDirectory() or '')
        if base:sub(-1) ~= '\\' and base:sub(-1) ~= '/' then
            base = base .. '\\'
        end
    end

    local manifestPath = base .. 'recruit_helper_update_version.tmp'
    local scriptTempPath = base .. 'recruit_helper_update_script.tmp'
    UPDATE_STATE.manifestPath = manifestPath
    UPDATE_STATE.scriptTempPath = scriptTempPath

    if manual then
        chatInfo('Проверяю обновление Recruit Helper...')
    end

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
            UPDATE_STATE.busy = false
            chatInfo('Установлена актуальная версия v' .. localVersion .. '.')
            return
        end

        chatInfo('Найдена новая версия v' .. remoteVersion .. '. Скачиваю...')

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

            chatInfo('Обновление установлено. Перезагружаю Recruit Helper...')
            debugLog('Updater installed remote version ' .. tostring(remoteVersion))
            scheduleAction(1000, function()
                thisScript():reload()
            end)
        end)
    end)
end

    sampRegisterChatCommand('rdiag', showDiagnostics)
    sampRegisterChatCommand('diag', showDiagnostics)

    sampRegisterChatCommand('str', sendStroyAnnouncement)
    sampRegisterChatCommand('update', function()
        checkForUpdate(true)
    end)

    -- Автобиндер.
    -- /autobinder оставлен как быстрый toggle.
    sampRegisterChatCommand('autobinder', toggleAutoBinder)
    sampRegisterChatCommand('bindon', function()
        setAutoBinderEnabled(true)
    end)
    sampRegisterChatCommand('bindoff', function()
        setAutoBinderEnabled(false)
    end)

    -- Отдельное управление двумя объявлениями.
    sampRegisterChatCommand('bpon', function()
        setBattlePassBinderEnabled(true)
    end)
    sampRegisterChatCommand('bpoff', function()
        setBattlePassBinderEnabled(false)
    end)
    sampRegisterChatCommand('dcon', function()
        setDiscordBinderEnabled(true)
    end)
    sampRegisterChatCommand('dcoff', function()
        setDiscordBinderEnabled(false)
    end)

    sampRegisterChatCommand('bindstatus', printAutoBinderStatus)

    -- Ручная отправка блоков. Они всё равно проходят через общую антифлуд-очередь.
    sampRegisterChatCommand('battlepass', function()
        if sendBattlePassBinderNow(false) then
            AUTO_BINDER.battlePassNextAt = autoBinderNowMs() + autoBinderInterval()
        end
    end)

    sampRegisterChatCommand('discordls', function()
        if sendDiscordBinderNow(false) then
            AUTO_BINDER.discordNextAt = autoBinderNowMs() + discordBinderInterval()
        end
    end)

    sampRegisterChatCommand('near', startNearest)
    sampRegisterChatCommand('rrp', giveFractionRpInRadius)
    sampRegisterChatCommand('recruit', function(arg)
        local id = tonumber(trim(arg))
        if id then
            startRecruitment(id)
        else
            chatInfo('Использование: /recruit ID')
        end
    end)
    sampRegisterChatCommand('rstop', function()
        clearSession('manual stop')
        chatInfo('Проверка остановлена.')
    end)
    sampRegisterChatCommand('rstatus', printStatus)
    sampRegisterChatCommand('raccept', forceAcceptCurrentCandidate)
    local function skipActiveTimer()
        if not session.active then
            chatInfo('Активной проверки нет.')
            return
        end

        if session.stage == 'q1' or session.stage == 'rp_menu' or session.stage == 'rp_custom'
            or session.stage == 'q2' or session.stage == 'q2_retry' or session.stage == 'q2_retry_hint'
            or session.stage == 'q3' then
            manualAdvanceInterview()
            return
        end

        if session.deadline <= 0 then
            chatInfo('Сейчас активного таймера нет. Ожидаю действие кандидата или открытие документов.')
            return
        end

        local seconds = math.max(0, session.deadline - os.time())
        session.deadline = os.time()
        chatInfo(string.format('Таймер пропущен%s.',
            seconds > 0 and (' (оставалось ' .. tostring(seconds) .. ' сек.)') or ''))
    end

    sampRegisterChatCommand('rskip', skipActiveTimer)
    -- Старую /rnext сохраняем как алиас, чтобы прежние привычки/заметки работали.
    sampRegisterChatCommand('rnext', skipActiveTimer)
    sampRegisterChatCommand('roff', function()
        CONFIG.autoInvite = not CONFIG.autoInvite
        chatInfo('Автоматический /inv: ' .. (CONFIG.autoInvite and 'включён' or 'выключен') .. '.')
    end)
    sampRegisterChatCommand('rlog', function()
        chatInfo('Лог диагностики: ' .. getDebugLogPath())
    end)
    sampRegisterChatCommand('rtest', runTestCommand)
    sampRegisterChatCommand('rnick', function(arg)
        local nick = trim(arg or '')
        if nick == '' then
            chatInfo('Использование: /rnick Name_Surname')
            return
        end
        startRpNicknameCheck(nick, false)
    end)

    debugLog('Recruit Helper 2.0.8 loaded. Safe CEF mode enabled; FFI packet scan removed.')

    initAutoBinderSchedule(true)

    chatInfo('Загружен v2.0.8. /near или Alt+1. Интервью: 2, вопросы: 1-5 сверху, F: принять сразу.')
    chatInfo('Строй: /str [минуты]. Обновление: /update.')
    chatInfo('Автобиндер запущен с таймера: первая реклама только через 60 минут. /bindon /bindoff /bindstatus.')
    chatInfo('Отдельно: /bpon /bpoff (Battle Pass), /dcon /dcoff (Discord), вручную: /battlepass /discordls.')
    printAutoBinderStatus()
    autoVoisChat('Встроенный Auto VOiS v2 активен. Команды: /autovois, /avstate')
    if CONFIG.updateCheckOnStart then
        scheduleAction(3000, function()
            checkForUpdate(false)
        end)
    end

    while true do
        wait(0)

        -- Все отложенные действия и исходящий чат обслуживаются главным циклом.
        -- Это намеренно не использует lua_thread/coroutine.
        processScheduledActions()
        processOutboundQueue()
        processAutoVois()
        processAutoBinder()
        processMaintenance()
        drawInterviewHud()
        handleInterviewHotkeys()

        if CONFIG.hotkeyAltN
            and not sampIsChatInputActive()
            and not sampIsDialogActive()
            and isKeyDown(vkeys.VK_MENU)
            and wasKeyPressed(0x31) then
            startNearest()
        end

        if session.active and not session.testMode and session.targetId
            and not sampIsPlayerConnected(session.targetId) then
            chatInfo('Кандидат вышел из игры. Проверка остановлена.')
            clearSession('target disconnected')
        else
            processDeadline()
        end
    end
end
