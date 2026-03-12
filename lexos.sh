#!/usr/bin/env bash
# ============================================================
# LexOS — Scripts de Deploy e Automação
# Linguagem: Bash 5
# Função: Setup, deploy, backup, monitoramento
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

LEXOS_VERSION="2.4.1"
LEXOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()     { echo -e "${BOLD}[LexOS]${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✗${RESET}  $*" >&2; }
die()     { error "$*"; exit 1; }

# ============================================================
# SETUP INICIAL — Configura ambiente do zero
# ============================================================
cmd_setup() {
  log "Iniciando setup LexOS v${LEXOS_VERSION}..."

  # Verificar dependências
  local deps=("docker" "docker-compose" "openssl" "curl")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      die "Dependência não encontrada: $dep. Instale antes de continuar."
    fi
  done
  success "Dependências verificadas"

  # Criar .env se não existir
  if [[ ! -f "${LEXOS_DIR}/.env" ]]; then
    log "Criando arquivo .env..."
    cat > "${LEXOS_DIR}/.env" <<EOF
# LexOS — Variáveis de Ambiente
# Gerado em: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Banco de Dados
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n')

# Redis
REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n')

# JWT
JWT_SECRET=$(openssl rand -base64 64 | tr -d '/+=\n')

# Next.js
NEXTAUTH_SECRET=$(openssl rand -base64 32 | tr -d '/+=\n')
APP_URL=http://localhost:3000
API_URL=http://localhost:8080

# APIs Externas (preencher manualmente)
OPENAI_API_KEY=sk-...
CNJ_API_KEY=

# Grafana
GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=\n')
EOF
    success ".env criado com senhas geradas automaticamente"
    warn "IMPORTANTE: Preencha OPENAI_API_KEY e CNJ_API_KEY no .env"
  else
    warn ".env já existe, pulando criação"
  fi

  # Criar diretórios necessários
  mkdir -p \
    "${LEXOS_DIR}/infrastructure/ssl" \
    "${LEXOS_DIR}/backups" \
    "${LEXOS_DIR}/logs"
  success "Diretórios criados"

  # SSL auto-assinado para desenvolvimento
  if [[ ! -f "${LEXOS_DIR}/infrastructure/ssl/cert.pem" ]]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${LEXOS_DIR}/infrastructure/ssl/key.pem" \
      -out    "${LEXOS_DIR}/infrastructure/ssl/cert.pem" \
      -subj "/C=BR/ST=SP/L=São Paulo/O=LexOS/CN=lexos.local" \
      2>/dev/null
    success "Certificado SSL auto-assinado criado"
  fi

  success "Setup concluído! Execute: ./scripts/lexos.sh deploy"
}

# ============================================================
# DEPLOY — Sobe todos os serviços
# ============================================================
cmd_deploy() {
  local env="${1:-production}"
  log "Deploy LexOS — ambiente: ${env}"

  cd "${LEXOS_DIR}"

  # Build das imagens
  log "Building imagens Docker..."
  docker compose build --parallel 2>&1 | grep -E "(Successfully|Error|warning)" || true
  success "Imagens construídas"

  # Subir banco primeiro
  log "Iniciando banco de dados..."
  docker compose up -d postgres redis
  aguardar_servico "postgres" 30
  aguardar_servico "redis" 15
  success "Banco e cache online"

  # Executar migrations
  cmd_migrate

  # Subir demais serviços
  log "Iniciando todos os serviços..."
  docker compose up -d
  success "Todos os serviços iniciados"

  # Verificar saúde
  sleep 5
  cmd_status
}

# ============================================================
# MIGRATE — Executar migrations SQL
# ============================================================
cmd_migrate() {
  log "Executando migrations..."
  source "${LEXOS_DIR}/.env" 2>/dev/null || true

  local pg_container
  pg_container=$(docker compose ps -q postgres 2>/dev/null || echo "")

  if [[ -z "$pg_container" ]]; then
    die "Container postgres não encontrado. Execute 'deploy' primeiro."
  fi

  local migration_dir="${LEXOS_DIR}/database"
  local migration_files
  mapfile -t migration_files < <(find "$migration_dir" -name "*.sql" | sort)

  for file in "${migration_files[@]}"; do
    local filename
    filename=$(basename "$file")
    log "Aplicando migration: ${filename}"

    docker compose exec -T postgres psql \
      -U lexos -d lexos_db \
      -v ON_ERROR_STOP=1 \
      < "$file" \
      && success "${filename} aplicado" \
      || warn "${filename} pode já ter sido aplicado (ignorando)"
  done

  success "Migrations concluídas"
}

# ============================================================
# STATUS — Verificar saúde dos serviços
# ============================================================
cmd_status() {
  log "Status dos serviços LexOS:"
  echo ""

  local services=("api:8080" "ai-service:8001" "docs-service:8002" "cnj-service:8003" "frontend:3000")

  for svc in "${services[@]}"; do
    local name="${svc%%:*}"
    local port="${svc##*:}"
    local status
    status=$(curl -sf --max-time 3 "http://localhost:${port}/health" 2>/dev/null && echo "UP" || echo "DOWN")

    if [[ "$status" == "UP" ]]; then
      echo -e "  ${GREEN}●${RESET} ${name} (porta ${port}) — ${GREEN}ONLINE${RESET}"
    else
      echo -e "  ${RED}●${RESET} ${name} (porta ${port}) — ${RED}OFFLINE${RESET}"
    fi
  done

  echo ""
  # Docker stats resumido
  docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
}

# ============================================================
# BACKUP — Backup automático do banco
# ============================================================
cmd_backup() {
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_file="${LEXOS_DIR}/backups/lexos_${timestamp}.sql.gz"

  log "Iniciando backup: ${backup_file}"

  docker compose exec -T postgres pg_dump \
    -U lexos \
    --no-password \
    --verbose \
    --format=plain \
    lexos_db \
    2>/dev/null \
    | gzip > "$backup_file"

  local size
  size=$(du -sh "$backup_file" | cut -f1)
  success "Backup concluído: ${backup_file} (${size})"

  # Limpar backups com mais de 30 dias
  find "${LEXOS_DIR}/backups" -name "*.sql.gz" -mtime +30 -delete
  success "Backups antigos removidos"
}

# ============================================================
# LOGS — Ver logs dos serviços
# ============================================================
cmd_logs() {
  local service="${1:-api}"
  local lines="${2:-100}"
  docker compose logs --tail="$lines" --follow "$service" 2>/dev/null
}

# ============================================================
# RESTORE — Restaurar backup
# ============================================================
cmd_restore() {
  local backup_file="${1:-}"
  [[ -z "$backup_file" ]] && die "Uso: lexos.sh restore <arquivo.sql.gz>"
  [[ -f "$backup_file" ]] || die "Arquivo não encontrado: $backup_file"

  warn "ATENÇÃO: Isso vai APAGAR todos os dados atuais!"
  read -rp "Digite 'CONFIRMAR' para continuar: " confirm
  [[ "$confirm" == "CONFIRMAR" ]] || die "Operação cancelada"

  log "Restaurando backup..."
  gunzip -c "$backup_file" | docker compose exec -T postgres psql \
    -U lexos -d lexos_db -v ON_ERROR_STOP=1
  success "Restore concluído"
}

# ============================================================
# SCALE — Escalar serviço horizontalmente
# ============================================================
cmd_scale() {
  local service="${1:-api}"
  local replicas="${2:-2}"
  log "Escalando ${service} para ${replicas} réplicas..."
  docker compose up -d --scale "${service}=${replicas}" "$service"
  success "${service} escalado para ${replicas} réplicas"
}

# ============================================================
# HELPER: Aguardar serviço subir
# ============================================================
aguardar_servico() {
  local servico="$1"
  local timeout="${2:-30}"
  local count=0

  while ! docker compose exec -T "$servico" true 2>/dev/null; do
    sleep 1
    count=$((count + 1))
    [[ $count -ge $timeout ]] && die "Timeout aguardando ${servico}"
  done
  success "${servico} pronto"
}

# ============================================================
# MAIN — Dispatcher de comandos
# ============================================================
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    setup)   cmd_setup   "$@" ;;
    deploy)  cmd_deploy  "$@" ;;
    migrate) cmd_migrate "$@" ;;
    status)  cmd_status  "$@" ;;
    backup)  cmd_backup  "$@" ;;
    restore) cmd_restore "$@" ;;
    logs)    cmd_logs    "$@" ;;
    scale)   cmd_scale   "$@" ;;
    stop)    docker compose down ;;
    restart) docker compose restart "${1:-}" ;;
    *)
      echo ""
      echo -e "  ${BOLD}LexOS v${LEXOS_VERSION}${RESET} — CLI de Operações"
      echo ""
      echo "  Uso: lexos.sh <comando> [opções]"
      echo ""
      echo "  Comandos:"
      echo "    setup              Configura o ambiente pela primeira vez"
      echo "    deploy [env]       Faz deploy completo de todos os serviços"
      echo "    migrate            Executa migrations do banco de dados"
      echo "    status             Verifica saúde de todos os serviços"
      echo "    backup             Faz backup do banco de dados"
      echo "    restore <arquivo>  Restaura um backup"
      echo "    logs [serviço]     Exibe logs em tempo real"
      echo "    scale [svc] [n]    Escala horizontalmente um serviço"
      echo "    stop               Para todos os serviços"
      echo "    restart [serviço]  Reinicia serviço(s)"
      echo ""
      ;;
  esac
}

main "$@"
