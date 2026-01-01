local Logger = require("logger")
local Utils = require("utils")

local M = {}

local UCIEngine = {}
UCIEngine.__index = UCIEngine

local function parse_uci_line(line, state)
  line = line:match("^%s*(.-)%s*$")
  if not line or line == "" then return end

  Logger.info("UCI READ: " .. line)

  local eng = state._engine

  if line == "uciok" then
    Logger.info("UCI: ¡RECIBIDO UCIOK!")
    state.uciok = true
    eng:_trigger("uciok")
  elseif line == "readyok" then
    state.readyok = true
    eng:_trigger("readyok")
  elseif line:find("^id name") then
    state.id_name = line:match("^id name%s+(.+)$")
  elseif line:find("^bestmove") then
    local mv = line:match("^bestmove%s+(%S+)")
    Logger.info("UCI: bestmove -> " .. tostring(mv))
    eng:_trigger("bestmove", mv)
  
  -- [PARSEO DE OPCIONES - VITAL]
  -- Esto lee las líneas "option name Hash type spin..." de tu log
  elseif line:find("^option") then
    local name = line:match("name%s+(.-)%s+type")
    local type = line:match("type%s+(%w+)")
    local default = line:match("default%s+(%S+)")
    
    if name and type then
       -- Guardamos la opción para que SettingsWidget la encuentre
       state.options[name] = { 
           type = type, 
           default = default, 
           value = default,
           min = line:match("min%s+(%d+)"),
           max = line:match("max%s+(%d+)")
       }
    end
  end
end

function UCIEngine.spawn(cmd, args)
  local pid, rfd, wfd_or_err = Utils.execInSubProcess(cmd, args, true, true)
  if not pid then return nil, rfd end

  local self = setmetatable({}, UCIEngine)
  self.pid = pid
  self.fd_read = rfd
  self.fd_write = wfd_or_err
  self.callbacks = {}
  
  self.state = {
    uciok = false,
    options = {}, -- Inicializamos la tabla de opciones
    _engine = self,
  }

  self._reader = Utils.reader(self.fd_read,
                              function(line)
                                parse_uci_line(line, self.state)
                                self:_trigger("read", line)
                              end,
                              "Kochess UCI Reader")
  
  -- ESCRITOR PROTEGIDO
  local raw_writer = Utils.writer(self.fd_write, true, "Kochess UCI Writer")
  self.send = function(data)
    local status, err = pcall(function()
      raw_writer(tostring(data))  -- SIN "\n"
    end)
    if not status then
      Logger.warn("UCI WRITE ERROR: " .. tostring(err))
    else
      Logger.info("UCI SENT: " .. tostring(data))
    end
  end


  return self
end

function UCIEngine:on(event, fn)
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], fn)
end

function UCIEngine:_trigger(event, ...)
    local list = self.callbacks[event]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

-- Comandos
function UCIEngine:uci()
  self.state.uciok = false
  self.state.to_uciok = 80  -- un poco más de margen en Kobo
  Logger.info("UCI: Enviando comando 'uci'...")
  self.send("uci")

  Utils.pollingLoop(1, self._reader, function()
      self.state.to_uciok = self.state.to_uciok - 1
      return (not self.state.uciok) and self.state.to_uciok > 0
  end)
end
function UCIEngine:isready() self.send("isready") end

function UCIEngine:setOption(name, value)
  -- Normaliza a string (UCI manda todo como texto)
  value = tostring(value)

  -- Envía comando UCI
  self.send(string.format("setoption name %s value %s", name, value))

  -- Mantén el estado coherente para el widget
  self.state.options[name] = self.state.options[name] or { type = "string", default = nil }
  self.state.options[name].value = value

  -- (Opcional pero recomendable) fuerza sincronización
  self:isready()
end


function UCIEngine:ucinewgame() self.send("ucinewgame") end

function UCIEngine:position(spec)
  local cmd = "position" .. (spec.fen and (" fen " .. spec.fen) or " startpos")
  if spec.moves then cmd = cmd .. " moves " .. spec.moves end
  self.send(cmd)
end

function UCIEngine:go(opts)
    local cmd = "go"
    opts = opts or {}

    -- Orden recomendado UCI (y tokens booleanos sin valor)
    local order = {
        "searchmoves", "ponder",
        "wtime", "btime", "winc", "binc", "movestogo",
        "depth", "nodes", "mate", "movetime",
        "infinite"
    }

    for _, k in ipairs(order) do
        local v = opts[k]
        if v ~= nil then
            if type(v) == "boolean" then
                if v then cmd = cmd .. " " .. k end
            else
                cmd = cmd .. " " .. k .. " " .. tostring(v)
            end
        end
    end

    self.state.bestmove = nil
    Logger.info("UCI: Enviando GO -> " .. cmd)
    self.send(cmd)

    -- Leer hasta que llegue bestmove
    Utils.pollingLoop(1, self._reader, function()
        return not self.state.bestmove
    end)
end


function UCIEngine:stop() self.send("stop") end

M.UCIEngine = UCIEngine
return M