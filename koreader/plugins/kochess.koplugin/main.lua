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

local Chess = require("chess")
local ChessBoard = require("board")
local Timer = require("timer")
local Uci = require("uci")
local SettingsWidget = require("settingswidget")
local _ = require("gettext")

-- RUTA ABSOLUTA
local PLUGIN_PATH = "/mnt/onboard/.adds/koreader/plugins/kochess.koplugin/"
local UCI_ENGINE_PATH = PLUGIN_PATH .. "engines/stockfish"

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

function Kochess:installIconsIfNeeded()
    local dest_dir = "/mnt/onboard/.adds/koreader/resources/icons/src/kochess"
    if lfs.attributes(dest_dir, "mode") ~= "directory" then
        local src_dir = PLUGIN_PATH .. "icons"
        os.execute('cp -r "' .. src_dir .. '" "' .. dest_dir .. '"')
    end
end

function Kochess:addToMainMenu(menu_items)
    menu_items.kochess = {
        text = _("Chess Game"), sorting_hint = "tools", callback = function() self:startGame() end, keep_menu_open = false, 
    }
end

function Kochess:startGame()
    self:initializeGameLogic()
    self:initializeEngine() 
    self:initializeBoard()
    self:buildUILayout()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self.board:updateBoard() 
    UIManager:show(self) 
end

-- ==========================================================
-- ARRANQUE DEL MOTOR (MÉTODO DIRECTO - EL QUE FUNCIONA)
-- ==========================================================
function Kochess:initializeEngine()
    Logger.info("KOCHESS: Arrancando Stockfish 11 (Directo + Argv0)...")

    os.execute("chmod +x " .. UCI_ENGINE_PATH)

    -- [CORRECCIÓN] Pasamos "stockfish" como argumento.
    -- Antes pasábamos {} (vacío), y eso confunde al proceso en Linux.
    self.engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})

    
    if not self.engine then
        Logger.error("KOCHESS: Fallo al crear proceso.")
        UIManager:show(infoMessage:new{text="Error", message="Motor no arranca."})
        return
    end

    -- CHIVATO
    self.engine:on("read", function(data)
        if data then 
            local clean = data:gsub("\n", " "):gsub("\r", "")
            Logger.info("RAW ENGINE: " .. clean)
        end
    end)

    self.engine:on("uciok", function()
        Logger.info("KOCHESS: ¡RECIBIDO UCIOK!")
        self:updatePgnLogInitialText()

        -- CONFIGURACIÓN PARA KOBO (RÁPIDA Y LIGERA)
        self.engine.send("setoption name Hash value 4")   -- Mínima memoria
        self.engine.send("setoption name Threads value 1") -- Un solo hilo
        self.engine.send("setoption name Skill Level value 5") -- Nivel bajo (juega más rápido y humano)
        self.engine.send("setoption name Slow Mover value 10") -- Reduce el "fanatismo" por el tiempo
        
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
    
    self.pgn_log = self:createPgnLogWidget(_("Welcome!"), self.full_width - toolbar_width, log_h)
    
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
        FrameContainer:new{ background = BACKGROUND_COLOR, padding=0, HorizontalGroup:new{ height=log_h, toolbar, self.pgn_log } },
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

function Kochess:createPgnLogWidget(txt, w, h) return TextBoxWidget:new{ use_xtext=true, text=txt, face=Font:getFace(self.notation_font, self.notation_size), scroll=true, width=w, height=h, dialog=self } end
function Kochess:createToolbarButton(icon, w, h, cb) return ButtonWidget:new{ icon=icon, icon_width=w, icon_height=h, callback=cb } end
function Kochess:handleUndoMove(all) self:stopUCI(); self.timer:stop(); if all then while self.game.undo() do end else self.game.undo() end; self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui"); self.timer:start() end
function Kochess:handleRedoMove(all) self:stopUCI(); self.timer:stop(); if all then while self.game.redo() do end else self.game.redo() end; self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui"); self.timer:start() end

function Kochess:onMoveExecuted(move)
    Logger.info("KOCHESS: Move " .. move.san)
    self.running = true
    self:updatePgnLog()
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
    -- Evitar reentradas: si el motor ya está pensando, no relanzar go
    if self.engine_busy then return end
    self.engine_busy = true

    local moves = {}
    for _, m in ipairs(self.game.history({ verbose = true })) do
        moves[#moves + 1] = m.from .. m.to .. (m.promotion or "")
    end

    -- Si tu wrapper ya asume startpos, basta con moves=...
    self.engine:position({ moves = table.concat(moves, " ") })

    Logger.info("KOCHESS: Enviando GO con límite de 10 segundos...")
    self.engine:go({
        movetime = 10000 -- 10000 ms = 10 segundos por jugada
    })
    --self.engine:go({
    --    wtime = self.timer:getRemainingTime(Chess.WHITE) * 1000,
    --    btime = self.timer:getRemainingTime(Chess.BLACK) * 1000,
    --})
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
    local current_dir = lfs.currentdir()
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