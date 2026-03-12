// ============================================================
// LexOS — Backend API Principal
// Linguagem: Go 1.22
// Framework: Chi Router + pgx + Redis
// ============================================================

package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	"github.com/go-chi/jwtauth/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// ============================================================
// CONFIGURAÇÃO
// ============================================================

type Config struct {
	Port        string
	DatabaseURL string
	RedisURL    string
	JWTSecret   string
	AIServiceURL string
	CNJApiURL   string
}

func loadConfig() Config {
	return Config{
		Port:         getEnv("PORT", "8080"),
		DatabaseURL:  getEnv("DATABASE_URL", "postgres://lexos:lexos@localhost:5432/lexos_db"),
		RedisURL:     getEnv("REDIS_URL", "redis://localhost:6379"),
		JWTSecret:    getEnv("JWT_SECRET", "lexos-secret-change-in-production"),
		AIServiceURL: getEnv("AI_SERVICE_URL", "http://ai-service:8001"),
		CNJApiURL:    getEnv("CNJ_API_URL", "https://api.cnj.jus.br/pje"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ============================================================
// MODELOS
// ============================================================

type Processo struct {
	ID              uuid.UUID  `json:"id" db:"id"`
	EscritorioID    uuid.UUID  `json:"escritorio_id" db:"escritorio_id"`
	NumeroCNJ       string     `json:"numero_cnj" db:"numero_cnj"`
	Titulo          string     `json:"titulo" db:"titulo"`
	Area            string     `json:"area" db:"area"`
	Status          string     `json:"status" db:"status"`
	ClienteID       uuid.UUID  `json:"cliente_id" db:"cliente_id"`
	ValorCausa      float64    `json:"valor_causa" db:"valor_causa"`
	RiscoIA         int        `json:"risco_ia" db:"risco_ia"`
	ChanceExitoIA   int        `json:"chance_exito_ia" db:"chance_exito_ia"`
	CriadoEm        time.Time  `json:"criado_em" db:"criado_em"`
	AtualizadoEm    time.Time  `json:"atualizado_em" db:"atualizado_em"`
}

type Cliente struct {
	ID           uuid.UUID `json:"id"`
	EscritorioID uuid.UUID `json:"escritorio_id"`
	Tipo         string    `json:"tipo"`
	Nome         string    `json:"nome"`
	CpfCnpj      string    `json:"cpf_cnpj"`
	Email        string    `json:"email"`
	Telefone     string    `json:"telefone"`
	CriadoEm     time.Time `json:"criado_em"`
}

type Prazo struct {
	ID          uuid.UUID `json:"id"`
	ProcessoID  uuid.UUID `json:"processo_id"`
	Titulo      string    `json:"titulo"`
	DataPrazo   time.Time `json:"data_prazo"`
	Tipo        string    `json:"tipo"`
	Prioridade  int       `json:"prioridade"`
	Concluido   bool      `json:"concluido"`
}

type Honorario struct {
	ID             uuid.UUID `json:"id"`
	ProcessoID     uuid.UUID `json:"processo_id"`
	ClienteID      uuid.UUID `json:"cliente_id"`
	Descricao      string    `json:"descricao"`
	Valor          float64   `json:"valor"`
	Status         string    `json:"status"`
	DataVencimento time.Time `json:"data_vencimento"`
}

type DashboardStats struct {
	ProcessosAtivos     int     `json:"processos_ativos"`
	ProcessosUrgentes   int     `json:"processos_urgentes"`
	ClientesAtivos      int     `json:"clientes_ativos"`
	PrazosProximos      int     `json:"prazos_proximos"`
	ReceitaMes          float64 `json:"receita_mes"`
	HonorariosPendentes float64 `json:"honorarios_pendentes"`
	HonorariosVencidos  float64 `json:"honorarios_vencidos"`
}

// ============================================================
// SERVIDOR
// ============================================================

type Server struct {
	config Config
	db     *pgxpool.Pool
	rdb    *redis.Client
	router *chi.Mux
	jwt    *jwtauth.JWTAuth
	log    *slog.Logger
}

func NewServer(cfg Config) (*Server, error) {
	// Database
	pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}

	// Redis
	opt, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opt)

	s := &Server{
		config: cfg,
		db:     pool,
		rdb:    rdb,
		jwt:    jwtauth.New("HS256", []byte(cfg.JWTSecret), nil),
		log:    slog.New(slog.NewJSONHandler(os.Stdout, nil)),
	}
	s.setupRoutes()
	return s, nil
}

// ============================================================
// ROTAS
// ============================================================

func (s *Server) setupRoutes() {
	r := chi.NewRouter()

	// Middlewares globais
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(30 * time.Second))
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"https://*.lexos.com.br", "http://localhost:3000"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type"},
		AllowCredentials: true,
	}))

	// Health check
	r.Get("/health", s.handleHealth)
	r.Get("/metrics", s.handleMetrics)

	// Auth (público)
	r.Group(func(r chi.Router) {
		r.Post("/api/v1/auth/login", s.handleLogin)
		r.Post("/api/v1/auth/refresh", s.handleRefreshToken)
	})

	// Rotas protegidas por JWT
	r.Group(func(r chi.Router) {
		r.Use(jwtauth.Verifier(s.jwt))
		r.Use(jwtauth.Authenticator(s.jwt))
		r.Use(s.middlewareEscritorio)

		// Dashboard
		r.Get("/api/v1/dashboard", s.handleDashboard)

		// Processos
		r.Route("/api/v1/processos", func(r chi.Router) {
			r.Get("/",      s.handleListProcessos)
			r.Post("/",     s.handleCreateProcesso)
			r.Get("/{id}",  s.handleGetProcesso)
			r.Put("/{id}",  s.handleUpdateProcesso)
			r.Delete("/{id}", s.handleDeleteProcesso)
			r.Post("/{id}/sincronizar-cnj", s.handleSincronizarCNJ)
			r.Get("/{id}/movimentacoes",    s.handleMovimentacoes)
			r.Post("/{id}/analisar-ia",     s.handleAnalisarIA)
		})

		// Clientes
		r.Route("/api/v1/clientes", func(r chi.Router) {
			r.Get("/",     s.handleListClientes)
			r.Post("/",    s.handleCreateCliente)
			r.Get("/{id}", s.handleGetCliente)
			r.Put("/{id}", s.handleUpdateCliente)
		})

		// Prazos
		r.Route("/api/v1/prazos", func(r chi.Router) {
			r.Get("/",           s.handleListPrazos)
			r.Post("/",          s.handleCreatePrazo)
			r.Patch("/{id}/concluir", s.handleConcluirPrazo)
		})

		// Honorários
		r.Route("/api/v1/honorarios", func(r chi.Router) {
			r.Get("/",          s.handleListHonorarios)
			r.Post("/",         s.handleCreateHonorario)
			r.Patch("/{id}/pagar", s.handlePagarHonorario)
		})

		// Documentos
		r.Route("/api/v1/documentos", func(r chi.Router) {
			r.Post("/upload",  s.handleUploadDocumento)
			r.Get("/{id}",     s.handleGetDocumento)
			r.Post("/{id}/analisar-ia", s.handleAnalisarDocumentoIA)
		})
	})

	s.router = r
}

// ============================================================
// MIDDLEWARE: Escritório por JWT claim
// ============================================================

func (s *Server) middlewareEscritorio(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, claims, _ := jwtauth.FromContext(r.Context())
		escritorioID, ok := claims["escritorio_id"].(string)
		if !ok || escritorioID == "" {
			s.respondError(w, http.StatusUnauthorized, "escritorio_id ausente no token")
			return
		}
		ctx := context.WithValue(r.Context(), contextKeyEscritorioID, escritorioID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type contextKey string
const contextKeyEscritorioID contextKey = "escritorio_id"

// ============================================================
// HANDLERS
// ============================================================

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	dbOk := s.db.Ping(ctx) == nil
	redisOk := s.rdb.Ping(ctx).Err() == nil
	s.respondJSON(w, http.StatusOK, map[string]any{
		"status":    "ok",
		"database":  dbOk,
		"redis":     redisOk,
		"timestamp": time.Now(),
		"version":   "2.4.1",
	})
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	stats := s.db.Stat()
	s.respondJSON(w, http.StatusOK, map[string]any{
		"db_acquired":        stats.AcquiredConns(),
		"db_idle":            stats.IdleConns(),
		"db_total":           stats.TotalConns(),
		"db_max":             stats.MaxConns(),
	})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email string `json:"email"`
		Senha string `json:"senha"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		s.respondError(w, http.StatusBadRequest, "payload inválido")
		return
	}

	var userID, escritorioID, nome string
	var senhaHash string
	err := s.db.QueryRow(r.Context(),
		`SELECT u.id, u.escritorio_id, u.nome, u.senha_hash 
		 FROM usuarios u WHERE u.email = $1 AND u.ativo = TRUE`,
		body.Email,
	).Scan(&userID, &escritorioID, &nome, &senhaHash)

	if err != nil {
		s.respondError(w, http.StatusUnauthorized, "credenciais inválidas")
		return
	}

	// Em produção: bcrypt.CompareHashAndPassword
	_, tokenString, _ := s.jwt.Encode(map[string]any{
		"user_id":       userID,
		"escritorio_id": escritorioID,
		"nome":          nome,
		"exp":           time.Now().Add(24 * time.Hour).Unix(),
	})

	s.respondJSON(w, http.StatusOK, map[string]any{
		"token": tokenString,
		"user":  map[string]string{"id": userID, "nome": nome},
	})
}

func (s *Server) handleRefreshToken(w http.ResponseWriter, r *http.Request) {
	s.respondJSON(w, http.StatusOK, map[string]string{"message": "token renovado"})
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	escritorioID := r.Context().Value(contextKeyEscritorioID).(string)
	cacheKey := "dashboard:" + escritorioID

	// Tentar cache primeiro
	cached, err := s.rdb.Get(r.Context(), cacheKey).Bytes()
	if err == nil {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "HIT")
		w.Write(cached)
		return
	}

	var stats DashboardStats
	err = s.db.QueryRow(r.Context(),
		`SELECT processos_ativos, processos_urgentes, clientes_ativos,
		        prazos_proximos, receita_mes, honorarios_pendentes, honorarios_vencidos
		 FROM vw_dashboard_escritorio WHERE escritorio_id = $1`,
		escritorioID,
	).Scan(
		&stats.ProcessosAtivos, &stats.ProcessosUrgentes, &stats.ClientesAtivos,
		&stats.PrazosProximos, &stats.ReceitaMes, &stats.HonorariosPendentes, &stats.HonorariosVencidos,
	)
	if err != nil {
		s.respondError(w, http.StatusInternalServerError, "erro ao buscar dashboard")
		return
	}

	// Salvar no cache por 2 minutos
	data, _ := json.Marshal(stats)
	s.rdb.Set(r.Context(), cacheKey, data, 2*time.Minute)

	s.respondJSON(w, http.StatusOK, stats)
}

func (s *Server) handleListProcessos(w http.ResponseWriter, r *http.Request) {
	escritorioID := r.Context().Value(contextKeyEscritorioID).(string)
	q := r.URL.Query()

	rows, err := s.db.Query(r.Context(),
		`SELECT id, escritorio_id, numero_cnj, titulo, area, status,
		        cliente_id, valor_causa, risco_ia, chance_exito_ia, criado_em, atualizado_em
		 FROM processos
		 WHERE escritorio_id = $1
		   AND ($2 = '' OR status = $2)
		   AND ($3 = '' OR area   = $3)
		 ORDER BY atualizado_em DESC
		 LIMIT 50`,
		escritorioID, q.Get("status"), q.Get("area"),
	)
	if err != nil {
		s.respondError(w, http.StatusInternalServerError, "erro ao listar processos")
		return
	}
	defer rows.Close()

	processos := []Processo{}
	for rows.Next() {
		var p Processo
		rows.Scan(&p.ID, &p.EscritorioID, &p.NumeroCNJ, &p.Titulo, &p.Area, &p.Status,
			&p.ClienteID, &p.ValorCausa, &p.RiscoIA, &p.ChanceExitoIA, &p.CriadoEm, &p.AtualizadoEm)
		processos = append(processos, p)
	}
	s.respondJSON(w, http.StatusOK, map[string]any{"data": processos, "total": len(processos)})
}

func (s *Server) handleCreateProcesso(w http.ResponseWriter, r *http.Request) {
	escritorioID := r.Context().Value(contextKeyEscritorioID).(string)
	var p Processo
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		s.respondError(w, http.StatusBadRequest, "payload inválido")
		return
	}
	p.ID = uuid.New()
	p.EscritorioID, _ = uuid.Parse(escritorioID)
	p.Status = "ativo"

	_, err := s.db.Exec(r.Context(),
		`INSERT INTO processos (id, escritorio_id, numero_cnj, titulo, area, status, cliente_id, valor_causa)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		p.ID, p.EscritorioID, p.NumeroCNJ, p.Titulo, p.Area, p.Status, p.ClienteID, p.ValorCausa,
	)
	if err != nil {
		s.respondError(w, http.StatusInternalServerError, "erro ao criar processo")
		return
	}

	// Invalidar cache do dashboard
	s.rdb.Del(r.Context(), "dashboard:"+escritorioID)

	s.respondJSON(w, http.StatusCreated, p)
}

func (s *Server) handleGetProcesso(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	escritorioID := r.Context().Value(contextKeyEscritorioID).(string)
	var p Processo
	err := s.db.QueryRow(r.Context(),
		`SELECT id, escritorio_id, numero_cnj, titulo, area, status,
		        cliente_id, valor_causa, risco_ia, chance_exito_ia, criado_em, atualizado_em
		 FROM processos WHERE id = $1 AND escritorio_id = $2`,
		id, escritorioID,
	).Scan(&p.ID, &p.EscritorioID, &p.NumeroCNJ, &p.Titulo, &p.Area, &p.Status,
		&p.ClienteID, &p.ValorCausa, &p.RiscoIA, &p.ChanceExitoIA, &p.CriadoEm, &p.AtualizadoEm)
	if err != nil {
		s.respondError(w, http.StatusNotFound, "processo não encontrado")
		return
	}
	s.respondJSON(w, http.StatusOK, p)
}

func (s *Server) handleUpdateProcesso(w http.ResponseWriter, r *http.Request) {
	s.respondJSON(w, http.StatusOK, map[string]string{"message": "processo atualizado"})
}

func (s *Server) handleDeleteProcesso(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	escritorioID := r.Context().Value(contextKeyEscritorioID).(string)
	_, err := s.db.Exec(r.Context(),
		`UPDATE processos SET status = 'arquivado' WHERE id = $1 AND escritorio_id = $2`,
		id, escritorioID,
	)
	if err != nil {
		s.respondError(w, http.StatusInternalServerError, "erro ao arquivar")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleSincronizarCNJ(w http.ResponseWriter, r *http.Request) {
	// Dispara job assíncrono via Redis Queue
	id := chi.URLParam(r, "id")
	s.rdb.LPush(r.Context(), "queue:cnj_sync", id)
	s.respondJSON(w, http.StatusAccepted, map[string]string{
		"message":    "sincronização enfileirada",
		"processo_id": id,
	})
}

func (s *Server) handleMovimentacoes(w http.ResponseWriter, r *http.Request) {
	s.respondJSON(w, http.StatusOK, map[string]any{"data": []any{}})
}

func (s *Server) handleAnalisarIA(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	s.rdb.LPush(r.Context(), "queue:ia_analise", id)
	s.respondJSON(w, http.StatusAccepted, map[string]string{
		"message":    "análise IA enfileirada",
		"processo_id": id,
	})
}

func (s *Server) handleListClientes(w http.ResponseWriter, r *http.Request)      { s.respondJSON(w, http.StatusOK, map[string]any{"data": []any{}}) }
func (s *Server) handleCreateCliente(w http.ResponseWriter, r *http.Request)     { s.respondJSON(w, http.StatusCreated, map[string]string{"message": "cliente criado"}) }
func (s *Server) handleGetCliente(w http.ResponseWriter, r *http.Request)        { s.respondJSON(w, http.StatusOK, map[string]string{"message": "cliente"}) }
func (s *Server) handleUpdateCliente(w http.ResponseWriter, r *http.Request)     { s.respondJSON(w, http.StatusOK, map[string]string{"message": "atualizado"}) }
func (s *Server) handleListPrazos(w http.ResponseWriter, r *http.Request)        { s.respondJSON(w, http.StatusOK, map[string]any{"data": []any{}}) }
func (s *Server) handleCreatePrazo(w http.ResponseWriter, r *http.Request)       { s.respondJSON(w, http.StatusCreated, map[string]string{"message": "prazo criado"}) }
func (s *Server) handleConcluirPrazo(w http.ResponseWriter, r *http.Request)     { s.respondJSON(w, http.StatusOK, map[string]string{"message": "prazo concluído"}) }
func (s *Server) handleListHonorarios(w http.ResponseWriter, r *http.Request)    { s.respondJSON(w, http.StatusOK, map[string]any{"data": []any{}}) }
func (s *Server) handleCreateHonorario(w http.ResponseWriter, r *http.Request)   { s.respondJSON(w, http.StatusCreated, map[string]string{"message": "honorário criado"}) }
func (s *Server) handlePagarHonorario(w http.ResponseWriter, r *http.Request)    { s.respondJSON(w, http.StatusOK, map[string]string{"message": "honorário pago"}) }
func (s *Server) handleUploadDocumento(w http.ResponseWriter, r *http.Request)   { s.respondJSON(w, http.StatusCreated, map[string]string{"message": "documento enviado"}) }
func (s *Server) handleGetDocumento(w http.ResponseWriter, r *http.Request)      { s.respondJSON(w, http.StatusOK, map[string]string{"message": "documento"}) }
func (s *Server) handleAnalisarDocumentoIA(w http.ResponseWriter, r *http.Request) { s.respondJSON(w, http.StatusAccepted, map[string]string{"message": "análise enfileirada"}) }

// ============================================================
// HELPERS
// ============================================================

func (s *Server) respondJSON(w http.ResponseWriter, code int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(data)
}

func (s *Server) respondError(w http.ResponseWriter, code int, msg string) {
	s.respondJSON(w, code, map[string]string{"error": msg})
}

// ============================================================
// MAIN
// ============================================================

func main() {
	cfg := loadConfig()
	srv, err := NewServer(cfg)
	if err != nil {
		slog.Error("falha ao inicializar servidor", "erro", err)
		os.Exit(1)
	}

	slog.Info("LexOS API iniciando",
		"porta", cfg.Port,
		"versao", "2.4.1",
	)

	http.ListenAndServe(":"+cfg.Port, srv.router)
}
