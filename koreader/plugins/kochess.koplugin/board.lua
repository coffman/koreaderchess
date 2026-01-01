-- board.lua (VERSIÓN FINAL: GEOMETRÍA ESTÁTICA)
local _ = require("gettext")
local logger = require("logger")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Chess = require("chess/src/chess")
local Device = require("device")
local Screen = Device.screen

local BOARD_SIZE = 8
local SELECTED_BORDER = 5

local icons = {
    empty = "chess/empty", 
    [Chess.PAWN]   = { [Chess.WHITE] = "chess/wP", [Chess.BLACK] = "chess/bP" },
    [Chess.KNIGHT] = { [Chess.WHITE] = "chess/wN", [Chess.BLACK] = "chess/bN" },
    [Chess.BISHOP] = { [Chess.WHITE] = "chess/wB", [Chess.BLACK] = "chess/bB" },
    [Chess.ROOK]   = { [Chess.WHITE] = "chess/wR", [Chess.BLACK] = "chess/bR" },
    [Chess.QUEEN]  = { [Chess.WHITE] = "chess/wQ", [Chess.BLACK] = "chess/bQ" },
    [Chess.KING]   = { [Chess.WHITE] = "chess/wK", [Chess.BLACK] = "chess/bK" },
}

local Board = FrameContainer:extend{
    game = nil,
    width = 250,
    height = 250,
    moveCallback = nil,
    holdCallback = nil,
    onPromotionNeeded = nil, 
    padding = 0,
    background = Blitbuffer.COLOR_WHITE,
}

function Board:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Board:init()
    if not self.game then
        logger.error("Chess: must be initialized with a Game object")
        return
    end

    local margins = self:allMarginSizes()
    self.button_size = math.min(
        math.floor(self.width / (BOARD_SIZE + 1)) - margins.w,
        math.floor(self.height / (BOARD_SIZE + 1)) - margins.h
    )

    self.selected = nil
    logger.dbg(string.format("Initializing board: %dx%d, button size: %d", self.width, self.height, self.button_size))

    local grid = {}
    for rank = BOARD_SIZE - 1, 0, -1 do 
        local row = {}
        for file = 0, BOARD_SIZE - 1 do 
            table.insert(row, self:createSquareButton(file, rank))
        end
        table.insert(grid, row)
    end

    self.table = ButtonTable:new{
        buttons = grid,
        shrink_unneeded_width = false,
        zero_sep = true,
        sep_width = 0,
        addVerticalSpan = function() end, 
    }

    self:applySquareColors()
    self[1] = CenterContainer:new{ dimen = self:getSize(), self.table }

    logger.dbg("Chess board initialized")
end

function Board:createSquareButton(file, rank)
    return {
        id = Board.toId(file, rank),
        icon = icons.empty,
        alpha = true,
        width = self.button_size,
        height = self.button_size,
        icon_width = self.button_size,
        icon_height = self.button_size,
        
        -- [CAMBIO CLAVE] El borde SIEMPRE ocupa espacio, para evitar saltos.
        bordersize = Screen:scaleBySize(SELECTED_BORDER), 
        
        margin = 0,
        padding = 0,
        allow_hold_when_disabled = true,
        callback = function() self:handleClick(file, rank) end,
        hold_callback = self.holdCallback,
    }
end

function Board:applySquareColors()
    for rank = 0, BOARD_SIZE - 1 do
        for file = 0, BOARD_SIZE - 1 do
            local button = self.table:getButtonById(Board.toId(file, rank))
            local color = ((file + rank) % 2 == 1)
                and Blitbuffer.COLOR_LIGHT_GRAY
                or Blitbuffer.COLOR_DARK_GRAY
            
            button.frame.background = color
            -- [CAMBIO] El borde inicial es del mismo color que el fondo (Invisible)
            button.frame.border_color = color 
        end
    end
end

function Board:handleClick(file, rank)
    local id = Board.toId(file, rank)
    local square = Board.idToPosition(id) 
    logger.dbg("Chess click on square: " .. square)

    if self.selected then
        if self.selected == square then
            self:unmarkSelected(square)
            self.selected = nil
        else
            self:handleMove(self.selected, square)
        end
    else
        local piece = self.game.get(square)
        if piece and piece.color == self.game.turn() then
            logger.dbg("Chess select piece " .. piece.type .. " at " .. square)
            self.selected = square
            self:markSelected(square)
        end
    end
end

function Board:handleMove(from, to)
    -- NO deseleccionamos visualmente todavía para evitar parpadeos
    self.selected = nil 

    local piece = self.game.get(from) 

    local is_pawn_promotion = false
    if piece and piece.type == Chess.PAWN then
        local to_rank_num = tonumber(to:sub(2, 2)) 
        if (piece.color == Chess.WHITE and to_rank_num == 8) or
           (piece.color == Chess.BLACK and to_rank_num == 1) then
            is_pawn_promotion = true
        end
    end

    if is_pawn_promotion and self.onPromotionNeeded then
        self:unmarkSelected(from) -- Aquí sí limpiamos porque sale un diálogo
        self.onPromotionNeeded(from, to, piece.color)
    else
        local move = self.game.move{ from = from, to = to }
        if move then
            -- Éxito: placePiece se encargará de "borrar" el borde al repintar
            self:handleGameMove(move)
        else
            -- Fallo: Restauramos manualmente
            logger.dbg(string.format("Illegal move attempted from %s to %s.", from, to), "ERROR")
            self:unmarkSelected(from)
            self:updateBoard()
        end
    end
end

function Board:handleGameMove(move)
    if not move then return end 

    logger.dbg("Applying game move to board visuals: " .. move.san)
    self:updateSquare(move.from) 
    self:updateSquare(move.to)   

    self:handleMoveFlags(move, move.to)

    if self.moveCallback then
        self.moveCallback(move) 
    end
end

function Board:handleMoveFlags(move, to)
    if not move.flags then return end

    local to_id_result = Board.chessToId(to)
    if not to_id_result then return end
    local to_id = to_id_result

    if move.flags == Chess.FLAGS.EP_CAPTURE then
        local captured_pawn_rank_offset = (move.color == Chess.BLACK and 1 or -1)
        local captured_pawn_id = to_id + captured_pawn_rank_offset * BOARD_SIZE 
        local captured_pawn_square_result = Board.idToPosition(captured_pawn_id)
        if captured_pawn_square_result then
            self:updateSquare(captured_pawn_square_result)
        end
    elseif move.flags == Chess.FLAGS.KSIDE_CASTLE then
        local rook_from_file_id = 7 
        local rook_to_file_id = 5 
        local rank_index = (move.color == Chess.WHITE and 0 or 7) 
        self:updateSquare(Board.idToPosition(Board.toId(rook_from_file_id, rank_index)))
        self:updateSquare(Board.idToPosition(Board.toId(rook_to_file_id, rank_index)))
    elseif move.flags == Chess.FLAGS.QSIDE_CASTLE then
        local rook_from_file_id = 0 
        local rook_to_file_id = 3 
        local rank_index = (move.color == Chess.WHITE and 0 or 7) 
        self:updateSquare(Board.idToPosition(Board.toId(rook_from_file_id, rank_index)))
        self:updateSquare(Board.idToPosition(Board.toId(rook_to_file_id, rank_index)))
    end
end

function Board:markSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then return end
    local button = self.table:getButtonById(id_result)
    
    -- [CAMBIO] Solo cambiamos el COLOR del borde (a Negro), no el tamaño
    button.frame.border_color = Blitbuffer.COLOR_BLACK
    button:refresh()
end

function Board:unmarkSelected(square)
    local id_result = Board.chessToId(square)
    if not id_result then return end
    local button = self.table:getButtonById(id_result)
    
    -- [CAMBIO] Restauramos el borde al color del fondo (invisible)
    button.frame.border_color = Board.positionToColor(square)
    button:refresh()
end

function Board:placePiece(square, piece, color)
    local icon = (piece and icons[piece] and icons[piece][color]) or icons.empty
    local id_result = Board.chessToId(square)
    if not id_result then return end
    
    local button = self.table:getButtonById(id_result)
    button:setIcon(icon, self.button_size)
    
    local bg_color = Board.positionToColor(square)
    button.frame.background = bg_color
    
    -- [CAMBIO] Al colocar/mover, aseguramos que el borde sea invisible (reseteo)
    -- Mantenemos el bordersize fijo que definimos en init.
    button.frame.border_color = bg_color
    
    button:refresh()
end

function Board:updateSquare(square)
    local piece = self.game.get(square)
    if piece then
        self:placePiece(square, piece.type, piece.color)
    else
        self:placePiece(square) 
    end
end

function Board:updateBoard()
    logger.dbg("Chess: Update entire board")
    local board_fen = self.game.board() 
    for file_idx = 0, BOARD_SIZE - 1 do
        for rank_idx = 0, BOARD_SIZE - 1 do
            local element = board_fen[BOARD_SIZE - rank_idx][file_idx + 1]
            local square = Board.idToPosition(Board.toId(file_idx, rank_idx))
            if element then
                self:placePiece(square, element.type, element.color)
            else
                self:placePiece(square) 
            end
        end
    end
end

-- Utilidades
function Board.toId(file, rank) return file * BOARD_SIZE + rank end

function Board.chessToId(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return Board.toId(file_idx, rank_idx)
        end
    end
    return nil
end

function Board.idToPosition(id)
    if type(id) == "number" and id >= 0 and id < BOARD_SIZE * BOARD_SIZE then
        local file_idx = math.floor(id / BOARD_SIZE)
        local rank_idx = id % BOARD_SIZE
        local file_char = string.char(file_idx + string.byte('a'))
        local rank_char = tostring(rank_idx + 1) 
        return file_char .. rank_char
    end
    return nil
end

function Board.positionToColor(position)
    if type(position) == "string" and #position == 2 then
        local file_char = position:sub(1, 1)
        local rank_char = position:sub(2, 2)
        if 'a' <= file_char and file_char <= 'h' and '1' <= rank_char and rank_char <= '8' then
            local file_idx = string.byte(file_char) - string.byte('a')
            local rank_idx = tonumber(rank_char) - 1
            return (file_idx + rank_idx) % 2 == 1 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
        end
    end
    return nil 
end

function Board:allMarginSizes()
    self._padding_top = self.padding_top or self.padding
    self._padding_right = self.padding_right or self.padding
    self._padding_bottom = self.padding_bottom or self.padding
    self._padding_left = self.padding_left or self.padding
    return Geom:new{
        w = (self.margin + self.bordersize) * 2 + self._padding_right + self._padding_left,
        h = (self.margin + self.bordersize) * 2 + self._padding_top + self._padding_bottom,
    }
end

return Board