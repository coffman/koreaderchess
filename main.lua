local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geometry = require("ui/geometry")
local Logger = require("logger")
local DataStorage = require("datastorage")
local json = require("json")

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TitleBarWidget = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ButtonWidget    = require("ui/widget/button")
local infoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup") 
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextWidget = require("ui/widget/textwidget")
local InputText = require("ui/widget/inputtext")
local PathChooser = require("ui/widget/pathchooser")
local LeftContainer = require("ui/widget/container/leftcontainer")


local Chess = require("chess")
local ChessBoard = require("board")
local Timer = require("timer")
local Uci = require("uci")
local SettingsWidget = require("settingswidget")
local _ = require("gettext")

-- RUTA ABSOLUTA

-- local PLUGIN_PATH = "/mnt/onboard/.adds/koreader/plugins/kochess.koplugin/"
local function getPluginPath()
    -- ruta real del fichero main.lua
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "") -- quitar @ de luajit
    -- convertir .../kochess.koplugin/main.lua -> .../kochess.koplugin/
    local path = src:match("^(.*[/\\])main%.lua$")
    Logger.info("KOCHESS: Plugin path detected: " .. tostring(path))
    return path
end

local PLUGIN_PATH = getPluginPath()

local ENGINES_DIR = PLUGIN_PATH .. "engines/"

local function fileExists(path)
    local ok = lfs.attributes(path, "mode")
    return ok == "file"
end

local function chmodX(path)
    -- En Kindle/Kobo suele hacer falta; en PC normalmente no molesta
    os.execute('chmod +x "' .. path .. '"')
end

local function getArch()
    -- "uname -m" suele estar disponible en Kobo/Kindle/PC (Linux)
    local p = io.popen("uname -m 2>/dev/null")
    if not p then return "unknown" end
    local out = p:read("*a") or ""
    p:close()
    out = out:gsub("%s+", "")
    Logger.info("KOCHESS: Detected architecture: " .. out)
    return (#out > 0) and out or "unknown"
end

local function getEnginePath()
    local arch = getArch()

    -- 1) Preferencia por dispositivo KOReader (más específico)
    local candidates = {} 

    -- KOBO: armv7l
    if Device:isKobo() then
        candidates = {
            ENGINES_DIR .. "stockfish",
        }
    elseif Device:isKindle() then
        candidates = {
            ENGINES_DIR .. "stockfish_kindle",
            ENGINES_DIR .. "stockfish_linux_armv7",
            ENGINES_DIR .. "stockfish_linux_aarch64",
        }
    else
        -- PC / entorno de pruebas
        candidates = {
            ENGINES_DIR .. "stockfish_pc",
        }
    end

    -- 2) Fallback por arquitectura (por si el "tipo de Device" no cuadra)
    if arch == "x86_64" then
        candidates[#candidates+1] = ENGINES_DIR .. "stockfish_pc"
    elseif arch:match("^arm") then
        candidates[#candidates+1] = ENGINES_DIR .. "stockfish"
    elseif arch == "aarch64" then
        candidates[#candidates+1] = ENGINES_DIR .. "stockfish_linux_aarch64"
    end

        -- 3) Seleccionar el primero que exista
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            chmodX(path)
            return path
        end
    end

    return nil
end

local UCI_ENGINE_PATH = getEnginePath()
-- local UCI_ENGINE_PATH = PLUGIN_PATH .. "engines/stockfish"
local GAMES_PATH = PLUGIN_PATH .. "Games"

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE
local PGN_LOG_FONT = "smallinfofont"
local PGN_LOG_FONT_SIZE = 14
local TOOLBAR_PADDING = 4

local Kochess = FrameContainer:extend{
    name = "kochess_root",
    background = BACKGROUND_COLOR,
    bordersize = 0,
    padding = 0,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    notation_font = PGN_LOG_FONT,
    notation_size = PGN_LOG_FONT_SIZE,
    game = nil, timer = nil, engine = nil, board = nil,
    pgn_log = nil, status_bar = nil, running = false,
}

function Kochess:init()
    self.dimensions = Geometry:new{ w = self.full_width, h = self.full_height }
    self.covers_fullscreen = true 
    Dispatcher:registerAction("kochess", {
        category = "none", event = "KochessStart", title = _("Chess Game"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    self:installIconsIfNeeded()
end

local function mkdir_p(path)
    local sep = package.config:sub(1,1)
    local cur = ""
    for part in path:gmatch("[^" .. sep .. "]+") do
        cur = (cur == "") and part or (cur .. sep .. part)
        if lfs.attributes(cur, "mode") ~= "directory" then
            lfs.mkdir(cur)
        end
    end
end

function Kochess:installIconsIfNeeded()
    -- Directorio de datos real de KOReader (PC / Kobo / Kindle)
    local data_dir = DataStorage:getDataDir()
    local dest_dir = data_dir .. "/resources/icons/chess"
    local src_dir  = PLUGIN_PATH .. "icons"

    Logger.info("KOCHESS: Installing icons")
    Logger.info("KOCHESS: data_dir  = " .. tostring(data_dir))
    Logger.info("KOCHESS: src_dir   = " .. tostring(src_dir))
    Logger.info("KOCHESS: dest_dir  = " .. tostring(dest_dir))

    if lfs.attributes(dest_dir, "mode") ~= "directory" then
        -- Asegurar jerarquía hasta .../resources/icons/chess
        mkdir_p(data_dir .. "/resources/icons/chess")
        os.execute('cp -r "' .. src_dir .. '/." "' .. dest_dir .. '"')
    end
end

function Kochess:addToMainMenu(menu_items)
    menu_items.kochess = {
        text = _("Chess Game"), sorting_hint = "tools", callback = function() self:startGame() end, keep_menu_open = false, 
    }
end

function Kochess:startGame()
    self.last_cp = nil
    self.last_mate = nil
    self.eval_turn = nil

    self:initializeGameLogic()
    self:initializeEngine() 
    self:initializeBoard()
    self:loadOpenings()
    self:buildUILayout()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self.board:updateBoard() 
    UIManager:show(self) 
end

-- ==========================================================
-- CARGAMOS LAS APERTURAS
-- ==========================================================
function Kochess:loadOpenings()
    if self.openings then return end  -- cache

    self.openings = {}
    local path = PLUGIN_PATH .. "data/aperturas.json"

    local f = io.open(path, "r")
    if not f then
        Logger.info("KOCHESS: No se pudo abrir aperturas.json")
        return
    end

    local content = f:read("*all")
    f:close()

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        Logger.info("KOCHESS: aperturas.json inválido")
        return
    end

    self.openings = data
    Logger.info("KOCHESS: Aperturas cargadas: " .. tostring(#self.openings))
end

-- ==========================================================
-- ARRANQUE DEL MOTOR (MÉTODO DIRECTO - EL QUE FUNCIONA)
-- ==========================================================
function Kochess:initializeEngine()

    local defaultSkill = 10
    self.last_cp = nil

    if not UCI_ENGINE_PATH then
        Logger.info("KOCHESS: No Stockfish engine binary found in " .. ENGINES_DIR)
        UIManager:show(infoMessage:new{
            text = "Error",
            message = "No se encontró un binario de Stockfish.\nCopia el motor en:\n" .. ENGINES_DIR
        })
        return
    end
    Logger.info("KOCHESS: Arrancando Stockfish ..." .. UCI_ENGINE_PATH)

    os.execute("chmod +x " .. UCI_ENGINE_PATH)

    -- [CORRECCIÓN] Pasamos "stockfish" como argumento.
    -- Antes pasábamos {} (vacío), y eso confunde al proceso en Linux.
    self.engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})

    
    if not self.engine then
        Logger.info("KOCHESS: Fallo al crear proceso.")
        UIManager:show(infoMessage:new{text="Error", message="Motor no arranca."})
        return
    end

    self.engine:on("read", function(data)
        if data then
            local clean = data:gsub("\r", "")
            Logger.info("RAW ENGINE: " .. clean:gsub("\n", " "))

            -- Parseo robusto del último score cp (multipv 1 si viene)
            for line in tostring(data):gmatch("[^\r\n]+") do
                if line:match("^info ") then
                    local mp = tonumber(line:match(" multipv (%d+)")) or 1
                    if mp == 1 then
                        local cp = line:match(" score cp (-?%d+)")
                        local mate = line:match(" score mate (-?%d+)")
                        if mate then
                            local mv = tonumber(mate)
                            if self.eval_turn == Chess.BLACK then mv = -mv end
                            self.last_mate = mv
                            self.last_cp = nil
                            Logger.info("RAW ENGINE: Mate detected: " .. tostring(mv))
                        elseif cp then
                            local cpv = tonumber(cp)
                            if self.eval_turn == Chess.BLACK then cpv = -cpv end
                            self.last_cp = cpv
                            self.last_mate = nil
                        end
                    end
                end
            end
        end
    end)

    self.engine:on("uciok", function()
        Logger.info("KOCHESS: ¡RECIBIDO UCIOK!")
        self:updatePgnLogInitialText()

        -- CONFIGURACIÓN PARA KOBO (RÁPIDA Y LIGERA)
        self.engine.send("setoption name Hash value 8")   -- Mínima memoria
        self.engine.send("setoption name Threads value 1") -- Un solo hilo
        self.engine.send("setoption name Skill Level value " .. defaultSkill)
        self.engine.send("setoption name Move Overhead value 150")
        self.engine.send("setoption name Ponder value false")
        self.engine.send("setoption name Slow Mover value 90")
        self.current_skill = defaultSkill

        self.engine:ucinewgame()
        self.engine.send("isready")
        UIManager:setDirty(self, "ui")
    end)

    self.engine:on("bestmove", function(move_uci)
        self.engine_busy = false

        Logger.info("KOCHESS: Motor mueve -> " .. tostring(move_uci))
        if not self.game.is_human(self.game.turn()) then
            self:uciMove(move_uci)
        end
    end)
    
    -- Damos un respiro y saludamos
    os.execute("sleep 0.2")

    Logger.info("KOCHESS: Enviando 'uci'...")
    self.engine:uci()
end

-- [RESTO DE FUNCIONES LÓGICAS]
function Kochess:initializeGameLogic()
    self.game = Chess:new()
    self.game.reset() 
    self.game.initial_fen = self.game.fen() 
    self.timer = Timer:new({[Chess.WHITE]=1800, [Chess.BLACK]=1800}, {[Chess.WHITE]=0, [Chess.BLACK]=0}, function() self:updateTimerDisplay() end)
    self.running = false 
end

function Kochess:initializeBoard()
    self.board = ChessBoard:new{
        game = self.game, width = self.full_width, height = math.floor(0.7 * self.full_height), 
        moveCallback = function(move) self:onMoveExecuted(move) end,
        onPromotionNeeded = function(f, t, c) self:openPromotionDialog(f, t, c) end,
    }
end

function Kochess:buildUILayout()
    local title_bar = self:createTitleBar()
    local status_bar = self:createStatusBar()
    local board_h = self.board:getSize().h
    local log_h = math.max(100, self.full_height - title_bar:getSize().h - board_h - status_bar:getSize().h)
    local toolbar_width = math.floor(math.min(log_h / 4 + 16, self.full_width / 3))
    
    local eval_h = 22  -- altura de una línea (ajusta si quieres)
    local pgn_w  = self.full_width - toolbar_width

    self.eval_line = TextWidget:new{
        text = "Eval: --",
        face = Font:getFace("smallinfofont", 14),
        halign = "left",
        padding = 0,
        width  = pgn_w,       
    }

    local eval_line_left = LeftContainer:new{
        dimen = Geometry:new{ w = pgn_w, h = eval_h + 5 },
        self.eval_line,
    }
    

    self:updateEvalLine()

    self.pgn_log = self:createPgnLogWidget(_("Welcome!"), pgn_w, log_h - eval_h)

    local pgn_with_eval = VerticalGroup:new{
        width  = pgn_w,
        height = log_h,
        self.pgn_log,
        eval_line_left,   -- 👈 aquí, no pongas self.eval_line directamente
    }

    local toolbar = VerticalGroup:new{
        width = toolbar_width, height = log_h, padding = TOOLBAR_PADDING,
        self:createToolbarButton("chevron.left", toolbar_width-8, 40, function() self:handleUndoMove(false) end),
        self:createToolbarButton("chevron.right", toolbar_width-8, 40, function() self:handleRedoMove(false) end),
        self:createToolbarButton("bookmark", toolbar_width-8, 40, function() UIManager:show(self:openSaveDialog()) end),
        self:createToolbarButton("appbar.filebrowser", toolbar_width-8, 40, function() self:openLoadPgnDialog() end),
    }

    local main_vgroup = VerticalGroup:new{
        align = "center", width = self.full_width, height = self.full_height,
        title_bar, self.board,
        FrameContainer:new{ background = BACKGROUND_COLOR, padding=0, HorizontalGroup:new{ height=log_h, toolbar, pgn_with_eval } },
        status_bar,
    }
    self.status_bar = status_bar 
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), main_vgroup }
end

function Kochess:updatePgnLogInitialText()
    local text = _("Kochess Ready.\nWhite to play.")
    if self.engine and self.engine.state.uciok then text = text .. "\nEngine: " .. (self.engine.state.id_name or "Stockfish") end
    if self.pgn_log then self.pgn_log:setText(text); UIManager:setDirty(self, "ui") end
end

-- ==========================================================
-- DETECTA LAS APERTURAS
-- ==========================================================
function Kochess:detectOpening()
    if not self.openings then return nil end

    -- Intento 1: SAN (lo que necesitas para comparar con "e4 e6")
    local hist = self.game.history and self.game:history() or nil
    if type(hist) ~= "table" or #hist == 0 then
        -- fallback: por si tu API es game.history(...)
        hist = self.game.history and self.game.history() or {}
    end

    local moves = {}
    for i, san in ipairs(hist) do
        if type(san) == "string" and san ~= "" then
            -- normaliza SAN (quita + # ! ? por si acaso)
            san = san:gsub("[+#?!]", "")
            moves[#moves + 1] = san
        end
    end

    local played = table.concat(moves, " ")

    -- Debug útil
    Logger.info("KOCHESS: played SAN = " .. played)

    local best = nil
    for _, o in ipairs(self.openings) do
        if played:find(o.moves, 1, true) == 1 then
            if not best or #o.moves > #best.moves then
                best = o
            end
        end
    end

    return best
end



local function formatEval(self)
    local mate = self.last_mate
    if mate ~= nil then
        local m = tonumber(mate) or 0
        if m == 0 then
            return "eval: # (checkmate)"
        end
        local side  = (m > 0) and "White" or "Black"
        local moves = math.max(1, math.ceil(math.abs(m) / 2))
        return string.format("eval: Mate in %d (%s)", moves, side)
    end

    local cp = self.last_cp
    if cp == nil then
        return "eval: --"
    end

    local v = (tonumber(cp) or 0) / 100.0
    local abs = math.abs(v)

    local tag
    if abs < 0.20 then
        tag = "(roughly equal)"
    elseif abs < 0.50 then
        tag = (v > 0) and "(slight advantage for White)" or "(slight advantage for Black)"
    elseif abs < 1.00 then
        tag = (v > 0) and "(small advantage for White)" or "(small advantage for Black)"
    elseif abs < 2.00 then
        tag = (v > 0) and "(clear advantage for White)" or "(clear advantage for Black)"
    elseif abs < 4.00 then
        tag = (v > 0) and "(winning advantage for White)" or "(winning advantage for Black)"
    else
        tag = (v > 0) and "(decisive advantage for White)" or "(decisive advantage for Black)"
    end

    return string.format("eval: %+.2f %s", v, tag)
end



function Kochess:updateEvalLine()
    Logger.info("KOCHESS: EvalLine -> %s (cp=%s mate=%s)",
    tostring(self.eval_line and "ok" or "nil"),
    tostring(self.last_cp),
    tostring(self.last_mate)
)
    if self.eval_line then
        self.eval_line:setText(formatEval(self))
        UIManager:setDirty(self, "ui")
    end
end

function Kochess:createPgnLogWidget(txt, w, h) return TextBoxWidget:new{ use_xtext=true, text=txt, face=Font:getFace(self.notation_font, self.notation_size), scroll=true, width=w, height=h, dialog=self } end
function Kochess:createToolbarButton(icon, w, h, cb) return ButtonWidget:new{ icon=icon, icon_width=w, icon_height=h, callback=cb } end
function Kochess:handleUndoMove(all) self:stopUCI(); self.timer:stop(); if all then while self.game.undo() do end else self.game.undo() end; self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui"); self.timer:start() end
function Kochess:handleRedoMove(all) self:stopUCI(); self.timer:stop(); if all then while self.game.redo() do end else self.game.redo() end; self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui"); self.timer:start() end

function Kochess:onMoveExecuted(move)
    Logger.info("KOCHESS: Player Move " .. tostring(move.san))
    self.running = true

    -- 1) Actualiza historial/PGN (aquí ya se ha aplicado la jugada al game)
    self:updatePgnLog()

    -- 2) Detecta apertura AHORA (historial ya incluye la jugada del humano o del motor)
    local opening = self:detectOpening()
    Logger.info("KOCHESS: Opening detected: " .. (opening and opening.name or "none"))

    -- 3) Pinta línea (si hay apertura, la mostramos; la eval se añade si existe)
    if self.eval_line then
        local eval_txt = formatEval(self)
        if opening then
            self.eval_line:setText(string.format("%s (%s) · %s", opening.name, opening.eco or "?", eval_txt))
        else
            self.eval_line:setText(eval_txt)
        end
    end

    -- 4) Continúa flujo normal
    self:launchNextMove()
    UIManager:setDirty(self, "ui")
end


function Kochess:launchNextMove()
    self.timer:switchPlayer()
    self:updateTimerDisplay()
    if self.engine and self.engine.state.uciok and not self.game.is_human(self.game.turn()) then self:launchUCI() end
end

function Kochess:uciMove(str)
    local m = self.game.move({from=str:sub(1,2), to=str:sub(3,4), promotion=(#str==5 and str:sub(5,5) or nil)})
    if m then self.board:handleGameMove(m); self:onMoveExecuted(m) end
end

function Kochess:launchUCI()

    local CAP_MS = 20000 -- 20 segundos
    -- Evitar reentradas: si el motor ya está pensando, no relanzar go
    if self.engine_busy then return end
    self.engine_busy = true

    local moves = {}
    for _, m in ipairs(self.game.history({ verbose = true })) do
        moves[#moves + 1] = m.from .. m.to .. (m.promotion or "")
    end
    
    -- Si tu wrapper ya asume startpos, basta con moves=...
    self.engine:position({ moves = table.concat(moves, " ") })

    self.eval_turn = self.game.turn()
    
    self.engine:go({
        wtime = self.timer:getRemainingTime(Chess.WHITE) * 1000,
        btime = self.timer:getRemainingTime(Chess.BLACK) * 1000,
        winc  = self.timer.increment[Chess.WHITE] * 1000,
        binc  = self.timer.increment[Chess.BLACK] * 1000,
        movestogo = 30, -- opcional, ayuda a distribuir tiempo
        movetime = CAP_MS,
    })

end


function Kochess:stopUCI() if self.engine and self.engine.state.uciok then self.engine.send("stop") end end

function Kochess:updatePgnLog()
    local moves = self.game:history()
    local txt = ""
    for i, m in ipairs(moves) do
        if i%2==1 then txt = txt .. " " .. (math.floor(i/2)+1) .. "." end
        txt = txt .. " " .. m
    end
    self.pgn_log:setText(txt)
end

function Kochess:updateTimerDisplay()
    local ind = self.running and ((self.game.turn()==Chess.WHITE and " < ") or " > ") or " || "
    self.status_bar:setTitle(self.timer:formatTime(self.timer:getRemainingTime(Chess.WHITE)) .. ind .. self.timer:formatTime(self.timer:getRemainingTime(Chess.BLACK)))
    UIManager:setDirty(self.status_bar, "ui")
end

function Kochess:updatePlayerDisplay()
    local function lbl(c) return self.game.is_human(c) and "Human" or "Engine" end
    self.status_bar:setSubTitle(lbl(Chess.WHITE) .. " - " .. lbl(Chess.BLACK))
end

function Kochess:resetGame()
    self:stopUCI(); self.game.reset(); self.timer:reset()
    if self.engine then self.engine.send("ucinewgame") end
    self:updateTimerDisplay(); self:updatePlayerDisplay(); self.board:updateBoard(); UIManager:setDirty(self, "ui")
end

function Kochess:createTitleBar()
    return TitleBarWidget:new{ fullscreen=true, title=_("Kochess"), left_icon="home", left_icon_tap_callback=function() self:resetGame() end, close_callback=function() self.timer:stop(); if self.engine then self.engine:stop() end; UIManager:close(self) end }
end

function Kochess:createStatusBar()
    return TitleBarWidget:new{
        fullscreen=true, title="00:00", subtitle="HvH", left_icon="appbar.settings",
        left_icon_tap_callback=function()
            SettingsWidget:new{
                engine=self.engine, timer=self.timer, game=self.game, parent=self,
                onApply=function() 
                    if not self.game.is_human(self.game.turn()) then self:launchUCI() end
                    self.timer:reset(); self:updatePlayerDisplay(); self:updateTimerDisplay()
                end
            }:show()
        end,
        right_icon="check", right_icon_tap_callback=function()
            if self.running then self.timer:stop(); self.running=false else self.running=true; self.timer:start(); if self.engine and not self.game.is_human(self.game.turn()) then self:launchUCI() end end
            self:updateTimerDisplay()
        end
    }
end

function Kochess:openLoadPgnDialog()
    UIManager:show(
        PathChooser:new{
            path = GAMES_PATH,
            title = _("Load PGN File"),
            select_directory = false,
            onConfirm = function(path)
                if not path then return end
                local fh = io.open(path, "r")
                if not fh then
                    UIManager:show(infoMessage:new{
                        text = _("Error"), message = _("Could not open file:\n") .. path,
                    })
                    return
                end
                local pgn_data = fh:read("*a")
                fh:close()

                -- 1. Paramos el motor para no confundirlo
                self:stopUCI()
                self.timer:stop()
                
                -- 2. Reiniciamos el tablero lógico
                self.game.reset() 
                
                -- 3. Cargamos la partida
                self.game.load_pgn(pgn_data)

                -- [CAMBIO] Quitamos el rebobinado (undo) para ver el estado final.
                -- Si prefieres ver el principio, descomenta la siguiente línea:
                -- while self.game.undo() do end
                
                -- 4. Actualizamos todo
                self.board:updateBoard()
                self:updatePgnLog()
                self:updateTimerDisplay()
                self:updatePlayerDisplay()
                
                -- 5. Sincronizamos con Stockfish (Nueva posición)
                if self.engine and self.engine.state.uciok then
                    self.engine.send("ucinewgame")
                    self.engine.send("isready")
                    -- Opcional: Si quieres que el motor analice ya, podrías lanzar launchUCI aquí
                end

                UIManager:setDirty(self, "ui")
                self.timer:start()
            end,
        }
    )
end
-- Función auxiliar para procesar el guardado
function Kochess:handleSaveFile(dialog, filename_input, current_dir)
    filename_input:onCloseKeyboard() -- Cerrar teclado
    local dir = current_dir
    local file = filename_input:getText():gsub("\n$", "") -- Limpiar nombre
    
    -- Añadir extensión .pgn si falta
    if not file:lower():match("%.pgn$") then
        file = file .. ".pgn"
    end

    local sep = package.config:sub(1, 1)
    local fullpath = dir .. sep .. file
    local pgn_data = self.game.pgn() -- Obtener PGN del juego actual

    local fh, err = io.open(fullpath, "w")
    if not fh then
        UIManager:show(infoMessage:new{
            text = _("Error"), message = _("Could not save file:\n") .. tostring(err),
        })
        return
    end

    fh:write(pgn_data)
    fh:close()

    UIManager:close(dialog)
    UIManager:show(infoMessage:new{
        text = _("Saved"), message = _("Game saved to:\n") .. fullpath
    })
end

-- Función principal para abrir el diálogo de guardar
function Kochess:openSaveDialog()
    local current_dir = GAMES_PATH
    --local current_dir = lfs.currentdir()
    local dialog
    local filename_input

    local function onSaveConfirm()
        self:handleSaveFile(dialog, filename_input, current_dir)
    end

    dialog = InputDialog:new{
        title = _("Save current game as"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        filename_input:onCloseKeyboard()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = onSaveConfirm,
                },
            }
        }
    }

    local dir_label = TextWidget:new{
        text = current_dir,
        face = Font:getFace("smallinfofont"),
        truncate_left = true,
        max_width = dialog:getSize().w * 0.8,
    }

    local browse_button = ButtonWidget:new{
        text = "...",
        callback = function()
            UIManager:show(
                PathChooser:new{
                    path = current_dir,
                    title = _("Select Save Folder"),
                    select_file = false,
                    show_files = true,
                    parent = dialog,
                    onConfirm = function(chosen)
                        if chosen and #chosen > 0 then
                            current_dir = chosen
                            dir_label:setText(chosen)
                            UIManager:setDirty(dialog, "ui")
                        end
                    end
                }
            )
        end,
    }

    filename_input = InputText:new{
        text = "game.pgn",
        focused = true,
        parent = dialog,
        enter_callback = onSaveConfirm,
    }

    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            dialog.title_bar,
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Folder") .. ":", face = Font:getFace("cfont", 22) },
                dir_label,
                HorizontalSpan:new{ width = Size.padding.small },
                browse_button,
            },
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Filename") .. ":", face = Font:getFace("cfont", 22) },
                filename_input,
            },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = dialog.title_bar:getSize().w,
                    h = dialog.button_table:getSize().h,
                },
                dialog.button_table
            },
        },
    }

    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    dialog:refocusWidget()
    return dialog
end


function Kochess:openPromotionDialog(f,t,c)
    local choices = {q=Chess.QUEEN, r=Chess.ROOK, b=Chess.BISHOP, n=Chess.KNIGHT}
    local icons_p = { [Chess.QUEEN] = {[Chess.WHITE]="chess/wQ", [Chess.BLACK]="chess/bQ"}, [Chess.ROOK] = {[Chess.WHITE]="chess/wR", [Chess.BLACK]="chess/bR"}, [Chess.BISHOP] = {[Chess.WHITE]="chess/wB", [Chess.BLACK]="chess/bB"}, [Chess.KNIGHT] = {[Chess.WHITE]="chess/wN", [Chess.BLACK]="chess/bN"} }
    
    local dialog = InputDialog:new{ title=_("Promote to"), buttons={} }
    local btns = {}
    for char, type in pairs(choices) do
        table.insert(btns, ButtonWidget:new{ icon=icons_p[type][c], icon_width=60, icon_height=60, callback=function() 
            UIManager:close(dialog)
            local m = self.game.move({from=f, to=t, promotion=char})
            if m then self.board:handleGameMove(m); self:onMoveExecuted(m) end
        end })
    end
    
    local content = FrameContainer:new{ radius=Size.radius.window, bordersize=Size.border.window, background=BACKGROUND_COLOR, padding=Size.padding.large,
        VerticalGroup:new{ align="center", dialog.title_bar, VerticalSpan:new{width=20}, HorizontalGroup:new{ spacing=20, unpack(btns) } }
    }
    dialog.movable = MovableContainer:new{ content }; dialog[1] = CenterContainer:new{ dimen=Screen:getSize(), dialog.movable }
    UIManager:show(dialog)
end

return Kochess