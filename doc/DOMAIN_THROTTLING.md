# Domain Throttling - Gestione Rate Limiting SMTP

## Panoramica

Il sistema di Domain Throttling gestisce automaticamente il rate limiting quando un server SMTP destinatario risponde con un errore 451 "too many messages, slow down". Invece di ritentare immediatamente l'invio (causando potenzialmente ulteriori rifiuti e danni alla reputazione IP), il sistema rallenta intelligentemente l'invio per tutti i messaggi destinati allo stesso dominio.

## Problema Risolto

Quando si invia un grande volume di email a un singolo dominio, il server destinatario può rispondere con:

```
451 4.7.1 Too many messages, slow down
451 Rate limit exceeded, try again in 5 minutes
451 Too many connections from your IP
```

Senza gestione del throttling:
- ❌ Ogni messaggio viene ritentato individualmente
- ❌ I retry multipli peggiorano la situazione
- ❌ Rischio di blacklisting dell'IP
- ❌ Spreco di risorse

Con Domain Throttling:
- ✅ Un solo messaggio riceve l'errore 451
- ✅ Tutti i messaggi per lo stesso dominio vengono ritardati
- ✅ La reputazione IP viene preservata
- ✅ Efficienza delle risorse migliorata

## Architettura

### Componenti

```
┌─────────────────────────────────────────────────────────────────┐
│                    OutgoingMessageProcessor                      │
│  ┌─────────────────────┐    ┌──────────────────────────────┐   │
│  │ skip_if_domain_     │    │ apply_domain_throttle_       │   │
│  │ throttled           │    │ if_required                  │   │
│  │ (prima dell'invio)  │    │ (dopo errore 451)            │   │
│  └──────────┬──────────┘    └──────────────┬───────────────┘   │
└─────────────┼───────────────────────────────┼───────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      DomainThrottle Model                        │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────────────┐   │
│  │ .throttled? │  │ .apply()   │  │ .cleanup_expired       │   │
│  └─────────────┘  └────────────┘  └────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Database: domain_throttles                    │
│  ┌──────────┬────────────┬─────────────────┬────────────────┐  │
│  │server_id │ domain     │ throttled_until │ reason         │  │
│  ├──────────┼────────────┼─────────────────┼────────────────┤  │
│  │ 1        │ gmail.com  │ 2025-12-10 13:00│ 451 too many...│  │
│  │ 1        │ yahoo.com  │ 2025-12-10 12:55│ Rate limit...  │  │
│  └──────────┴────────────┴─────────────────┴────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Flusso di Esecuzione

```
1. Messaggio in coda
        │
        ▼
2. Processor acquisisce lock
        │
        ▼
3. Check: dominio in throttle? ──YES──► Imposta retry_after, rilascia lock
        │
        NO
        ▼
4. Procede con invio SMTP
        │
        ▼
5. Risposta dal server destinatario
        │
   ┌────┴────┐
   │         │
 Successo   Errore 451
   │         │
   ▼         ▼
6. Fine    Crea DomainThrottle
           Aggiorna tutti i queued_messages 
           per lo stesso dominio
           Imposta retry_after
```

## Struttura Database

### Tabella: domain_throttles

| Campo | Tipo | Descrizione |
|-------|------|-------------|
| `id` | integer | Primary key |
| `server_id` | integer | FK verso servers (throttle per-server) |
| `domain` | string | Dominio destinatario (normalizzato lowercase) |
| `throttled_until` | datetime | Timestamp fino a quando il dominio è in throttle |
| `reason` | string | Messaggio di errore originale del server SMTP |
| `created_at` | datetime | Timestamp creazione |
| `updated_at` | datetime | Timestamp ultimo aggiornamento |

**Indici:**
- `UNIQUE (server_id, domain)` - Un solo throttle per dominio per server
- `INDEX (throttled_until)` - Per query di pulizia efficienti

## Configurazione

### Costanti (DomainThrottle)

```ruby
# Durata default del throttle (5 minuti)
DEFAULT_THROTTLE_DURATION = 300

# Durata massima del throttle (30 minuti)
MAX_THROTTLE_DURATION = 1800
```

### Pattern di Rilevamento

Il sistema rileva automaticamente i seguenti pattern negli errori SMTP:

- `451 ... too many` / `too many messages` / `too many connections`
- `rate limit` / `rate limited`
- `slow down`
- `temporarily deferred` / `temporarily rejected` con menzione di rate/limit

### Estrazione Durata

Se il messaggio di errore contiene un tempo specifico, viene estratto:

```
"Try again in 30 seconds" → 40 secondi (30 + 10 buffer)
"Retry in 5 minutes" → 310 secondi (5*60 + 10 buffer)
"Try again in 2 hours" → 1800 secondi (capped a MAX)
```

## API del Modello DomainThrottle

### Metodi di Classe

```ruby
# Verifica se un dominio è in throttle
DomainThrottle.throttled?(server, "gmail.com")
# => DomainThrottle instance o nil

# Applica/estende un throttle
DomainThrottle.apply(
  server, 
  "gmail.com",
  duration: 300,           # opzionale, default 300
  reason: "451 too many"   # opzionale
)
# => DomainThrottle instance

# Pulisce i throttle scaduti
DomainThrottle.cleanup_expired
# => numero di record eliminati
```

### Scopes

```ruby
# Throttle attivi
DomainThrottle.active

# Throttle scaduti
DomainThrottle.expired
```

### Metodi di Istanza

```ruby
throttle.active?           # => true/false
throttle.remaining_seconds # => Integer (secondi rimanenti)
```

## Scheduled Task

Il task `PruneDomainThrottlesScheduledTask` viene eseguito ogni **15 minuti** per rimuovere i record di throttle scaduti dal database.

## Granularità

Il throttling è applicato **per-server**, il che significa che:

- Se il Server A riceve un 451 da `gmail.com`, solo i messaggi del Server A verso `gmail.com` vengono ritardati
- Il Server B può continuare a inviare a `gmail.com` normalmente
- Questo evita che un server sovraccarico impatti altri server nell'installazione

## Comportamento Batch

Quando viene rilevato un errore 451:

1. Viene creato/aggiornato il `DomainThrottle` per il dominio
2. **Tutti** i `queued_messages` dello stesso server con lo stesso dominio vengono aggiornati in batch con `retry_after`
3. Questo previene che altri worker tentino di inviare mentre il dominio è in throttle

```ruby
# Query di aggiornamento batch
QueuedMessage.where(server_id: server_id, domain: domain)
             .where("retry_after IS NULL OR retry_after < ?", throttled_until)
             .update_all(retry_after: throttled_until + 10.seconds)
```

## Backoff Esponenziale

Se un dominio riceve ripetuti errori 451, la durata del throttle aumenta progressivamente:

1. Primo 451: 5 minuti
2. Secondo 451 (mentre ancora in throttle): tempo rimanente × 2 (max 30 minuti)

Questo aiuta a gestire situazioni in cui il server destinatario ha bisogno di più tempo per recuperare.

## Esempi di Utilizzo

### Verifica Manuale dello Stato

```ruby
# In Rails console
server = Server.find(1)

# Verifica throttle attivi
server.domain_throttles.active

# Verifica se un dominio specifico è in throttle
DomainThrottle.throttled?(server, "gmail.com")

# Rimuovi manualmente un throttle
DomainThrottle.find_by(server: server, domain: "gmail.com")&.destroy
```

### Monitoraggio

```ruby
# Conteggio throttle attivi per server
Server.all.each do |s|
  count = s.domain_throttles.active.count
  puts "#{s.name}: #{count} domini in throttle" if count > 0
end

# Domini più frequentemente in throttle
DomainThrottle.group(:domain)
              .order('count_id DESC')
              .count(:id)
              .first(10)
```

## File Implementati

| File | Descrizione |
|------|-------------|
| `db/migrate/20251210000001_create_domain_throttles.rb` | Migration database |
| `app/models/domain_throttle.rb` | Modello ActiveRecord |
| `app/models/server.rb` | Aggiunta associazione `has_many :domain_throttles` |
| `app/senders/send_result.rb` | Nuovi attributi throttle |
| `app/senders/smtp_sender.rb` | Rilevamento errori 451 |
| `app/lib/message_dequeuer/outgoing_message_processor.rb` | Logica di throttling |
| `app/scheduled_tasks/prune_domain_throttles_scheduled_task.rb` | Pulizia periodica |
| `app/controllers/messages_controller.rb` | Actions per UI (`throttled_domains`, `remove_throttled_domain`) |
| `app/views/messages/throttled_domains.html.haml` | Vista lista domini in throttle |
| `app/views/messages/_header.html.haml` | Link nel menu di navigazione |
| `config/routes.rb` | Routes per le nuove pagine |

## Interfaccia Web

### Accesso

La pagina "Throttled Domains" è accessibile dalla sezione **Messages** di ogni server:

```
Organization → Server → Messages → Throttled Domains
```

### Funzionalità

La pagina mostra una tabella con:

| Colonna | Descrizione |
|---------|-------------|
| **Domain** | Il dominio destinatario in throttle |
| **Throttled Until** | Data e ora di scadenza del throttle |
| **Time Remaining** | Tempo rimanente in formato leggibile (es. "4m 30s") |
| **Reason** | Il messaggio di errore originale del server SMTP |
| **Actions** | Pulsante per rimuovere manualmente il throttle |

### Rimozione Manuale

È possibile rimuovere un throttle manualmente cliccando il pulsante "Remove". Questo è utile quando:

- Il problema sul server remoto è stato risolto
- Si vuole forzare un nuovo tentativo di invio
- Il throttle è stato applicato erroneamente

**Attenzione:** Rimuovere un throttle farà sì che i messaggi in coda vengano inviati immediatamente. Se il server remoto sta ancora limitando il rate, potrebbe risultare in ulteriori errori 451.

### Screenshot Concettuale

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Messages │ Outgoing │ Incoming │ Queue │ Held │ Send │ Suppressions │ [Throttled] │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Throttled Domains                                                          │
│                                                                             │
│  These domains are currently throttled due to rate limiting responses...   │
│                                                                             │
│  ┌────────────┬─────────────────────┬───────────┬──────────────┬─────────┐ │
│  │ Domain     │ Throttled Until     │ Remaining │ Reason       │ Actions │ │
│  ├────────────┼─────────────────────┼───────────┼──────────────┼─────────┤ │
│  │ gmail.com  │ Dec 10, 2025 14:30  │ 4m 30s    │ 451 too many │ Remove  │ │
│  │ yahoo.com  │ Dec 10, 2025 14:45  │ 19m 15s   │ Rate limit...│ Remove  │ │
│  └────────────┴─────────────────────┴───────────┴──────────────┴─────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Test

I test sono disponibili in:

- `spec/models/domain_throttle_spec.rb` - Test del modello
- `spec/scheduled_tasks/prune_domain_throttles_scheduled_task_spec.rb` - Test scheduled task
- `spec/senders/smtp_sender_spec.rb` - Test rilevamento throttle

Eseguire i test:

```bash
bundle exec rspec spec/models/domain_throttle_spec.rb \
                  spec/scheduled_tasks/prune_domain_throttles_scheduled_task_spec.rb \
                  spec/senders/smtp_sender_spec.rb
```

## Migrazione

Per attivare la funzionalità:

```bash
bundle exec rails db:migrate
```

La funzionalità è attiva immediatamente dopo la migrazione, senza necessità di configurazione aggiuntiva.

