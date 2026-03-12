// ============================================================
// LexOS — Frontend TypeScript
// Linguagem: TypeScript 5.4
// Framework: Next.js 14 + TanStack Query + Zod
// ============================================================

// ============================================================
// TYPES — Modelos centrais com Zod (runtime + compiletime)
// ============================================================

import { z } from "zod";

// Enums espelhando o banco
export const AreaJuridica = z.enum([
  "trabalhista", "civel", "criminal", "empresarial",
  "familia", "tributario", "previdenciario", "administrativo",
  "consumidor", "imobiliario", "ambiental", "constitucional",
]);

export const StatusProcesso = z.enum([
  "ativo", "aguardando", "suspenso", "arquivado",
  "encerrado", "urgente", "recurso", "execucao",
]);

export const StatusHonorario = z.enum([
  "pendente", "pago", "vencido", "cancelado", "parcelado",
]);

// Schemas
export const ProcessoSchema = z.object({
  id: z.string().uuid(),
  escritorioId: z.string().uuid(),
  numeroCnj: z.string().optional(),
  titulo: z.string().min(3).max(300),
  area: AreaJuridica,
  status: StatusProcesso,
  clienteId: z.string().uuid(),
  valorCausa: z.number().nonnegative().optional(),
  riscoIa: z.number().int().min(0).max(100).optional(),
  chanceExitoIa: z.number().int().min(0).max(100).optional(),
  criadoEm: z.string().datetime(),
  atualizadoEm: z.string().datetime(),
});

export const ClienteSchema = z.object({
  id: z.string().uuid(),
  tipo: z.enum(["fisica", "juridica"]),
  nome: z.string().min(2).max(300),
  cpfCnpj: z.string().optional(),
  email: z.string().email().optional(),
  telefone: z.string().optional(),
  criadoEm: z.string().datetime(),
});

export const PrazoSchema = z.object({
  id: z.string().uuid(),
  processoId: z.string().uuid(),
  titulo: z.string(),
  dataPrazo: z.string().datetime(),
  tipo: z.string(),
  prioridade: z.number().int().min(1).max(5),
  concluido: z.boolean(),
});

export const HonorarioSchema = z.object({
  id: z.string().uuid(),
  processoId: z.string().uuid().optional(),
  clienteId: z.string().uuid(),
  descricao: z.string(),
  valor: z.number().positive(),
  status: StatusHonorario,
  dataVencimento: z.string(),
});

export const DashboardStatsSchema = z.object({
  processosAtivos: z.number(),
  processosUrgentes: z.number(),
  clientesAtivos: z.number(),
  prazosProximos: z.number(),
  receitaMes: z.number(),
  honorariosPendentes: z.number(),
  honoariosVencidos: z.number(),
});

export const AnaliseRiscoSchema = z.object({
  nivelRisco: z.number().min(0).max(100),
  chanceExito: z.number().min(0).max(100),
  pontosCriticos: z.array(z.string()),
  jurisprudenciaFavoravel: z.array(z.string()),
  jurisprudenciaDesfavoravel: z.array(z.string()),
  recomendacoes: z.array(z.string()),
  resumo: z.string(),
});

// Types inferidos
export type Processo = z.infer<typeof ProcessoSchema>;
export type Cliente = z.infer<typeof ClienteSchema>;
export type Prazo = z.infer<typeof PrazoSchema>;
export type Honorario = z.infer<typeof HonorarioSchema>;
export type DashboardStats = z.infer<typeof DashboardStatsSchema>;
export type AnaliseRisco = z.infer<typeof AnaliseRiscoSchema>;

// ============================================================
// API CLIENT — Type-safe HTTP client
// ============================================================

interface ApiConfig {
  baseUrl: string;
  getToken: () => string | null;
}

type ApiResponse<T> =
  | { data: T; error: null }
  | { data: null; error: string };

class LexOSApiClient {
  private config: ApiConfig;

  constructor(config: ApiConfig) {
    this.config = config;
  }

  private async request<T>(
    method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
    path: string,
    body?: unknown,
    options?: RequestInit
  ): Promise<ApiResponse<T>> {
    const token = this.config.getToken();
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    };

    try {
      const res = await fetch(`${this.config.baseUrl}${path}`, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
        ...options,
      });

      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        return { data: null, error: err.error ?? "Erro desconhecido" };
      }

      const data = await res.json() as T;
      return { data, error: null };
    } catch (err) {
      return { data: null, error: (err as Error).message };
    }
  }

  // Auth
  async login(email: string, senha: string) {
    return this.request<{ token: string; user: { id: string; nome: string } }>(
      "POST", "/api/v1/auth/login", { email, senha }
    );
  }

  // Dashboard
  async getDashboard() {
    const res = await this.request<DashboardStats>("GET", "/api/v1/dashboard");
    if (res.data) {
      const parsed = DashboardStatsSchema.safeParse(res.data);
      return parsed.success
        ? { data: parsed.data, error: null }
        : { data: null, error: "Resposta inválida do servidor" };
    }
    return res;
  }

  // Processos
  async listProcessos(filters?: { status?: string; area?: string }) {
    const params = new URLSearchParams(
      Object.fromEntries(Object.entries(filters ?? {}).filter(([, v]) => v))
    );
    return this.request<{ data: Processo[]; total: number }>(
      "GET", `/api/v1/processos?${params}`
    );
  }

  async getProcesso(id: string) {
    return this.request<Processo>("GET", `/api/v1/processos/${id}`);
  }

  async createProcesso(data: Omit<Processo, "id" | "escritorioId" | "criadoEm" | "atualizadoEm">) {
    const validated = ProcessoSchema.omit({
      id: true, escritorioId: true, criadoEm: true, atualizadoEm: true
    }).parse(data);
    return this.request<Processo>("POST", "/api/v1/processos", validated);
  }

  async sincronizarCNJ(processoId: string) {
    return this.request<{ message: string }>(
      "POST", `/api/v1/processos/${processoId}/sincronizar-cnj`
    );
  }

  async analisarProcessoIA(processoId: string) {
    return this.request<{ message: string; processoId: string }>(
      "POST", `/api/v1/processos/${processoId}/analisar-ia`
    );
  }

  // Clientes
  async listClientes(busca?: string) {
    const params = busca ? `?q=${encodeURIComponent(busca)}` : "";
    return this.request<{ data: Cliente[] }>("GET", `/api/v1/clientes${params}`);
  }

  // Prazos
  async listPrazos(soPendentes = true) {
    return this.request<{ data: Prazo[] }>(
      "GET", `/api/v1/prazos${soPendentes ? "?concluido=false" : ""}`
    );
  }

  async concluirPrazo(id: string) {
    return this.request<Prazo>("PATCH", `/api/v1/prazos/${id}/concluir`);
  }

  // Honorários
  async listHonorarios(status?: string) {
    return this.request<{ data: Honorario[] }>(
      "GET", `/api/v1/honorarios${status ? `?status=${status}` : ""}`
    );
  }

  async pagarHonorario(id: string) {
    return this.request<Honorario>("PATCH", `/api/v1/honorarios/${id}/pagar`);
  }

  // Documentos
  async uploadDocumento(processoId: string, arquivo: File, tipo: string) {
    const formData = new FormData();
    formData.append("arquivo", arquivo);
    formData.append("processo_id", processoId);
    formData.append("titulo", arquivo.name);
    formData.append("tipo", tipo);

    const token = this.config.getToken();
    const res = await fetch(`${this.config.baseUrl}/api/v1/documentos/upload`, {
      method: "POST",
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      body: formData,
    });
    const data = await res.json();
    return res.ok
      ? { data, error: null }
      : { data: null, error: data.error ?? "Upload falhou" };
  }
}

// ============================================================
// HOOKS React Query
// ============================================================

import { useQuery, useMutation, useQueryClient, QueryClient } from "@tanstack/react-query";

// Query keys centralizados — evita magic strings
export const queryKeys = {
  dashboard:        ["dashboard"] as const,
  processos:        (filters?: object) => ["processos", filters] as const,
  processo:         (id: string) => ["processo", id] as const,
  clientes:         (busca?: string) => ["clientes", busca] as const,
  prazos:           (pendentes?: boolean) => ["prazos", pendentes] as const,
  honorarios:       (status?: string) => ["honorarios", status] as const,
} as const;

// Hook: Dashboard
export function useDashboard(api: LexOSApiClient) {
  return useQuery({
    queryKey: queryKeys.dashboard,
    queryFn: async () => {
      const res = await api.getDashboard();
      if (res.error) throw new Error(res.error);
      return res.data!;
    },
    refetchInterval: 2 * 60 * 1000, // 2 minutos
    staleTime: 60 * 1000,
  });
}

// Hook: Processos
export function useProcessos(api: LexOSApiClient, filters?: { status?: string; area?: string }) {
  return useQuery({
    queryKey: queryKeys.processos(filters),
    queryFn: async () => {
      const res = await api.listProcessos(filters);
      if (res.error) throw new Error(res.error);
      return res.data!;
    },
    staleTime: 30 * 1000,
  });
}

// Hook: Criar processo
export function useCreateProcesso(api: LexOSApiClient) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: Parameters<typeof api.createProcesso>[0]) =>
      api.createProcesso(data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["processos"] });
      qc.invalidateQueries({ queryKey: queryKeys.dashboard });
    },
  });
}

// Hook: Analisar com IA
export function useAnalisarIA(api: LexOSApiClient) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (processoId: string) => api.analisarProcessoIA(processoId),
    onSuccess: (_data, processoId) => {
      setTimeout(() => {
        qc.invalidateQueries({ queryKey: queryKeys.processo(processoId) });
      }, 5000); // Aguarda processamento assíncrono
    },
  });
}

// Hook: Prazos
export function usePrazos(api: LexOSApiClient) {
  return useQuery({
    queryKey: queryKeys.prazos(true),
    queryFn: async () => {
      const res = await api.listPrazos(true);
      if (res.error) throw new Error(res.error);
      return res.data!;
    },
    refetchInterval: 5 * 60 * 1000,
  });
}

// ============================================================
// UTILS
// ============================================================

export function formatarMoeda(valor: number): string {
  return new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(valor);
}

export function formatarNumeroCNJ(numero: string): string {
  const clean = numero.replace(/\D/g, "");
  if (clean.length !== 20) return numero;
  return `${clean.slice(0, 7)}-${clean.slice(7, 9)}.${clean.slice(9, 13)}.${clean.slice(13, 14)}.${clean.slice(14, 16)}.${clean.slice(16)}`;
}

export function calcularUrgenciaPrazo(dataPrazo: string): {
  label: string;
  classe: "urgente" | "atencao" | "normal" | "vencido";
  diasRestantes: number;
} {
  const diff = Math.ceil(
    (new Date(dataPrazo).getTime() - Date.now()) / (1000 * 60 * 60 * 24)
  );

  if (diff < 0)  return { label: "Vencido",  classe: "vencido",  diasRestantes: diff };
  if (diff <= 3) return { label: `${diff}d`,  classe: "urgente",  diasRestantes: diff };
  if (diff <= 7) return { label: `${diff}d`,  classe: "atencao",  diasRestantes: diff };
                 return { label: `${diff}d`,  classe: "normal",   diasRestantes: diff };
}

// Singleton do QueryClient
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 2,
      refetchOnWindowFocus: false,
    },
  },
});

// Singleton do API client
export const createApiClient = (baseUrl: string) =>
  new LexOSApiClient({
    baseUrl,
    getToken: () => {
      if (typeof window !== "undefined") {
        return localStorage.getItem("lexos_token");
      }
      return null;
    },
  });
