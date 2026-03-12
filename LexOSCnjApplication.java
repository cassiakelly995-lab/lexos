// ============================================================
// LexOS — Integração com CNJ e Tribunais Brasileiros
// Linguagem: Java 21
// Framework: Spring Boot 3.2 + WebFlux (reativo)
// Função: Crawler de processos, sincronização CNJ, PJe
// ============================================================

package br.com.lexos.cnj;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import io.lettuce.core.RedisClient;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.api.sync.RedisCommands;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.*;

// ============================================================
// APPLICATION
// ============================================================

@SpringBootApplication
@EnableScheduling
public class LexOSCnjApplication {
    public static void main(String[] args) {
        SpringApplication.run(LexOSCnjApplication.class, args);
    }
}

// ============================================================
// MODELOS CNJ
// ============================================================

@JsonIgnoreProperties(ignoreUnknown = true)
record ProcessoCNJ(
    @JsonProperty("numero")         String numero,
    @JsonProperty("tribunal")       String tribunal,
    @JsonProperty("classe")         String classe,
    @JsonProperty("assunto")        String assunto,
    @JsonProperty("dataAjuizamento") String dataAjuizamento,
    @JsonProperty("movimentos")     List<MovimentoCNJ> movimentos,
    @JsonProperty("partes")         List<ParteCNJ> partes
) {}

@JsonIgnoreProperties(ignoreUnknown = true)
record MovimentoCNJ(
    @JsonProperty("codigo")      String codigo,
    @JsonProperty("nome")        String nome,
    @JsonProperty("dataHora")    String dataHora,
    @JsonProperty("complemento") String complemento
) {}

@JsonIgnoreProperties(ignoreUnknown = true)
record ParteCNJ(
    @JsonProperty("tipo")   String tipo,   // AUTOR, REU, ADVOGADO
    @JsonProperty("nome")   String nome,
    @JsonProperty("cpfCnpj") String cpfCnpj
) {}

@JsonIgnoreProperties(ignoreUnknown = true)
record ResultadoPesquisa(
    @JsonProperty("hits")  List<ProcessoCNJ> hits,
    @JsonProperty("total") long total
) {}

record SyncRequest(String processoId, String numeroCnj, String tribunal) {}
record SyncResult(String processoId, boolean sucesso, String mensagem,
                  int movimentacoesNovas, LocalDateTime sincronizadoEm) {}

// ============================================================
// CONFIGURAÇÃO WEBCLIENT
// ============================================================

@Configuration
class WebClientConfig {

    @Value("${cnj.api.url:https://api.cnj.jus.br/pje-cloud/api/v1}")
    private String cnjApiUrl;

    @Value("${cnj.api.key:}")
    private String cnjApiKey;

    @Bean("cnjWebClient")
    public WebClient cnjWebClient() {
        return WebClient.builder()
            .baseUrl(cnjApiUrl)
            .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
            .defaultHeader("Authorization", "Bearer " + cnjApiKey)
            .codecs(c -> c.defaultCodecs().maxInMemorySize(10 * 1024 * 1024))
            .build();
    }

    @Bean("tjspWebClient")
    public WebClient tjspWebClient() {
        return WebClient.builder()
            .baseUrl("https://esaj.tjsp.jus.br/cpopg")
            .defaultHeader(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE)
            .build();
    }
}

// ============================================================
// SERVIÇO CNJ
// ============================================================

@Service
class CNJService {

    private static final Logger log = LoggerFactory.getLogger(CNJService.class);

    private final WebClient cnjClient;
    private final JdbcTemplate jdbc;

    @Autowired
    CNJService(@Qualifier("cnjWebClient") WebClient cnjClient, JdbcTemplate jdbc) {
        this.cnjClient = cnjClient;
        this.jdbc = jdbc;
    }

    /**
     * Busca processo pelo número CNJ no DataJud (API oficial CNJ)
     */
    public Mono<ProcessoCNJ> buscarProcesso(String numeroCnj, String tribunal) {
        log.info("Consultando CNJ: {} no tribunal {}", numeroCnj, tribunal);

        return cnjClient.get()
            .uri("/processos/{numero}", numeroCnj)
            .header("X-Tribunal", tribunal.toUpperCase())
            .retrieve()
            .bodyToMono(ProcessoCNJ.class)
            .doOnSuccess(p -> log.info("Processo {} encontrado com {} movimentos",
                numeroCnj, p.movimentos() != null ? p.movimentos().size() : 0))
            .doOnError(e -> log.error("Erro ao consultar CNJ: {}", e.getMessage()))
            .onErrorReturn(new ProcessoCNJ(numeroCnj, tribunal, "", "", null, List.of(), List.of()));
    }

    /**
     * Pesquisa por texto livre na base do DataJud
     */
    public Mono<ResultadoPesquisa> pesquisar(String query, String tribunal, int pagina) {
        return cnjClient.get()
            .uri(uriBuilder -> uriBuilder
                .path("/processos")
                .queryParam("q", query)
                .queryParam("tribunal", tribunal)
                .queryParam("page", pagina)
                .queryParam("size", 20)
                .build())
            .retrieve()
            .bodyToMono(ResultadoPesquisa.class)
            .onErrorReturn(new ResultadoPesquisa(List.of(), 0));
    }

    /**
     * Sincroniza processo do banco LexOS com dados do CNJ
     */
    public SyncResult sincronizar(String processoId) {
        // 1. Buscar dados do processo no banco
        Map<String, Object> processo;
        try {
            processo = jdbc.queryForMap(
                "SELECT numero_cnj, tribunal_id, escritorio_id FROM processos WHERE id = ?::uuid",
                processoId
            );
        } catch (Exception e) {
            return new SyncResult(processoId, false, "Processo não encontrado no banco", 0, LocalDateTime.now());
        }

        String numeroCnj = (String) processo.get("numero_cnj");
        if (numeroCnj == null || numeroCnj.isBlank()) {
            return new SyncResult(processoId, false, "Processo sem número CNJ", 0, LocalDateTime.now());
        }

        // 2. Buscar tribunal
        String tribunal = buscarSiglaTribunal((UUID) processo.get("tribunal_id"));

        // 3. Consultar API CNJ
        ProcessoCNJ dadosCNJ = buscarProcesso(numeroCnj, tribunal).block();
        if (dadosCNJ == null || dadosCNJ.movimentos().isEmpty()) {
            return new SyncResult(processoId, false, "Nenhum dado retornado pelo CNJ", 0, LocalDateTime.now());
        }

        // 4. Inserir novas movimentações (ignora duplicatas)
        int novas = 0;
        for (MovimentoCNJ mov : dadosCNJ.movimentos()) {
            try {
                jdbc.update(
                    """INSERT INTO movimentacoes
                       (id, processo_id, tipo, descricao, data_ocorrencia, origem)
                       VALUES (gen_random_uuid(), ?::uuid, 'outro', ?, ?::timestamptz, 'cnj_sync')
                       ON CONFLICT DO NOTHING""",
                    processoId,
                    mov.nome() + (mov.complemento() != null ? ": " + mov.complemento() : ""),
                    mov.dataHora()
                );
                novas++;
            } catch (Exception ignored) {}
        }

        // 5. Atualizar timestamp de sincronização
        jdbc.update(
            "UPDATE processos SET cnj_sincronizado_em = NOW() WHERE id = ?::uuid",
            processoId
        );

        log.info("Processo {} sincronizado: {} movimentações novas", processoId, novas);
        return new SyncResult(processoId, true, "Sincronização concluída", novas, LocalDateTime.now());
    }

    private String buscarSiglaTribunal(UUID tribunalId) {
        if (tribunalId == null) return "TJSP";
        try {
            return jdbc.queryForObject(
                "SELECT sigla FROM tribunais WHERE id = ?", String.class, tribunalId
            );
        } catch (Exception e) {
            return "TJSP";
        }
    }
}

// ============================================================
// WORKER DE FILA (consome queue:cnj_sync do Redis)
// ============================================================

@Service
class CNJQueueWorker {

    private static final Logger log = LoggerFactory.getLogger(CNJQueueWorker.class);

    private final CNJService cnjService;
    private final RedisCommands<String, String> redis;

    @Autowired
    CNJQueueWorker(CNJService cnjService,
                   @Value("${redis.url:redis://localhost:6379}") String redisUrl) {
        this.cnjService = cnjService;
        var client = RedisClient.create(redisUrl);
        StatefulRedisConnection<String, String> conn = client.connect();
        this.redis = conn.sync();
    }

    @Scheduled(fixedDelay = 3000)
    public void processarFila() {
        String processoId = redis.rpoplpush("queue:cnj_sync", "queue:cnj_processing");
        if (processoId != null) {
            log.info("Processando sincronização CNJ: {}", processoId);
            try {
                SyncResult result = cnjService.sincronizar(processoId);
                if (result.sucesso()) {
                    redis.lrem("queue:cnj_processing", 0, processoId);
                    log.info("Sync OK: {} — {} movimentações", processoId, result.movimentacoesNovas());
                } else {
                    redis.lrem("queue:cnj_processing", 0, processoId);
                    redis.lpush("queue:cnj_failed", processoId);
                    log.warn("Sync falhou: {} — {}", processoId, result.mensagem());
                }
            } catch (Exception e) {
                log.error("Erro crítico na sync {}: {}", processoId, e.getMessage());
                redis.lrem("queue:cnj_processing", 0, processoId);
                redis.lpush("queue:cnj_failed", processoId);
            }
        }
    }

    /**
     * Sincronização em lote — todos os processos ativos do escritório
     * Executa toda madrugada às 02:00
     */
    @Scheduled(cron = "0 0 2 * * *")
    public void sincronizacaoNoturna() {
        log.info("Iniciando sincronização noturna CNJ...");
        // Em produção: buscar todos processos ativos e enfileirar
        // jdbc.query("SELECT id FROM processos WHERE status IN ('ativo','urgente')", ...)
        //     .forEach(id -> redis.lpush("queue:cnj_sync", id));
    }
}

// ============================================================
// CONTROLLER REST
// ============================================================

@RestController
@RequestMapping("/api/v1/cnj")
class CNJController {

    private final CNJService cnjService;

    @Autowired
    CNJController(CNJService cnjService) {
        this.cnjService = cnjService;
    }

    @GetMapping("/processo/{numero}")
    public Mono<ProcessoCNJ> consultarProcesso(
        @PathVariable String numero,
        @RequestParam(defaultValue = "TJSP") String tribunal
    ) {
        return cnjService.buscarProcesso(numero, tribunal);
    }

    @PostMapping("/sincronizar/{processoId}")
    public SyncResult sincronizar(@PathVariable String processoId) {
        return cnjService.sincronizar(processoId);
    }

    @GetMapping("/pesquisar")
    public Mono<ResultadoPesquisa> pesquisar(
        @RequestParam String q,
        @RequestParam(defaultValue = "") String tribunal,
        @RequestParam(defaultValue = "0") int pagina
    ) {
        return cnjService.pesquisar(q, tribunal, pagina);
    }

    @GetMapping("/health")
    public Map<String, Object> health() {
        return Map.of(
            "status", "ok",
            "service", "lexos-cnj",
            "tribunaisMonitorados", List.of("TJSP","TJRJ","TRT2","TRT1","STJ","TST","STF"),
            "timestamp", LocalDateTime.now()
        );
    }
}

// ============================================================
// ANOTAÇÃO AUXILIAR (Qualifier)
// ============================================================

import java.lang.annotation.*;
@Target({ElementType.FIELD, ElementType.PARAMETER})
@Retention(RetentionPolicy.RUNTIME)
@Documented
@interface Qualifier { String value(); }
