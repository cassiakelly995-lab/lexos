-- ============================================================
-- LexOS — Scripts Redis Atômicos
-- Linguagem: Lua 5.1 (embedded no Redis)
-- Função: Controle de prazos, cache, rate limiting, filas
-- Execução: EVAL script 0 [args] via Redis
-- ============================================================


-- ============================================================
-- SCRIPT 1: Verificar e alertar prazos vencendo
-- Chave: prazo:{escritorio_id}:{prazo_id}
-- Retorna: lista de prazos críticos
-- ============================================================
local VERIFICAR_PRAZOS = [[
local escritorio_id = ARGV[1]
local agora         = tonumber(ARGV[2])  -- unix timestamp

-- Buscar todos prazos do escritório
local pattern = "prazo:" .. escritorio_id .. ":*"
local cursor  = "0"
local prazos_criticos = {}

repeat
  local res = redis.call("SCAN", cursor, "MATCH", pattern, "COUNT", 200)
  cursor = res[1]
  local chaves = res[2]

  for _, chave in ipairs(chaves) do
    local dados = redis.call("HGETALL", chave)
    local prazo = {}
    for i = 1, #dados, 2 do
      prazo[dados[i]] = dados[i+1]
    end

    local data_prazo = tonumber(prazo["data_timestamp"] or "0")
    local concluido  = prazo["concluido"] or "false"

    if concluido == "false" and data_prazo > 0 then
      local diff_horas = (data_prazo - agora) / 3600
      local urgencia

      if    diff_horas < 0    then urgencia = "VENCIDO"
      elseif diff_horas < 24  then urgencia = "HOJE"
      elseif diff_horas < 72  then urgencia = "3_DIAS"
      elseif diff_horas < 168 then urgencia = "7_DIAS"
      end

      if urgencia then
        table.insert(prazos_criticos, chave)
        table.insert(prazos_criticos, urgencia)
        table.insert(prazos_criticos, prazo["titulo"] or "")
        table.insert(prazos_criticos, tostring(data_prazo))
      end
    end
  end
until cursor == "0"

return prazos_criticos
]]


-- ============================================================
-- SCRIPT 2: Rate Limiting por escritório (sliding window)
-- Previne abuso da API e ataques
-- ============================================================
local RATE_LIMIT = [[
local key      = KEYS[1]        -- "ratelimit:{ip}:{endpoint}"
local limit    = tonumber(ARGV[1])  -- ex: 100
local window   = tonumber(ARGV[2])  -- ex: 60 (segundos)
local agora    = tonumber(ARGV[3])  -- unix timestamp ms

local janela_inicio = agora - (window * 1000)

-- Remover requisições fora da janela
redis.call("ZREMRANGEBYSCORE", key, "-inf", janela_inicio)

-- Contar requisições na janela atual
local count = redis.call("ZCARD", key)

if count < limit then
  -- Permitir e registrar
  redis.call("ZADD", key, agora, agora .. "-" .. math.random(100000))
  redis.call("EXPIRE", key, window + 1)
  return {1, limit - count - 1, window}  -- {permitido, restantes, reset_em}
else
  -- Bloquear — retornar tempo até reset
  local mais_antigo = redis.call("ZRANGE", key, 0, 0, "WITHSCORES")
  local reset_em = 0
  if #mais_antigo > 0 then
    reset_em = math.ceil((tonumber(mais_antigo[2]) + window * 1000 - agora) / 1000)
  end
  return {0, 0, reset_em}  -- {bloqueado, restantes=0, segundos_ate_reset}
end
]]


-- ============================================================
-- SCRIPT 3: Cache invalidation em cascata
-- Ao salvar processo, invalida caches relacionados
-- ============================================================
local INVALIDAR_CACHE_PROCESSO = [[
local processo_id   = ARGV[1]
local escritorio_id = ARGV[2]
local invalidados   = 0

-- Chaves a invalidar
local chaves = {
  "processo:" .. processo_id,
  "dashboard:" .. escritorio_id,
  "processos_lista:" .. escritorio_id,
  "ia:" .. processo_id .. ":*",
}

for _, chave in ipairs(chaves) do
  -- Deletar chave exata
  local del = redis.call("DEL", chave)
  invalidados = invalidados + del
end

-- Invalidar chaves com wildcard via SCAN
local pattern = "ia:" .. processo_id .. ":*"
local cursor  = "0"
repeat
  local res = redis.call("SCAN", cursor, "MATCH", pattern, "COUNT", 50)
  cursor = res[1]
  for _, k in ipairs(res[2]) do
    redis.call("DEL", k)
    invalidados = invalidados + 1
  end
until cursor == "0"

-- Registrar evento de invalidação para debug
redis.call("LPUSH", "log:cache_invalidations",
  os.time() .. ":processo:" .. processo_id)
redis.call("LTRIM", "log:cache_invalidations", 0, 999)

return invalidados
]]


-- ============================================================
-- SCRIPT 4: Enfileirar job com deduplicação
-- Evita processar o mesmo processo duas vezes
-- ============================================================
local ENFILEIRAR_JOB = [[
local fila       = ARGV[1]  -- ex: "queue:cnj_sync"
local job_id     = ARGV[2]  -- ex: uuid do processo
local ttl_lock   = tonumber(ARGV[3] or "300")  -- 5 min default

local lock_key = "lock:" .. fila .. ":" .. job_id

-- Verificar se já está na fila ou em processamento
local existe = redis.call("EXISTS", lock_key)
if existe == 1 then
  return {0, "JOB_DUPLICADO"}
end

-- Adquirir lock atômico
redis.call("SET", lock_key, "1", "EX", ttl_lock, "NX")

-- Enfileirar
local pos = redis.call("LPUSH", fila, job_id)

-- Incrementar contador de jobs
redis.call("INCR", "stats:jobs_enfileirados:" .. fila)

return {1, tostring(pos)}
]]


-- ============================================================
-- SCRIPT 5: Dashboard stats com TTL inteligente
-- Atualiza stats somente se mudaram (economiza recálculo)
-- ============================================================
local ATUALIZAR_STATS_DASHBOARD = [[
local escritorio_id = ARGV[1]
local dados_json    = ARGV[2]
local timestamp     = ARGV[3]

local chave = "dashboard:" .. escritorio_id
local chave_ts = chave .. ":updated_at"

-- Verificar se dados mudaram (hash simples)
local hash_novo = redis.call("CRC16", dados_json) or 0
local hash_ant  = redis.call("GET", chave .. ":hash") or ""

if tostring(hash_novo) == tostring(hash_ant) then
  -- Só atualizar TTL, dados não mudaram
  redis.call("EXPIRE", chave, 120)
  return {"NOT_MODIFIED", timestamp}
end

-- Salvar novos dados
redis.call("SET",  chave,          dados_json, "EX", 120)
redis.call("SET",  chave .. ":hash", hash_novo,  "EX", 120)
redis.call("SET",  chave_ts,       timestamp,    "EX", 120)

-- Log de atualização
redis.call("HSET", "stats:dashboard_updates",
  escritorio_id, timestamp)

return {"UPDATED", timestamp}
]]


-- ============================================================
-- SCRIPT 6: Sessão de usuário segura
-- Rotação automática de tokens
-- ============================================================
local VALIDAR_SESSAO = [[
local session_id    = ARGV[1]
local user_id       = ARGV[2]
local ip            = ARGV[3]
local agora         = tonumber(ARGV[4])

local chave = "session:" .. session_id

-- Buscar sessão
local sessao = redis.call("HGETALL", chave)
if #sessao == 0 then
  return {0, "SESSION_NOT_FOUND"}
end

local sess = {}
for i = 1, #sessao, 2 do
  sess[sessao[i]] = sessao[i+1]
end

-- Verificar user_id
if sess["user_id"] ~= user_id then
  redis.call("DEL", chave)
  return {0, "SESSION_HIJACK_DETECTED"}
end

-- Verificar expiração
local exp = tonumber(sess["expires_at"] or "0")
if exp < agora then
  redis.call("DEL", chave)
  return {0, "SESSION_EXPIRED"}
end

-- Sliding expiration: renovar se mais de metade passou
local criado = tonumber(sess["created_at"] or agora)
local duracao = 86400  -- 24h em segundos
if (agora - criado) > (duracao / 2) then
  redis.call("HSET", chave, "expires_at", agora + duracao)
  redis.call("EXPIRE", chave, duracao)
end

-- Atualizar último acesso e IP
redis.call("HSET", chave, "last_seen", agora, "last_ip", ip)

return {1, "VALID", sess["escritorio_id"] or ""}
]]


-- ============================================================
-- REGISTRO DOS SCRIPTS (SHA1 para uso com EVALSHA)
-- Execute uma vez na inicialização do sistema
-- ============================================================
print("-- Carregando scripts LexOS no Redis...")
print("-- SCRIPT_VERIFICAR_PRAZOS     = redis.call('SCRIPT', 'LOAD', [scripts acima])")
print("-- Usar: redis.call('EVALSHA', sha, 0, escritorio_id, timestamp)")
print("")
print("Scripts disponíveis:")
print("  1. VERIFICAR_PRAZOS         - Detecta prazos críticos (hoje/3d/7d/vencido)")
print("  2. RATE_LIMIT               - Sliding window rate limiter")
print("  3. INVALIDAR_CACHE_PROCESSO - Cache invalidation em cascata")
print("  4. ENFILEIRAR_JOB           - Job queue com deduplicação atômica")
print("  5. ATUALIZAR_STATS_DASHBOARD - Cache inteligente com diff")
print("  6. VALIDAR_SESSAO           - Sessão segura com anti-hijack")
