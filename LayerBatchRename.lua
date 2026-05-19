-- ============================================================
-- Aseprite 批量重命名图层 v0.0.3
-- 功能：批量重命名选中图层，支持模式检测、变量替换和序号生成
-- ============================================================

-- ============================================================
-- 常量定义
-- ============================================================

local SCRIPT_NAME = "批量重命名图层"
local SCRIPT_VERSION = "1.0.0"
local ERROR_LOG_FILE = "LayerBatchRename_ErrorLog.txt"
local VAR_CHARS = "1234567890abcefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local MAX_VARS = #VAR_CHARS
local PH = "#"

local function escapeLiteralPH(str)
    return str:gsub(PH, PH .. PH)
end

local CANVAS_WIDTH = 520
local CANVAS_MAX_HEIGHT = 300
local ROW_HEIGHT = 18
local HEADER_HEIGHT = 22
local COL_WIDTH = 258
local COL_GAP = 4
local TEXT_PADDING_X = 6
local TEXT_PADDING_Y = 3
local SCROLLBAR_WIDTH = 10
local SCROLLBAR_MIN_THUMB = 20

local ERROR_CODES = {
    E001 = { msg = "未打开任何文档", detail = "请先在 Aseprite 中打开一个文档后再运行此脚本。" },
    E002 = { msg = "未选中任何图层", detail = "请在时间轴中选中至少一个图层后再运行此脚本。" },
    E201 = { msg = "图层 '{layerName}' 重命名失败", detail = "该图层可能被锁定。请检查图层状态后重试。" },
    E203 = { msg = "表达式与图层名不匹配", detail = "原始表达式无法匹配部分图层名，请检查表达式或图层名。" },
    E204 = { msg = "序号参数无效", detail = "序号起始和步长必须为整数（可为负数）。" },
    E205 = { msg = "新图层名不能为空", detail = "表达式生成的名称不能为空字符串。" },
    E206 = { msg = "变量数量超过限制", detail = "图层名差异过大，变量数量超过 " .. MAX_VARS .. " 个。请减少选中图层数量。" },
    E999 = { msg = "未知错误", detail = "发生了未预期的错误。请将错误信息反馈给开发者。" },
}

-- ============================================================
-- 工具函数
-- ============================================================

local function posToVarChar(pos)
    if pos < 1 or pos > MAX_VARS then return nil end
    return VAR_CHARS:sub(pos, pos)
end

local function varCharToPos(ch)
    local idx = VAR_CHARS:find(ch, 1, true)
    if idx == nil then return -1 end
    return idx
end

local function isVarChar(ch)
    return VAR_CHARS:find(ch, 1, true) ~= nil
end

local MAGIC_CHARS = "^$()%.[]*+-?"
local function escapeMagicChar(c)
    if MAGIC_CHARS:find(c, 1, true) then
        return "%" .. c
    end
    return c
end

local function padNumber(num, width)
    if width <= 0 then return tostring(num) end
    local isNeg = num < 0
    local s = tostring(math.abs(num))
    while #s < width do s = "0" .. s end
    if isNeg then return "-" .. s end
    return s
end

-- ============================================================
-- 错误处理
-- ============================================================

local function getErrorCodeInfo(code)
    return ERROR_CODES[code] or ERROR_CODES.E999
end

local function formatErrorMessage(code, extra)
    local info = getErrorCodeInfo(code)
    local msg = "[" .. code .. "] " .. info.msg
    if extra then
        msg = msg .. "\n  附加信息: " .. extra
    end
    local detail = info.detail:gsub("{layerName}", extra or "")
    msg = msg .. "\n  解决方案: " .. detail
    return msg
end

local function showError(code, extra)
    local msg = formatErrorMessage(code, extra)
    app.alert({ title = SCRIPT_NAME .. " v" .. SCRIPT_VERSION .. " — 错误", text = msg, buttons = "OK" })
end

local function getLogFilePath()
    local configPath = app.fs.userConfigPath
    if configPath and configPath ~= "" then
        return app.fs.joinPath(configPath, ERROR_LOG_FILE)
    end
    return app.fs.joinPath(app.fs.desktopPath, ERROR_LOG_FILE)
end

local function logError(code, extra)
    local msg = formatErrorMessage(code, extra)
    local timestamp = os.date()
    local logEntry = "[" .. timestamp .. "] " .. msg .. "\n---\n"
    local ok, err = pcall(function()
        local filePath = getLogFilePath()
        local file = io.open(filePath, "a")
        if file then
            file:write(logEntry)
            file:close()
        end
    end)
end

local CONFIG_FILE = "LayerBatchRename_Config.txt"

local function getConfigFilePath()
    local configPath = app.fs.userConfigPath
    if configPath and configPath ~= "" then
        return app.fs.joinPath(configPath, CONFIG_FILE)
    end
    return app.fs.joinPath(app.fs.desktopPath, CONFIG_FILE)
end

local function loadConfig()
    local cfg = { excludeGroups = false, excludeLayers = false, seqPad = 0, seqReverse = false }
    local ok, err = pcall(function()
        local filePath = getConfigFilePath()
        local file = io.open(filePath, "r")
        if file then
            for line in file:lines() do
                local key, val = line:match("^(%w+)=(%d+)$")
                if key and val then
                    if key == "excludeGroups" then cfg.excludeGroups = (val == "1")
                    elseif key == "excludeLayers" then cfg.excludeLayers = (val == "1")
                    elseif key == "seqPad" then cfg.seqPad = tonumber(val) or 0
                    elseif key == "seqReverse" then cfg.seqReverse = (val == "1")
                    end
                end
            end
            file:close()
        end
    end)
    return cfg
end

local function saveConfig(excludeGroups, excludeLayers, seqPad, seqReverse)
    pcall(function()
        local filePath = getConfigFilePath()
        local file = io.open(filePath, "w")
        if file then
            file:write("excludeGroups=" .. (excludeGroups and "1" or "0") .. "\n")
            file:write("excludeLayers=" .. (excludeLayers and "1" or "0") .. "\n")
            file:write("seqPad=" .. tostring(seqPad or 0) .. "\n")
            file:write("seqReverse=" .. (seqReverse and "1" or "0") .. "\n")
            file:close()
        end
    end)
end

-- ============================================================
-- 图层操作
-- ============================================================

local function buildHierarchyIndex(sprite)
    local indexMap = {}
    local counter = 0
    local function traverse(layers)
        for i = 1, #layers do
            local layer = layers[i]
            counter = counter + 1
            indexMap[layer] = counter
            if layer.isGroup and layer.layers and #layer.layers > 0 then
                traverse(layer.layers)
            end
        end
    end
    traverse(sprite.layers)
    return indexMap
end

local function getLayerTypeTag(layer)
    if layer.isBackground then return "[背景]" end
    if layer.isReference then return "[参考]" end
    if layer.isTilemap then return "[瓦片]" end
    if layer.isGroup then return "[组]" end
    return "[图]"
end

local function isLayerEditable(layer)
    local current = layer
    while current do
        if not current.isEditable then return false end
        local parent = current.parent
        if parent == nil then break end
        if parent == current.sprite then break end
        current = parent
    end
    return true
end

local function getSelectedLayers(sprite)
    local range = app.range
    if range.sprite ~= sprite then
        if app.layer then return { app.layer } end
        return {}
    end
    local layers = range.layers
    if layers == nil or #layers == 0 then
        if app.layer then return { app.layer } end
        return {}
    end
    return layers
end

local function buildLayerData(sprite)
    local selectedLayers = getSelectedLayers(sprite)
    local hierarchyIndex = buildHierarchyIndex(sprite)

    local layerData = {}
    for _, layer in ipairs(selectedLayers) do
        table.insert(layerData, {
            layer = layer,
            name = layer.name,
            isGroup = layer.isGroup,
            isReference = layer.isReference or false,
            isTilemap = layer.isTilemap or false,
            isBackground = layer.isBackground or false,
            isEditable = isLayerEditable(layer),
            hierarchyIndex = hierarchyIndex[layer] or 0,
            variables = {},
            newName = nil,
        })
    end

    table.sort(layerData, function(a, b)
        return a.hierarchyIndex > b.hierarchyIndex
    end)

    return layerData
end

local function expandLayerDataWithChildren(baseLayerData, sprite)
    local hierarchyIndex = buildHierarchyIndex(sprite)
    local seen = {}
    local result = {}

    for _, ld in ipairs(baseLayerData) do
        if not seen[ld.layer] then
            seen[ld.layer] = true
            table.insert(result, ld)
        end

        if ld.isGroup and ld.layer.layers then
            local function addChildren(layers)
                for _, child in ipairs(layers) do
                    if not seen[child] then
                        seen[child] = true
                        table.insert(result, {
                            layer = child,
                            name = child.name,
                            isGroup = child.isGroup,
                            isReference = child.isReference or false,
                            isTilemap = child.isTilemap or false,
                            isBackground = child.isBackground or false,
                            isEditable = isLayerEditable(child),
                            hierarchyIndex = hierarchyIndex[child] or 0,
                            variables = {},
                            newName = nil,
                        })
                        if child.isGroup and child.layers and #child.layers > 0 then
                            addChildren(child.layers)
                        end
                    end
                end
            end
            addChildren(ld.layer.layers)
        end
    end

    table.sort(result, function(a, b)
        return a.hierarchyIndex > b.hierarchyIndex
    end)

    return result
end

-- ============================================================
-- 表达式算法
-- ============================================================

local function commonPrefix(strings)
    if #strings == 0 then return "" end
    local prefix = strings[1]
    for i = 2, #strings do
        while true do
            if #prefix == 0 then return "" end
            if strings[i]:sub(1, #prefix) == prefix then break end
            prefix = prefix:sub(1, #prefix - 1)
        end
    end
    return prefix
end

local function commonSuffix(strings)
    if #strings == 0 then return "" end
    local suffix = strings[1]
    for i = 2, #strings do
        while #suffix > 0 do
            local sLen = #suffix
            local strLen = #strings[i]
            if strLen >= sLen and strings[i]:sub(strLen - sLen + 1) == suffix then
                break
            end
            suffix = suffix:sub(2)
        end
        if #suffix == 0 then return "" end
    end
    return suffix
end

local function findLCS(strings)
    if #strings == 0 then return "" end
    local shortest = strings[1]
    for i = 2, #strings do
        if #strings[i] < #shortest then shortest = strings[i] end
    end
    if #shortest == 0 then return "" end

    local best = ""
    for start = 1, #shortest do
        for endPos = #shortest, start + #best, -1 do
            local sub = shortest:sub(start, endPos)
            if #sub <= #best then break end
            local found = true
            for i = 1, #strings do
                if not strings[i]:find(sub, 1, true) then
                    found = false
                    break
                end
            end
            if found then
                best = sub
                break
            end
        end
    end
    return best
end

local function buildPatternRecursive(strings, nextVar)
    local allSame = true
    for i = 2, #strings do
        if strings[i] ~= strings[1] then allSame = false; break end
    end
    if allSame then return { expression = escapeLiteralPH(strings[1]), varCount = nextVar - 1 } end

    local allEmpty = true
    for i = 1, #strings do
        if strings[i] ~= "" then allEmpty = false; break end
    end
    if allEmpty then return { expression = "", varCount = nextVar - 1 } end

    local prefix = commonPrefix(strings)

    local remaining = {}
    for i = 1, #strings do
        table.insert(remaining, strings[i]:sub(#prefix + 1))
    end
    local suffix = commonSuffix(remaining)

    local middle = {}
    for i = 1, #strings do
        local s = strings[i]
        local midEnd = #s - #suffix
        table.insert(middle, s:sub(#prefix + 1, midEnd))
    end

    local allMiddleSame = true
    for i = 2, #middle do
        if middle[i] ~= middle[1] then allMiddleSame = false; break end
    end

    if prefix == "" and suffix == "" and not allMiddleSame then
        local lcs = findLCS(strings)
        if lcs ~= "" then
            local parts = {}
            for i = 1, #strings do
                local startIdx, endIdx = strings[i]:find(lcs, 1, true)
                table.insert(parts, {
                    before = strings[i]:sub(1, startIdx - 1),
                    after = strings[i]:sub(endIdx + 1),
                })
            end

            local expression = ""
            local varCount = nextVar - 1

            local hasBefore = false
            for i = 1, #parts do
                if parts[i].before ~= "" then hasBefore = true; break end
            end
            if hasBefore then
                local beforeStrings = {}
                for i = 1, #parts do table.insert(beforeStrings, parts[i].before) end
                local beforeResult = buildPatternRecursive(beforeStrings, nextVar)
                if beforeResult.error then return beforeResult end
                expression = expression .. beforeResult.expression
                varCount = beforeResult.varCount
                nextVar = varCount + 1
            end

            expression = expression .. escapeLiteralPH(lcs)

            local hasAfter = false
            for i = 1, #parts do
                if parts[i].after ~= "" then hasAfter = true; break end
            end
            if hasAfter then
                local afterStrings = {}
                for i = 1, #parts do table.insert(afterStrings, parts[i].after) end
                local afterResult = buildPatternRecursive(afterStrings, nextVar)
                if afterResult.error then return afterResult end
                expression = expression .. afterResult.expression
                varCount = afterResult.varCount
            end

            return { expression = expression, varCount = varCount }
        else
            local vc = posToVarChar(nextVar)
            if not vc then return { expression = "", varCount = nextVar, error = true } end
            return { expression = PH .. vc, varCount = nextVar }
        end
    end

    local expression = escapeLiteralPH(prefix)
    local varCount = nextVar - 1

    if not allMiddleSame then
        local middleResult = buildPatternRecursive(middle, nextVar)
        if middleResult.error then return middleResult end
        expression = expression .. middleResult.expression
        varCount = middleResult.varCount
    elseif #middle > 0 and middle[1] ~= "" then
        expression = expression .. escapeLiteralPH(middle[1])
    end

    expression = expression .. escapeLiteralPH(suffix)

    return { expression = expression, varCount = varCount }
end

local function renumberExpression(expr)
    local reserved = {}
    local i = 1
    while i <= #expr do
        if expr:sub(i, i) == PH and i + 1 <= #expr and expr:sub(i + 1, i + 1) == PH then
            if i + 2 <= #expr then
                local ch = expr:sub(i + 2, i + 2)
                if isVarChar(ch) then
                    reserved[varCharToPos(ch)] = true
                end
            end
            i = i + 3
        elseif expr:sub(i, i) == PH and i + 1 <= #expr then
            i = i + 2
        else
            i = i + 1
        end
    end

    local hasReserved = false
    for _ in pairs(reserved) do hasReserved = true; break end
    if not hasReserved then return expr end

    local placeholders = {}
    i = 1
    while i <= #expr do
        if expr:sub(i, i) == PH and i + 1 <= #expr then
            if expr:sub(i + 1, i + 1) == PH then
                i = i + 3
            else
                local ch = expr:sub(i + 1, i + 1)
                if isVarChar(ch) then
                    table.insert(placeholders, { startPos = i, varPos = varCharToPos(ch) })
                end
                i = i + 2
            end
        else
            i = i + 1
        end
    end

    if #placeholders == 0 then return expr end

    local nextAvailable = 1
    local renumberMap = {}
    for _, ph in ipairs(placeholders) do
        while reserved[nextAvailable] do
            nextAvailable = nextAvailable + 1
        end
        if nextAvailable > MAX_VARS then return nil end
        renumberMap[ph.varPos] = nextAvailable
        nextAvailable = nextAvailable + 1
    end

    local result = ""
    i = 1
    while i <= #expr do
        if expr:sub(i, i) == PH and i + 1 <= #expr then
            if expr:sub(i + 1, i + 1) == PH then
                result = result .. PH .. PH
                i = i + 2
                if i <= #expr then
                    result = result .. expr:sub(i, i)
                    i = i + 1
                end
            else
                local ch = expr:sub(i + 1, i + 1)
                if isVarChar(ch) then
                    local oldPos = varCharToPos(ch)
                    local newPos = renumberMap[oldPos]
                    if newPos then
                        local newChar = posToVarChar(newPos)
                        result = result .. PH .. (newChar or ch)
                    else
                        result = result .. PH .. ch
                    end
                else
                    result = result .. PH .. ch
                end
                i = i + 2
            end
        else
            result = result .. expr:sub(i, i)
            i = i + 1
        end
    end

    return result
end

local function analyzePattern(names)
    if #names == 0 then return { expression = "", varCount = 0 } end
    if #names == 1 then return { expression = escapeLiteralPH(names[1]), varCount = 0 } end

    local result = buildPatternRecursive(names, 1)
    if result.error then
        return { expression = escapeLiteralPH(names[1]), varCount = 0, error = true }
    end

    local renumbered = renumberExpression(result.expression)
    if renumbered == nil then
        return { expression = escapeLiteralPH(names[1]), varCount = 0, error = true }
    end

    return { expression = renumbered, varCount = result.varCount }
end

-- ============================================================
-- 表达式求值
-- ============================================================

local function expressionToPattern(expr)
    local pattern = "^"
    local captureMap = {}
    local i = 1
    while i <= #expr do
        local c = expr:sub(i, i)
        if c == PH then
            if i + 1 <= #expr then
                local nxt = expr:sub(i + 1, i + 1)
                if nxt == PH then
                    pattern = pattern .. escapeMagicChar(PH)
                    i = i + 2
                elseif nxt == "d" then
                    pattern = pattern .. "(%d+)"
                    table.insert(captureMap, "d")
                    i = i + 2
                elseif isVarChar(nxt) then
                    pattern = pattern .. "(.-)"
                    table.insert(captureMap, varCharToPos(nxt))
                    i = i + 2
                else
                    pattern = pattern .. escapeMagicChar(PH) .. escapeMagicChar(nxt)
                    i = i + 2
                end
            else
                pattern = pattern .. escapeMagicChar(PH)
                i = i + 1
            end
        else
            pattern = pattern .. escapeMagicChar(c)
            i = i + 1
        end
    end
    pattern = pattern .. "$"
    return pattern, captureMap
end

local function extractVariables(name, expr)
    local pattern, captureMap = expressionToPattern(expr)
    local numCaptures = #captureMap

    if numCaptures == 0 then
        if name:match(pattern) then return {} end
        return nil
    end

    local captures = { name:match(pattern) }
    if captures == nil or #captures == 0 then return nil end
    if #captures ~= numCaptures then return nil end

    local varMap = {}
    for i = 1, #captures do
        local varPos = captureMap[i]
        if varPos ~= "d" then
            varMap[varPos] = captures[i]
        end
    end

    return varMap
end

local function generateNewName(newExpr, varMap, seqNum, seqPad)
    local result = ""
    local i = 1
    while i <= #newExpr do
        local c = newExpr:sub(i, i)
        if c == PH then
            if i + 1 <= #newExpr then
                local nxt = newExpr:sub(i + 1, i + 1)
                if nxt == PH then
                    result = result .. PH
                    i = i + 2
                elseif nxt == "d" then
                    result = result .. padNumber(seqNum, seqPad)
                    i = i + 2
                elseif isVarChar(nxt) then
                    local pos = varCharToPos(nxt)
                    if pos >= 1 and varMap[pos] then
                        result = result .. varMap[pos]
                    end
                    i = i + 2
                else
                    result = result .. PH .. nxt
                    i = i + 2
                end
            else
                result = result .. PH
                i = i + 1
            end
        else
            result = result .. c
            i = i + 1
        end
    end
    return result
end

-- ============================================================
-- Canvas 绘制
-- ============================================================

local function calcCanvasHeight(layerCount)
    local contentHeight = HEADER_HEIGHT + layerCount * ROW_HEIGHT
    return math.min(contentHeight, CANVAS_MAX_HEIGHT)
end

local function paintCanvas(gc, layerData, scrollOffset, selectedRow, excludeGroups, excludeLayers)
    local cw = gc.width
    local ch = gc.height
    local n = #layerData
    local contentHeight = HEADER_HEIGHT + n * ROW_HEIGHT
    local maxScroll = math.max(0, contentHeight - ch)
    scrollOffset = math.max(0, math.min(scrollOffset, maxScroll))

    local bgColor = Color { r = 46, g = 48, b = 52 }
    local headerBgColor = Color { r = 56, g = 58, b = 64 }
    local textColor = Color { r = 210, g = 210, b = 210 }
    local selectedBgColor = Color { r = 55, g = 75, b = 110 }
    local errorTextColor = Color { r = 240, g = 90, b = 90 }
    local separatorColor = Color { r = 80, g = 82, b = 88 }
    local headerTextColor = Color { r = 180, g = 180, b = 190 }
    local dimTextColor = Color { r = 110, g = 112, b = 116 }

    gc.color = bgColor
    gc:fillRect(Rectangle(0, 0, cw, ch))

    gc.color = headerBgColor
    gc:fillRect(Rectangle(0, 0, cw, HEADER_HEIGHT))

    gc.color = headerTextColor
    gc:fillText("原始图层名", TEXT_PADDING_X, TEXT_PADDING_Y)
    gc:fillText("新图层名", COL_WIDTH + COL_GAP + TEXT_PADDING_X, TEXT_PADDING_Y)

    gc.color = separatorColor
    gc:fillRect(Rectangle(0, HEADER_HEIGHT - 1, cw, 1))
    gc:fillRect(Rectangle(COL_WIDTH, 0, COL_GAP, ch))

    local visibleTop = HEADER_HEIGHT
    local visibleBottom = ch

    for i = 1, n do
        local y = visibleTop + (i - 1) * ROW_HEIGHT - scrollOffset
        if y + ROW_HEIGHT <= visibleTop then goto continue end
        if y >= visibleBottom then break end

        local ld = layerData[i]
        local tag = getLayerTypeTag(ld.layer)
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)

        if i == selectedRow then
            gc.color = selectedBgColor
            gc:fillRect(Rectangle(0, y, cw, ROW_HEIGHT))
        end

        if isExcluded then
            gc.color = dimTextColor
            gc:fillText(tag .. " " .. ld.name, TEXT_PADDING_X, y + TEXT_PADDING_Y)
            gc.color = dimTextColor
            gc:fillText(tag .. " " .. ld.name, COL_WIDTH + COL_GAP + TEXT_PADDING_X, y + TEXT_PADDING_Y)
        else
            gc.color = textColor
            gc:fillText(tag .. " " .. ld.name, TEXT_PADDING_X, y + TEXT_PADDING_Y)

            if ld.newName == nil then
                gc.color = errorTextColor
                gc:fillText(tag .. " [不匹配]", COL_WIDTH + COL_GAP + TEXT_PADDING_X, y + TEXT_PADDING_Y)
            elseif ld.newName == "" then
                gc.color = errorTextColor
                gc:fillText(tag .. " [空名称]", COL_WIDTH + COL_GAP + TEXT_PADDING_X, y + TEXT_PADDING_Y)
            else
                gc.color = textColor
                gc:fillText(tag .. " " .. ld.newName, COL_WIDTH + COL_GAP + TEXT_PADDING_X, y + TEXT_PADDING_Y)
            end
        end

        ::continue::
    end

    if contentHeight > ch then
        local trackX = cw - SCROLLBAR_WIDTH
        local trackY = HEADER_HEIGHT
        local trackH = ch - HEADER_HEIGHT

        gc.color = Color { r = 36, g = 38, b = 42 }
        gc:fillRect(Rectangle(trackX, trackY, SCROLLBAR_WIDTH, trackH))

        local thumbRatio = trackH / contentHeight
        local thumbH = math.max(SCROLLBAR_MIN_THUMB, math.floor(thumbRatio * trackH))
        local thumbY = trackY + math.floor((scrollOffset / maxScroll) * (trackH - thumbH))

        gc.color = Color { r = 90, g = 92, b = 98 }
        gc:fillRect(Rectangle(trackX + 1, thumbY, SCROLLBAR_WIDTH - 2, thumbH))
    end
end

-- ============================================================
-- 业务逻辑
-- ============================================================

local function updatePreview(dlg, state)
    local data = dlg.data
    local origExpr = data.origExpr or ""
    local newExpr = data.newExpr or ""
    local startVal = tonumber(data.seqStart) or 1
    local stepVal = tonumber(data.seqStep) or 1
    local padVal = tonumber(data.seqPad) or 0
    local seqReverse = data.seqReverse or false
    local excludeGroups = data.excludeGroups or false
    local excludeLayers = data.excludeLayers or false

    local activeCount = 0
    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then activeCount = activeCount + 1 end
    end

    local n = #state.layerData
    local activeIdx = 0
    for i = 1, n do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)

        if isExcluded then
            ld.newName = ld.name
            ld.variables = {}
        else
            activeIdx = activeIdx + 1
            local varMap = extractVariables(ld.name, origExpr)
            local seqNum
            if seqReverse then
                seqNum = startVal + (activeIdx - 1) * stepVal
            else
                seqNum = startVal + (activeCount - activeIdx) * stepVal
            end

            if varMap == nil then
                ld.newName = nil
                ld.variables = {}
            else
                ld.variables = varMap
                ld.newName = generateNewName(newExpr, varMap, seqNum, padVal)
            end
        end
    end
end

local function doValidate(state, excludeGroups, excludeLayers)
    local hasMismatch = false
    local hasEmpty = false

    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then
            if ld.newName == nil then
                hasMismatch = true
            elseif ld.newName == "" then
                hasEmpty = true
            end
        end
    end

    if hasMismatch then
        app.alert({
            title = SCRIPT_NAME .. " — 表达式不匹配",
            text = "原始表达式无法匹配部分图层名，请检查表达式。\n不匹配的图层在新图层名列表中显示为 [不匹配]。",
            buttons = "OK",
        })
        return false
    end

    if hasEmpty then
        app.alert({
            title = SCRIPT_NAME .. " — 名称为空",
            text = "表达式生成了空名称，请修改新表达式。\n空名称的图层在新图层名列表中显示为 [空名称]。",
            buttons = "OK",
        })
        return false
    end

    return true
end

local function doApply(dlg, state)
    local data = dlg.data
    local startVal = tonumber(data.seqStart)
    local stepVal = tonumber(data.seqStep)
    local padVal = tonumber(data.seqPad)
    local excludeGroups = data.excludeGroups or false
    local excludeLayers = data.excludeLayers or false

    local allExcluded = true
    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then allExcluded = false; break end
    end
    if allExcluded then
        app.alert({ title = SCRIPT_NAME, text = "所有图层均被排除，无可重命名项。", buttons = "OK" })
        return "allExcluded"
    end

    if startVal == nil or stepVal == nil then
        app.alert({ title = SCRIPT_NAME .. " — 参数错误", text = "序号起始和步长必须为整数。", buttons = "OK" })
        return false
    end
    if padVal == nil or padVal < 0 then
        app.alert({ title = SCRIPT_NAME .. " — 参数错误", text = "位数必须为非负整数。", buttons = "OK" })
        return false
    end

    if not doValidate(state, excludeGroups, excludeLayers) then return false end

    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then
            if ld.newName ~= nil and ld.newName ~= "" and ld.newName ~= ld.name then
                if not ld.isEditable then
                    logError("E201", ld.name)
                    showError("E201", ld.name)
                    return false
                end
            end
        end
    end

    local hasChange = false
    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then
            if ld.newName ~= nil and ld.newName ~= "" and ld.newName ~= ld.name then
                hasChange = true
                break
            end
        end
    end
    if not hasChange then return true end

    local nameSet = {}
    local duplicates = {}
    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then
            local nm = ld.newName
            if nm ~= nil and nm ~= "" then
                if nameSet[nm] then
                    table.insert(duplicates, nm)
                end
                nameSet[nm] = true
            end
        end
    end

    local ok, err = pcall(function()
        app.transaction(SCRIPT_NAME, function()
            for i = 1, #state.layerData do
                local ld = state.layerData[i]
                local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
                if not isExcluded then
                    if ld.newName ~= nil and ld.newName ~= "" and ld.newName ~= ld.name then
                        ld.layer.name = ld.newName
                    end
                end
            end
        end)
    end)

    if not ok then
        logError("E999", "事务执行失败: " .. tostring(err))
        showError("E999", "事务执行失败: " .. tostring(err))
        return false
    end

    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then
            if ld.newName ~= nil and ld.newName ~= "" and ld.newName ~= ld.name then
                ld.name = ld.newName
            end
        end
    end

    if #duplicates > 0 then
        local uniqueDups = {}
        local seenDups = {}
        for _, dup in ipairs(duplicates) do
            if not seenDups[dup] then
                seenDups[dup] = true
                table.insert(uniqueDups, dup)
            end
        end
        app.alert({
            title = SCRIPT_NAME .. " — 同名提示",
            text = "重命名已完成，以下新图层名存在重复：\n" .. table.concat(uniqueDups, "\n"),
            buttons = "OK",
        })
    end

    return true
end

local function refreshAfterApply(dlg, state)
    local data = dlg.data
    local excludeGroups = data.excludeGroups or false
    local excludeLayers = data.excludeLayers or false

    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        for j = 1, #state.baseLayerData do
            if state.baseLayerData[j].layer == ld.layer then
                state.baseLayerData[j].name = ld.name
                break
            end
        end
    end

    local names = {}
    for i = 1, #state.layerData do
        local ld = state.layerData[i]
        local isExcluded = (excludeGroups and ld.isGroup) or (excludeLayers and not ld.isGroup)
        if not isExcluded then
            table.insert(names, ld.name)
        end
    end

    local pattern = analyzePattern(names)

    local savedBounds = dlg.bounds
    state.ignoreChanges = true
    dlg:modify({ id = "origExpr", text = pattern.expression })
    dlg:modify({ id = "newExpr", text = pattern.expression })
    state.ignoreChanges = false
    dlg.bounds = Rectangle(savedBounds.x, savedBounds.y, savedBounds.width, savedBounds.height)

    updatePreview(dlg, state)
end

-- ============================================================
-- 界面构建
-- ============================================================

local function createDialog(layerData)
    local cfg = loadConfig()
    local sprite = app.sprite

    local state = {
        baseLayerData = layerData,
        layerData = layerData,
        scrollOffset = 0,
        selectedRow = 1,
        ignoreChanges = false,
        canvasHeight = 0,
        hasAutoResized = false,
    }

    local dlg

    local function getActiveNames()
        local names = {}
        for i = 1, #state.layerData do
            local ld = state.layerData[i]
            local isExcluded = (cfg.excludeGroups and ld.isGroup) or (cfg.excludeLayers and not ld.isGroup)
            if not isExcluded then
                table.insert(names, ld.name)
            end
        end
        return names
    end

    local function refreshExpression(deltaHeight)
        local savedBounds = dlg.bounds
        local activeNames = getActiveNames()
        local pat = analyzePattern(activeNames)
        if pat.error then
            pat = { expression = "", varCount = 0 }
        end
        state.ignoreChanges = true
        dlg:modify({ id = "origExpr", text = pat.expression })
        dlg:modify({ id = "newExpr", text = pat.expression })
        state.ignoreChanges = false
        local newHeight = savedBounds.height + (deltaHeight or 0)
        dlg.bounds = Rectangle(savedBounds.x, savedBounds.y, savedBounds.width, newHeight)
        updatePreview(dlg, state)
        dlg:repaint()
    end

    local function onGetChildrenChanged()
        if cfg.getChildren then
            state.layerData = expandLayerDataWithChildren(state.baseLayerData, sprite)
            local deltaHeight = 0
            if not state.hasAutoResized then
                local newCanvasHeight = calcCanvasHeight(#state.layerData)
                local oldCanvasHeight = calcCanvasHeight(#state.baseLayerData)
                deltaHeight = newCanvasHeight - oldCanvasHeight
                if deltaHeight > 0 then
                    state.hasAutoResized = true
                else
                    deltaHeight = 0
                end
            end
            state.selectedRow = 1
            state.scrollOffset = 0
            refreshExpression(deltaHeight)
        else
            state.layerData = state.baseLayerData
            state.selectedRow = 1
            state.scrollOffset = 0
            refreshExpression()
        end
    end

    local names = getActiveNames()
    local pattern = analyzePattern(names)
    if pattern.error then
        app.alert({
            title = SCRIPT_NAME .. " — 变量过多",
            text = "图层名差异过大，变量数量超过 " .. MAX_VARS .. " 个。\n请减少选中图层数量或手动输入表达式。",
            buttons = "OK",
        })
        return nil
    end

    local canvasHeight = calcCanvasHeight(#layerData)

    dlg = Dialog({ title = SCRIPT_NAME .. " v" .. SCRIPT_VERSION })

    dlg:canvas({
        id = "preview",
        width = CANVAS_WIDTH,
        height = canvasHeight,
        onpaint = function(ev)
            state.canvasHeight = ev.context.height
            local ok, err = pcall(function()
                paintCanvas(ev.context, state.layerData, state.scrollOffset, state.selectedRow, cfg.excludeGroups, cfg.excludeLayers)
            end)
            if not ok then
                logError("E999", "Canvas 绘制错误: " .. tostring(err))
            end
        end,
        onmousedown = function(ev)
            local y = ev.y
            if y < HEADER_HEIGHT then return end
            local row = math.floor((y - HEADER_HEIGHT + state.scrollOffset) / ROW_HEIGHT) + 1
            if row >= 1 and row <= #state.layerData then
                state.selectedRow = row
                dlg:repaint()
            end
        end,
        onwheel = function(ev)
            local delta = 0
            if type(ev.deltaY) == "number" then
                delta = ev.deltaY
            elseif type(ev.wheelDelta) == "number" then
                delta = ev.wheelDelta
            end
            if delta == 0 then return end

            local direction = delta > 0 and 1 or -1
            state.scrollOffset = state.scrollOffset + direction * ROW_HEIGHT * 3

            local contentHeight = HEADER_HEIGHT + #state.layerData * ROW_HEIGHT
            local maxScroll = math.max(0, contentHeight - state.canvasHeight)
            state.scrollOffset = math.max(0, math.min(state.scrollOffset, maxScroll))
            dlg:repaint()
        end,
    })

    dlg:newrow()
    dlg:check({ id = "excludeGroups", text = "排除图层组", selected = cfg.excludeGroups, onclick = function()
        cfg.excludeGroups = dlg.data.excludeGroups
        refreshExpression()
    end })
    dlg:check({ id = "excludeLayers", text = "排除图层", selected = cfg.excludeLayers, onclick = function()
        cfg.excludeLayers = dlg.data.excludeLayers
        refreshExpression()
    end })
    dlg:check({ id = "getChildren", text = "获取子对象", selected = false, onclick = function()
        cfg.getChildren = dlg.data.getChildren
        onGetChildrenChanged()
    end })

    dlg:newrow()
    dlg:entry({
        id = "origExpr",
        label = "原始表达式:",
        text = pattern.expression,
        focus = false,
        onchange = function()
            if state.ignoreChanges then return end
            updatePreview(dlg, state)
            dlg:repaint()
        end,
    })

    dlg:newrow()
    dlg:button({ id = "resetExpr", text = "重置", hexpand = false, onclick = function()
        refreshExpression()
    end })

    dlg:newrow()
    dlg:entry({
        id = "newExpr",
        label = "新表达式:",
        text = pattern.expression,
        focus = true,
        onchange = function()
            if state.ignoreChanges then return end
            updatePreview(dlg, state)
            dlg:repaint()
        end,
    })

    dlg:newrow()
    dlg:entry({ id = "seqStart", label = "序号起始:", text = "1", onchange = function()
        if state.ignoreChanges then return end
        updatePreview(dlg, state)
        dlg:repaint()
    end })
    dlg:entry({ id = "seqStep", label = "步长:", text = "1", onchange = function()
        if state.ignoreChanges then return end
        updatePreview(dlg, state)
        dlg:repaint()
    end })
    dlg:entry({ id = "seqPad", label = "位数:", text = tostring(cfg.seqPad), onchange = function()
        if state.ignoreChanges then return end
        updatePreview(dlg, state)
        dlg:repaint()
    end })

    dlg:newrow()
    dlg:check({ id = "seqReverse", text = "倒序", selected = cfg.seqReverse, onclick = function()
        if state.ignoreChanges then return end
        updatePreview(dlg, state)
        dlg:repaint()
    end })

    dlg:newrow()
    dlg:separator({ text = "说明" })

    dlg:label({ text = "#d = 序号（位数见输入框）  ## = 井号" })
    dlg:label({ text = "#1~#9 = 变量（匹配任意文本含空串，新表达式引用原文本）" })
    dlg:label({ text = "变量超9个: #0 #a~#z #A~#Z  序号从最下方图层递增" })

    local function getCurrentSeqPad()
        return tonumber(dlg.data.seqPad) or 0
    end

    local function getCurrentSeqReverse()
        return dlg.data.seqReverse or false
    end

    dlg:newrow()
    dlg:button({ id = "githubBtn", text = "GitHub", hexpand = false, onclick = function()
        app.clipboard.text = "https://github.com/TheMorningCat/Aseprite-Layer-Batch-Rename"
        app.alert({ title = "GitHub", text = "链接已复制到剪贴板", buttons = "OK" })
    end })

    dlg:newrow()
    dlg:button({ id = "okBtn", text = "确定", focus = true, hexpand = false, onclick = function()
        local ok, err = pcall(function()
            local result = doApply(dlg, state)
            if result == "allExcluded" then
                return
            end
            if result then
                saveConfig(cfg.excludeGroups, cfg.excludeLayers, getCurrentSeqPad(), getCurrentSeqReverse())
                dlg:close()
            end
        end)
        if not ok then
            logError("E999", "确定操作出现错误: " .. tostring(err))
            showError("E999", "确定操作出现错误: " .. tostring(err))
        end
    end })
    dlg:button({ id = "applyBtn", text = "应用", hexpand = false, onclick = function()
        local ok, err = pcall(function()
            local result = doApply(dlg, state)
            if result == "allExcluded" then
                dlg:close()
                return
            end
            if result then
                saveConfig(cfg.excludeGroups, cfg.excludeLayers, getCurrentSeqPad(), getCurrentSeqReverse())
                refreshAfterApply(dlg, state)
                dlg:repaint()
            end
        end)
        if not ok then
            logError("E999", "应用操作出现错误: " .. tostring(err))
            showError("E999", "应用操作出现错误: " .. tostring(err))
        end
    end })
    dlg:button({ id = "cancelBtn", text = "取消", hexpand = false, onclick = function()
        saveConfig(cfg.excludeGroups, cfg.excludeLayers, getCurrentSeqPad(), getCurrentSeqReverse())
        dlg:close()
    end })

    updatePreview(dlg, state)

    return dlg
end

-- ============================================================
-- 主入口
-- ============================================================

local function main()
    local sprite = app.sprite
    if not sprite then
        logError("E001")
        showError("E001")
        return
    end

    local layerData = buildLayerData(sprite)
    if #layerData == 0 then
        logError("E002")
        showError("E002")
        return
    end

    local dlg = createDialog(layerData)
    if not dlg then return end

    dlg:show({ wait = false })
end

local ok, err = pcall(main)
if not ok then
    local errMsg = tostring(err)
    logError("E999", errMsg)
    showError("E999", errMsg)
end
