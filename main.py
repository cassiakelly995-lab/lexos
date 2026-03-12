# ============================================================
# LexOS — Serviço de Inteligência Artificial
# Linguagem: Python 3.12
# Framework: FastAPI + LangChain + OpenAI
# Função: Análise de petições, risco, jurisprudência, predição
# ============================================================

from __future__ import annotations

import asyncio
import hashlib
import json
import re
from datetime import datetime
from typing import Any, Optional
from uuid import UUID

import httpx
import redis.asyncio as aioredis
from fastapi import FastAPI, HTTPException, BackgroundTasks, Depends
from fastapi.middleware.cors import CORSMiddleware
from langchain.chat_models import ChatOpenAI
from langchain.prompts import ChatPromptTemplate
from langchain.output_parsers import PydanticOutputParser
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain.embeddings import OpenAIEmbeddings
from langchain.vectorstores import PGVector
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings
import asyncpg


# ============================================================
# CONFIGURAÇÃO
# ============================================================

class Settings(BaseSettings):
    openai_api_key: str = ""
    database_url: str = "postgresql://lexos:lexos@localhost:5432/lexos_db"
    redis_url: str = "redis://localhost:6379"
    go_api_url: str = "http://api:8080"
    model_name: str = "gpt-4-turbo"
    model_temperature: float = 0.1

    class Config:
        env_file = ".env"

settings = Settings()


# ============================================================
# MODELOS PYDANTIC
# ============================================================

class AnaliseRisco(BaseModel):
    nivel_risco: int = Field(ge=0, le=100, description="0=sem risco, 100=risco máximo")
    chance_exito: int = Field(ge=0, le=100, description="Probabilidade de êxito %")
    pontos_criticos: list[str] = Field(description="Principais pontos de risco")
    jurisprudencia_favoravel: list[str] = Field(description="Julgados favoráveis identificados")
    jurisprudencia_desfavoravel: list[str] = Field(description="Julgados desfavoráveis identificados")
    recomendacoes: list[str] = Field(description="Ações recomendadas")
    resumo: str = Field(description="Análise executiva em 3 parágrafos")

class AnalisePeticao(BaseModel):
    qualidade_tecnica: int = Field(ge=0, le=100)
    clareza_redacao: int = Field(ge=0, le=100)
    fundamentacao_juridica: int = Field(ge=0, le=100)
    pedidos_identificados: list[str]
    argumentos_principais: list[str]
    pontos_melhoria: list[str]
    erros_formais: list[str]
    resumo: str

class EntidadesExtraidas(BaseModel):
    partes: list[dict[str, str]]   # [{"nome": ..., "cpf_cnpj": ..., "papel": ...}]
    valores: list[dict[str, Any]]  # [{"descricao": ..., "valor": ..., "moeda": ...}]
    datas: list[dict[str, str]]    # [{"descricao": ..., "data": ...}]
    numeros_processo: list[str]
    tribunais: list[str]
    advogados: list[dict[str, str]]

class PeticaoGerada(BaseModel):
    tipo: str
    conteudo: str
    numero_paginas_estimado: int
    qualidade_estimada: int
    alertas: list[str]

class AnaliseRequest(BaseModel):
    processo_id: UUID
    texto: Optional[str] = None
    tipo_analise: str  # "risco", "peticao", "entidades", "predicao"
    contexto: Optional[dict] = None

class GerarPeticaoRequest(BaseModel):
    processo_id: UUID
    tipo_peticao: str  # "contestacao", "recurso", "peticao_inicial"
    fatos: str
    pedidos: list[str]
    argumentos: Optional[list[str]] = None


# ============================================================
# CLIENTES EXTERNOS
# ============================================================

class DatabaseClient:
    def __init__(self, url: str):
        self.url = url
        self._pool: asyncpg.Pool | None = None

    async def pool(self) -> asyncpg.Pool:
        if not self._pool:
            self._pool = await asyncpg.create_pool(self.url)
        return self._pool

    async def get_processo(self, processo_id: str) -> dict | None:
        pool = await self.pool()
        row = await pool.fetchrow(
            """SELECT p.*, c.nome AS cliente_nome, c.cpf_cnpj,
                      t.sigla AS tribunal_sigla
               FROM processos p
               LEFT JOIN clientes c ON c.id = p.cliente_id
               LEFT JOIN tribunais t ON t.id = p.tribunal_id
               WHERE p.id = $1""",
            processo_id
        )
        return dict(row) if row else None

    async def salvar_analise(self, analise: dict) -> None:
        pool = await self.pool()
        await pool.execute(
            """INSERT INTO analises_ia
               (escritorio_id, processo_id, tipo_analise, modelo, resultado, confianca)
               VALUES ($1, $2, $3, $4, $5::jsonb, $6)""",
            analise["escritorio_id"], analise["processo_id"],
            analise["tipo"], settings.model_name,
            json.dumps(analise["resultado"]), analise.get("confianca", 80)
        )
        # Atualizar risco e chance no processo
        if "nivel_risco" in analise["resultado"]:
            await pool.execute(
                """UPDATE processos SET
                   risco_ia = $1, chance_exito_ia = $2, atualizado_em = NOW()
                   WHERE id = $3""",
                analise["resultado"]["nivel_risco"],
                analise["resultado"]["chance_exito"],
                analise["processo_id"]
            )


class CNJClient:
    """Integração com API do CNJ / PJe para busca de jurisprudência"""

    BASE_URL = "https://jurisprudencia.cnj.jus.br/pesquisa"

    async def buscar_jurisprudencia(self, termos: list[str], tribunal: str = "") -> list[dict]:
        async with httpx.AsyncClient(timeout=10.0) as client:
            try:
                resp = await client.get(
                    f"{self.BASE_URL}/api/v1/jurisprudencia",
                    params={"q": " ".join(termos[:5]), "tribunal": tribunal, "size": 5}
                )
                if resp.status_code == 200:
                    return resp.json().get("hits", [])
            except Exception:
                pass
        return []


# ============================================================
# MOTOR DE IA
# ============================================================

class LexIA:
    def __init__(self):
        self.llm = ChatOpenAI(
            model=settings.model_name,
            temperature=settings.model_temperature,
            openai_api_key=settings.openai_api_key
        )
        self.embeddings = OpenAIEmbeddings(openai_api_key=settings.openai_api_key)
        self.splitter = RecursiveCharacterTextSplitter(
            chunk_size=4000,
            chunk_overlap=400,
            separators=["\n\n", "\n", "Art.", "§", "Cláusula"]
        )

    async def analisar_risco(self, texto: str, contexto: dict) -> AnaliseRisco:
        parser = PydanticOutputParser(pydantic_object=AnaliseRisco)
        prompt = ChatPromptTemplate.from_messages([
            ("system", """Você é um advogado sênior especialista em análise de risco processual brasileiro.
Analise com rigor técnico e precisão. Cite números de processos e súmulas quando relevante.
Responda EXCLUSIVAMENTE em JSON válido seguindo o formato especificado.
{format_instructions}"""),
            ("human", """CONTEXTO DO PROCESSO:
Área: {area}
Tribunal: {tribunal}
Valor da causa: R$ {valor}
Polo do cliente: {polo}

TEXTO PARA ANÁLISE:
{texto}

Execute análise completa de risco processual.""")
        ])

        chain = prompt | self.llm | parser
        result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: chain.invoke({
                "area": contexto.get("area", "cível"),
                "tribunal": contexto.get("tribunal", "TJSP"),
                "valor": contexto.get("valor_causa", "0"),
                "polo": contexto.get("polo", "ativo"),
                "texto": texto[:6000],
                "format_instructions": parser.get_format_instructions()
            })
        )
        return result

    async def analisar_peticao(self, texto: str) -> AnalisePeticao:
        parser = PydanticOutputParser(pydantic_object=AnalisePeticao)
        prompt = ChatPromptTemplate.from_messages([
            ("system", """Você é revisor jurídico especializado em petições do Direito brasileiro.
Avalie qualidade técnica, clareza, fundamentação e forma.
{format_instructions}"""),
            ("human", "Analise esta petição juridicamente:\n\n{texto}")
        ])

        chain = prompt | self.llm | parser
        result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: chain.invoke({
                "texto": texto[:8000],
                "format_instructions": parser.get_format_instructions()
            })
        )
        return result

    async def extrair_entidades(self, texto: str) -> EntidadesExtraidas:
        parser = PydanticOutputParser(pydantic_object=EntidadesExtraidas)
        prompt = ChatPromptTemplate.from_messages([
            ("system", """Extraia todas as entidades jurídicas relevantes do texto.
Identifique partes, valores, datas, números de processo, tribunais, advogados.
{format_instructions}"""),
            ("human", "{texto}")
        ])
        chain = prompt | self.llm | parser
        result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: chain.invoke({
                "texto": texto[:8000],
                "format_instructions": parser.get_format_instructions()
            })
        )
        return result

    async def gerar_peticao(self, req: GerarPeticaoRequest, processo: dict) -> PeticaoGerada:
        TEMPLATES = {
            "contestacao": "contestação em face de {polo_passivo}",
            "recurso": "recurso ordinário em face da sentença",
            "peticao_inicial": "petição inicial"
        }
        tipo_desc = TEMPLATES.get(req.tipo_peticao, req.tipo_peticao)

        prompt = ChatPromptTemplate.from_messages([
            ("system", """Você é advogado sênior especializado em Direito {area} brasileiro.
Redija peças processuais em linguagem jurídica precisa, com formatação ABNT e estrutura processual correta.
Cite legislação e jurisprudência relevantes."""),
            ("human", """Redija {tipo} para o seguinte caso:

FATOS:
{fatos}

PEDIDOS:
{pedidos}

ARGUMENTOS ADICIONAIS:
{argumentos}

INFORMAÇÕES DO PROCESSO:
- Tribunal: {tribunal}
- Valor da causa: R$ {valor}

Inclua: qualificação das partes, dos fatos, do direito, dos pedidos e requerimentos finais.""")
        ])

        chain = prompt | self.llm
        result = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: chain.invoke({
                "area": processo.get("area", "cível"),
                "tipo": tipo_desc,
                "fatos": req.fatos,
                "pedidos": "\n".join(f"- {p}" for p in req.pedidos),
                "argumentos": "\n".join(req.argumentos or []),
                "tribunal": processo.get("tribunal_sigla", "TJSP"),
                "valor": processo.get("valor_causa", "0"),
                "polo_passivo": processo.get("parte_contraria", "[PARTE CONTRÁRIA]"),
            })
        )

        conteudo = result.content
        num_palavras = len(conteudo.split())
        return PeticaoGerada(
            tipo=req.tipo_peticao,
            conteudo=conteudo,
            numero_paginas_estimado=max(1, num_palavras // 350),
            qualidade_estimada=82,
            alertas=["Revisar nomes das partes", "Confirmar número do processo antes de protocolar"]
        )


# ============================================================
# APP FASTAPI
# ============================================================

app = FastAPI(
    title="LexOS — Serviço de IA Jurídica",
    version="2.4.1",
    description="Motor de inteligência artificial para análise processual brasileira"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "https://*.lexos.com.br"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Singletons
db_client = DatabaseClient(settings.database_url)
cnj_client = CNJClient()
lex_ia = LexIA()
redis_client: aioredis.Redis | None = None


@app.on_event("startup")
async def startup():
    global redis_client
    redis_client = await aioredis.from_url(settings.redis_url)
    # Iniciar worker de fila em background
    asyncio.create_task(processar_fila())


@app.get("/health")
async def health():
    return {"status": "ok", "service": "lexia", "model": settings.model_name}


@app.post("/api/v1/analisar", response_model=dict)
async def analisar(req: AnaliseRequest, background_tasks: BackgroundTasks):
    """Análise principal — aceita texto ou busca do banco pelo processo_id"""

    # Cache por hash do texto
    cache_key = f"ia:{req.tipo_analise}:{hashlib.md5((req.texto or str(req.processo_id)).encode()).hexdigest()}"
    if redis_client:
        cached = await redis_client.get(cache_key)
        if cached:
            return {"resultado": json.loads(cached), "cache": True}

    # Buscar processo se texto não fornecido
    processo = await db_client.get_processo(str(req.processo_id))
    if not processo and not req.texto:
        raise HTTPException(404, "Processo não encontrado")

    texto = req.texto or processo.get("resumo", "") or ""
    contexto = req.contexto or (dict(processo) if processo else {})

    # Executar análise
    resultado: Any
    if req.tipo_analise == "risco":
        resultado = await lex_ia.analisar_risco(texto, contexto)
    elif req.tipo_analise == "peticao":
        resultado = await lex_ia.analisar_peticao(texto)
    elif req.tipo_analise == "entidades":
        resultado = await lex_ia.extrair_entidades(texto)
    else:
        raise HTTPException(400, f"Tipo de análise inválido: {req.tipo_analise}")

    result_dict = resultado.dict()

    # Salvar no banco e cache em background
    if processo:
        background_tasks.add_task(db_client.salvar_analise, {
            "escritorio_id": str(processo["escritorio_id"]),
            "processo_id": str(req.processo_id),
            "tipo": req.tipo_analise,
            "resultado": result_dict,
        })

    if redis_client:
        await redis_client.setex(cache_key, 3600, json.dumps(result_dict, default=str))

    return {"resultado": result_dict, "cache": False, "modelo": settings.model_name}


@app.post("/api/v1/gerar-peticao", response_model=PeticaoGerada)
async def gerar_peticao(req: GerarPeticaoRequest):
    processo = await db_client.get_processo(str(req.processo_id))
    if not processo:
        raise HTTPException(404, "Processo não encontrado")
    return await lex_ia.gerar_peticao(req, dict(processo))


@app.post("/api/v1/jurisprudencia/buscar")
async def buscar_jurisprudencia(body: dict):
    termos = body.get("termos", [])
    tribunal = body.get("tribunal", "")
    resultados = await cnj_client.buscar_jurisprudencia(termos, tribunal)
    return {"resultados": resultados, "total": len(resultados)}


# ============================================================
# WORKER DE FILA (Redis Queue)
# ============================================================

async def processar_fila():
    """Consome fila queue:ia_analise do Redis — disparado pelo backend Go"""
    while True:
        try:
            if redis_client:
                item = await redis_client.brpop("queue:ia_analise", timeout=5)
                if item:
                    _, processo_id = item
                    processo = await db_client.get_processo(processo_id.decode())
                    if processo and processo.get("resumo"):
                        req = AnaliseRequest(
                            processo_id=UUID(processo_id.decode()),
                            texto=processo["resumo"],
                            tipo_analise="risco",
                            contexto=dict(processo)
                        )
                        await analisar(req, BackgroundTasks())
        except Exception as e:
            await asyncio.sleep(2)


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8001, reload=False, workers=2)
