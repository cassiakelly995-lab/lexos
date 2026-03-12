# ⚖️ LexOS — Sistema Jurídico Profissional

**A plataforma de gestão jurídica mais moderna do Brasil.**
Construída com 8 linguagens de programação, cada uma escolhida pela sua força específica.

---

## 🗂️ Arquitetura de Linguagens

| # | Linguagem | Serviço | Por que essa linguagem? |
|---|-----------|---------|------------------------|
| 1 | **SQL (PostgreSQL)** | Banco de dados | ACID, triggers de auditoria, views analíticas |
| 2 | **Go 1.22** | API Principal | Ultra-rápido, goroutines, <10ms p99 latência |
| 3 | **Python 3.12** | Motor de IA | LangChain, OpenAI, NLP jurídico |
| 4 | **Java 21** | Integração CNJ | Compatibilidade SOAP/PJe dos tribunais |
| 5 | **Rust 1.78** | Parser de PDFs | Segurança de memória, 100+ PDFs/segundo |
| 6 | **TypeScript 5.4** | Frontend | Tipagem estática, React/Next.js |
| 7 | **Lua 5.1** | Scripts Redis | Operações atômicas no cache |
| 8 | **Bash 5** | DevOps/CI | Automação, deploy, backup |

---

## 📁 Estrutura do Projeto

```
lexos/
├── database/
│   └── 001_schema.sql          # SQL — Schema completo PostgreSQL
├── backend-go/
│   └── main.go                 # Go — API REST principal
├── ai-python/
│   └── main.py                 # Python — Serviço de IA (FastAPI)
├── java-cnj/
│   └── LexOSCnjApplication.java # Java — Integração CNJ/Tribunais
├── docs-rust/
│   └── src/main.rs             # Rust — Parser de documentos PDF
├── frontend-ts/
│   └── src/lib/api.ts          # TypeScript — Client e hooks React
├── infrastructure/
│   ├── docker-compose.yml      # YAML — Orquestração completa
│   ├── redis-scripts.lua       # Lua — Scripts atômicos Redis
│   └── lexos.sh                # Bash — CLI de operações
└── README.md
```

---

## 🚀 Quick Start

```bash
# 1. Setup (uma única vez)
chmod +x infrastructure/lexos.sh
./infrastructure/lexos.sh setup

# 2. Preencher chaves de API no .env
nano .env   # OPENAI_API_KEY, CNJ_API_KEY

# 3. Deploy completo
./infrastructure/lexos.sh deploy

# 4. Verificar saúde
./infrastructure/lexos.sh status
```

**Acessos:**
| Serviço | URL |
|---------|-----|
| Dashboard | http://localhost:3000 |
| API | http://localhost:8080 |
| API Docs | http://localhost:8080/docs |
| Grafana | http://localhost:3001 |

---

## 🔌 Serviços e Portas

| Serviço | Porta | Tecnologia |
|---------|-------|------------|
| Frontend | 3000 | Next.js 14 + TypeScript |
| API Principal | 8080 | Go + Chi Router |
| Serviço IA | 8001 | Python + FastAPI |
| Parser Docs | 8002 | Rust + Axum |
| Integração CNJ | 8003 | Java + Spring Boot |
| PostgreSQL | 5432 | SQL |
| Redis | 6379 | Lua scripts |
| Prometheus | 9090 | Métricas |
| Grafana | 3001 | Dashboards |

---

## 🤖 Funcionalidades de IA (LexIA)

- **Análise de Risco Processual** — Score 0-100 com justificativa jurídica
- **Chance de Êxito** — Predição baseada em jurisprudência
- **Geração de Petições** — Contestações e recursos automáticos
- **Extração de Entidades** — CPF, CNPJ, valores, datas, partes
- **Análise de Petições** — Score de qualidade técnica e redação
- **Busca de Jurisprudência** — Via DataJud/CNJ em tempo real

---

## 🛡️ Segurança

- ✅ JWT com rotação automática
- ✅ Rate limiting por IP e endpoint (Lua/Redis)
- ✅ Multi-tenancy: dados isolados por `escritorio_id`
- ✅ Auditoria imutável de todas as operações
- ✅ Criptografia via `pgcrypto` no banco
- ✅ Anti-session hijack no Redis
- ✅ SSL/TLS obrigatório em produção

---

## 📊 Roadmap MVP → Escala

| Fase | Features | Prazo estimado |
|------|----------|----------------|
| **MVP** | Dashboard, processos, clientes, prazos | 3 meses |
| **v1** | IA básica, integração CNJ, honorários | +2 meses |
| **v2** | App mobile, assinatura eletrônica | +3 meses |
| **Scale** | Multi-região, white-label, API pública | +6 meses |

---

*LexOS — Construído para advogados que levam seu trabalho a sério.*
