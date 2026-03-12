-- ============================================================
-- LexOS — Schema Principal do Banco de Dados
-- PostgreSQL 15+
-- Linguagem: SQL
-- ============================================================

-- EXTENSÕES
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- busca textual fuzzy
CREATE EXTENSION IF NOT EXISTS "unaccent";       -- busca sem acento
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- criptografia

-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE area_juridica AS ENUM (
  'trabalhista', 'civel', 'criminal', 'empresarial',
  'familia', 'tributario', 'previdenciario', 'administrativo',
  'consumidor', 'imobiliario', 'ambiental', 'constitucional'
);

CREATE TYPE status_processo AS ENUM (
  'ativo', 'aguardando', 'suspenso', 'arquivado',
  'encerrado', 'urgente', 'recurso', 'execucao'
);

CREATE TYPE tipo_pessoa AS ENUM ('fisica', 'juridica');

CREATE TYPE tipo_movimentacao AS ENUM (
  'peticao_inicial', 'contestacao', 'recurso', 'sentenca',
  'acordao', 'despacho', 'audiencia', 'pericia',
  'embargo', 'execucao', 'citacao', 'intimacao', 'outro'
);

CREATE TYPE status_honorario AS ENUM (
  'pendente', 'pago', 'vencido', 'cancelado', 'parcelado'
);

CREATE TYPE tipo_documento AS ENUM (
  'peticao', 'contrato', 'procuracao', 'certidao',
  'comprovante', 'laudo', 'sentenca', 'recurso', 'outro'
);

-- ============================================================
-- ESCRITÓRIO
-- ============================================================

CREATE TABLE escritorios (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nome          VARCHAR(200) NOT NULL,
  cnpj          VARCHAR(18) UNIQUE,
  oab_num       VARCHAR(30),
  email         VARCHAR(150) UNIQUE NOT NULL,
  telefone      VARCHAR(20),
  endereco      JSONB,               -- {rua, num, bairro, cidade, uf, cep}
  configuracoes JSONB DEFAULT '{}',  -- preferências do sistema
  plano         VARCHAR(30) DEFAULT 'mvp',
  ativo         BOOLEAN DEFAULT TRUE,
  criado_em     TIMESTAMPTZ DEFAULT NOW(),
  atualizado_em TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- USUÁRIOS / ADVOGADOS
-- ============================================================

CREATE TABLE usuarios (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escritorio_id   UUID NOT NULL REFERENCES escritorios(id) ON DELETE CASCADE,
  nome            VARCHAR(200) NOT NULL,
  email           VARCHAR(150) UNIQUE NOT NULL,
  senha_hash      VARCHAR(255) NOT NULL,
  oab_numero      VARCHAR(30),
  oab_uf          CHAR(2),
  cargo           VARCHAR(100),
  avatar_url      VARCHAR(500),
  permissoes      JSONB DEFAULT '["processos:read","clientes:read"]',
  ativo           BOOLEAN DEFAULT TRUE,
  ultimo_login    TIMESTAMPTZ,
  criado_em       TIMESTAMPTZ DEFAULT NOW(),
  atualizado_em   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_usuarios_escritorio ON usuarios(escritorio_id);
CREATE INDEX idx_usuarios_email ON usuarios(email);

-- ============================================================
-- CLIENTES
-- ============================================================

CREATE TABLE clientes (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escritorio_id   UUID NOT NULL REFERENCES escritorios(id) ON DELETE CASCADE,
  tipo            tipo_pessoa NOT NULL DEFAULT 'fisica',
  nome            VARCHAR(300) NOT NULL,
  cpf_cnpj        VARCHAR(18),
  rg              VARCHAR(20),
  email           VARCHAR(150),
  telefone        VARCHAR(20),
  telefone2       VARCHAR(20),
  endereco        JSONB,
  data_nascimento DATE,
  profissao       VARCHAR(100),
  nacionalidade   VARCHAR(80) DEFAULT 'Brasileira',
  estado_civil    VARCHAR(30),
  observacoes     TEXT,
  tags            TEXT[],
  ativo           BOOLEAN DEFAULT TRUE,
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW(),
  atualizado_em   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_clientes_escritorio ON clientes(escritorio_id);
CREATE INDEX idx_clientes_nome ON clientes USING gin(nome gin_trgm_ops);
CREATE INDEX idx_clientes_cpf ON clientes(cpf_cnpj);

-- ============================================================
-- TRIBUNAIS / VARAS
-- ============================================================

CREATE TABLE tribunais (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sigla       VARCHAR(20) UNIQUE NOT NULL,  -- TJSP, TRT2, STJ...
  nome        VARCHAR(200) NOT NULL,
  uf          CHAR(2),
  tipo        VARCHAR(50),  -- estadual, federal, trabalhista, superior
  api_url     VARCHAR(500), -- endpoint CNJ/PJe
  ativo       BOOLEAN DEFAULT TRUE
);

CREATE TABLE varas (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tribunal_id  UUID NOT NULL REFERENCES tribunais(id),
  nome         VARCHAR(200) NOT NULL,
  comarca      VARCHAR(200),
  cidade       VARCHAR(100),
  uf           CHAR(2)
);

-- ============================================================
-- PROCESSOS (tabela principal)
-- ============================================================

CREATE TABLE processos (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escritorio_id       UUID NOT NULL REFERENCES escritorios(id) ON DELETE CASCADE,
  numero_cnj          VARCHAR(30) UNIQUE,   -- formato CNJ: 0000000-00.0000.0.00.0000
  numero_antigo       VARCHAR(50),
  titulo              VARCHAR(300) NOT NULL,
  area                area_juridica NOT NULL,
  status              status_processo NOT NULL DEFAULT 'ativo',
  tribunal_id         UUID REFERENCES tribunais(id),
  vara_id             UUID REFERENCES varas(id),
  cliente_id          UUID NOT NULL REFERENCES clientes(id),
  cliente_polo        VARCHAR(20) DEFAULT 'ativo',  -- ativo, passivo, terceiro
  parte_contraria     VARCHAR(300),
  advogado_resp_id    UUID REFERENCES usuarios(id),
  valor_causa         NUMERIC(15,2),
  valor_condenacao    NUMERIC(15,2),
  data_distribuicao   DATE,
  data_encerramento   DATE,
  fase_atual          VARCHAR(100),
  risco_ia            SMALLINT CHECK (risco_ia BETWEEN 0 AND 100),
  chance_exito_ia     SMALLINT CHECK (chance_exito_ia BETWEEN 0 AND 100),
  resumo              TEXT,
  observacoes         TEXT,
  tags                TEXT[],
  cnj_sincronizado_em TIMESTAMPTZ,
  criado_em           TIMESTAMPTZ DEFAULT NOW(),
  atualizado_em       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_processos_escritorio   ON processos(escritorio_id);
CREATE INDEX idx_processos_cliente      ON processos(cliente_id);
CREATE INDEX idx_processos_status       ON processos(status);
CREATE INDEX idx_processos_area         ON processos(area);
CREATE INDEX idx_processos_numero_cnj   ON processos(numero_cnj);
CREATE INDEX idx_processos_advogado     ON processos(advogado_resp_id);
CREATE INDEX idx_processos_titulo       ON processos USING gin(titulo gin_trgm_ops);

-- ============================================================
-- MOVIMENTAÇÕES PROCESSUAIS
-- ============================================================

CREATE TABLE movimentacoes (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  processo_id     UUID NOT NULL REFERENCES processos(id) ON DELETE CASCADE,
  tipo            tipo_movimentacao NOT NULL,
  descricao       TEXT NOT NULL,
  data_ocorrencia TIMESTAMPTZ NOT NULL,
  data_prazo      TIMESTAMPTZ,         -- prazo gerado por esta movimentação
  usuario_id      UUID REFERENCES usuarios(id),
  origem          VARCHAR(30) DEFAULT 'manual',  -- manual, cnj_sync, ia
  dados_extras    JSONB DEFAULT '{}',
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_movimentacoes_processo ON movimentacoes(processo_id);
CREATE INDEX idx_movimentacoes_data     ON movimentacoes(data_ocorrencia DESC);

-- ============================================================
-- PRAZOS
-- ============================================================

CREATE TABLE prazos (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  processo_id     UUID NOT NULL REFERENCES processos(id) ON DELETE CASCADE,
  escritorio_id   UUID NOT NULL REFERENCES escritorios(id),
  titulo          VARCHAR(300) NOT NULL,
  descricao       TEXT,
  data_prazo      TIMESTAMPTZ NOT NULL,
  tipo            VARCHAR(80),  -- fatal, recomendado, audiencia, pericia
  prioridade      SMALLINT DEFAULT 3 CHECK (prioridade BETWEEN 1 AND 5),
  concluido       BOOLEAN DEFAULT FALSE,
  concluido_em    TIMESTAMPTZ,
  concluido_por   UUID REFERENCES usuarios(id),
  alerta_1_dia    BOOLEAN DEFAULT TRUE,
  alerta_3_dias   BOOLEAN DEFAULT TRUE,
  alerta_7_dias   BOOLEAN DEFAULT FALSE,
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_prazos_processo   ON prazos(processo_id);
CREATE INDEX idx_prazos_data       ON prazos(data_prazo);
CREATE INDEX idx_prazos_escritorio ON prazos(escritorio_id, concluido, data_prazo);

-- ============================================================
-- HONORÁRIOS
-- ============================================================

CREATE TABLE honorarios (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  processo_id     UUID REFERENCES processos(id),
  cliente_id      UUID NOT NULL REFERENCES clientes(id),
  escritorio_id   UUID NOT NULL REFERENCES escritorios(id),
  descricao       VARCHAR(400) NOT NULL,
  valor           NUMERIC(12,2) NOT NULL,
  status          status_honorario NOT NULL DEFAULT 'pendente',
  data_vencimento DATE NOT NULL,
  data_pagamento  DATE,
  forma_pagamento VARCHAR(50),
  parcelas        SMALLINT DEFAULT 1,
  parcela_atual   SMALLINT DEFAULT 1,
  nota_fiscal     VARCHAR(100),
  observacoes     TEXT,
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW(),
  atualizado_em   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_honorarios_cliente    ON honorarios(cliente_id);
CREATE INDEX idx_honorarios_escritorio ON honorarios(escritorio_id, status);
CREATE INDEX idx_honorarios_vencimento ON honorarios(data_vencimento, status);

-- ============================================================
-- DOCUMENTOS
-- ============================================================

CREATE TABLE documentos (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  processo_id     UUID REFERENCES processos(id) ON DELETE CASCADE,
  escritorio_id   UUID NOT NULL REFERENCES escritorios(id),
  titulo          VARCHAR(400) NOT NULL,
  tipo            tipo_documento NOT NULL,
  storage_path    VARCHAR(1000),   -- S3/R2 path
  storage_url     VARCHAR(1000),
  tamanho_bytes   BIGINT,
  mime_type       VARCHAR(100),
  hash_sha256     CHAR(64),
  ia_analisado    BOOLEAN DEFAULT FALSE,
  ia_resumo       TEXT,
  ia_entidades    JSONB,           -- nomes, datas, valores extraídos pela IA
  ia_risco        SMALLINT,
  criado_por      UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_documentos_processo   ON documentos(processo_id);
CREATE INDEX idx_documentos_escritorio ON documentos(escritorio_id);

-- ============================================================
-- ANÁLISES DE IA
-- ============================================================

CREATE TABLE analises_ia (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escritorio_id   UUID NOT NULL REFERENCES escritorios(id),
  processo_id     UUID REFERENCES processos(id),
  documento_id    UUID REFERENCES documentos(id),
  tipo_analise    VARCHAR(80) NOT NULL,  -- risco, peticao, jurisprudencia, predicao
  modelo          VARCHAR(80) DEFAULT 'gpt-4-juridico-br',
  prompt_tokens   INTEGER,
  resp_tokens     INTEGER,
  resultado       JSONB NOT NULL,
  confianca       SMALLINT CHECK (confianca BETWEEN 0 AND 100),
  revisado        BOOLEAN DEFAULT FALSE,
  revisado_por    UUID REFERENCES usuarios(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_analises_ia_processo ON analises_ia(processo_id);

-- ============================================================
-- AUDITORIA (imutável)
-- ============================================================

CREATE TABLE auditoria (
  id          BIGSERIAL PRIMARY KEY,
  tabela      VARCHAR(80) NOT NULL,
  operacao    CHAR(6) NOT NULL,  -- INSERT, UPDATE, DELETE
  registro_id UUID NOT NULL,
  usuario_id  UUID,
  ip          INET,
  dados_antes JSONB,
  dados_apos  JSONB,
  criado_em   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_auditoria_tabela    ON auditoria(tabela, registro_id);
CREATE INDEX idx_auditoria_usuario   ON auditoria(usuario_id);
CREATE INDEX idx_auditoria_criado_em ON auditoria(criado_em DESC);

-- ============================================================
-- FUNÇÃO DE AUDITORIA AUTOMÁTICA
-- ============================================================

CREATE OR REPLACE FUNCTION fn_auditoria()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO auditoria(tabela, operacao, registro_id, dados_antes, dados_apos)
  VALUES (
    TG_TABLE_NAME,
    TG_OP,
    COALESCE(NEW.id, OLD.id),
    CASE WHEN TG_OP != 'INSERT' THEN row_to_json(OLD) ELSE NULL END,
    CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW) ELSE NULL END
  );
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Aplicar auditoria nas tabelas críticas
CREATE TRIGGER audit_processos
  AFTER INSERT OR UPDATE OR DELETE ON processos
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER audit_honorarios
  AFTER INSERT OR UPDATE OR DELETE ON honorarios
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

-- ============================================================
-- FUNÇÃO: updated_at automático
-- ============================================================

CREATE OR REPLACE FUNCTION fn_atualizado_em()
RETURNS TRIGGER AS $$
BEGIN NEW.atualizado_em = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_escritorios_upd   BEFORE UPDATE ON escritorios   FOR EACH ROW EXECUTE FUNCTION fn_atualizado_em();
CREATE TRIGGER trg_usuarios_upd      BEFORE UPDATE ON usuarios      FOR EACH ROW EXECUTE FUNCTION fn_atualizado_em();
CREATE TRIGGER trg_clientes_upd      BEFORE UPDATE ON clientes      FOR EACH ROW EXECUTE FUNCTION fn_atualizado_em();
CREATE TRIGGER trg_processos_upd     BEFORE UPDATE ON processos     FOR EACH ROW EXECUTE FUNCTION fn_atualizado_em();
CREATE TRIGGER trg_honorarios_upd    BEFORE UPDATE ON honorarios    FOR EACH ROW EXECUTE FUNCTION fn_atualizado_em();

-- ============================================================
-- VIEWS ANALÍTICAS
-- ============================================================

CREATE OR REPLACE VIEW vw_dashboard_escritorio AS
SELECT
  e.id AS escritorio_id,
  COUNT(DISTINCT p.id) FILTER (WHERE p.status = 'ativo')      AS processos_ativos,
  COUNT(DISTINCT p.id) FILTER (WHERE p.status = 'urgente')    AS processos_urgentes,
  COUNT(DISTINCT c.id) FILTER (WHERE c.ativo = TRUE)          AS clientes_ativos,
  COUNT(DISTINCT pr.id) FILTER (WHERE pr.concluido = FALSE AND pr.data_prazo <= NOW() + INTERVAL '7 days') AS prazos_proximos,
  SUM(h.valor) FILTER (WHERE h.status = 'pago' AND DATE_TRUNC('month', h.data_pagamento) = DATE_TRUNC('month', NOW())) AS receita_mes,
  SUM(h.valor) FILTER (WHERE h.status = 'pendente') AS honorarios_pendentes,
  SUM(h.valor) FILTER (WHERE h.status = 'vencido')  AS honorarios_vencidos
FROM escritorios e
LEFT JOIN processos  p  ON p.escritorio_id  = e.id
LEFT JOIN clientes   c  ON c.escritorio_id  = e.id
LEFT JOIN prazos     pr ON pr.escritorio_id = e.id
LEFT JOIN honorarios h  ON h.escritorio_id  = e.id
GROUP BY e.id;

-- ============================================================
-- DADOS INICIAIS (seed)
-- ============================================================

INSERT INTO tribunais (sigla, nome, uf, tipo) VALUES
  ('TJSP',  'Tribunal de Justiça de São Paulo',          'SP', 'estadual'),
  ('TJRJ',  'Tribunal de Justiça do Rio de Janeiro',     'RJ', 'estadual'),
  ('TRT2',  'Tribunal Regional do Trabalho 2ª Região',   'SP', 'trabalhista'),
  ('TRT1',  'Tribunal Regional do Trabalho 1ª Região',   'RJ', 'trabalhista'),
  ('TRF3',  'Tribunal Regional Federal 3ª Região',       'SP', 'federal'),
  ('STJ',   'Superior Tribunal de Justiça',              'DF', 'superior'),
  ('TST',   'Tribunal Superior do Trabalho',             'DF', 'superior'),
  ('STF',   'Supremo Tribunal Federal',                  'DF', 'superior'),
  ('CNJ',   'Conselho Nacional de Justiça',              'DF', 'administrativo');
