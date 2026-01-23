# Verifica Inizializzazione Database - Guida Rapida

## Come Verificare che Tutte le Migration Vengano Eseguite

### 1. Verifica Automatica con Test

Esegui il test di integrità dello schema:

```bash
bundle exec rspec spec/lib/database_schema_integrity_spec.rb
```

Questo test verifica:
- ✅ La versione dello schema corrisponde all'ultima migration
- ✅ Tutti i campi delle migration recenti sono presenti nel database
- ✅ Tutte le migration sono state applicate

### 2. Verifica Manuale della Versione

```bash
# Controlla la versione corrente dello schema
bundle exec rails runner "puts ActiveRecord::Base.connection.migration_context.current_version"

# Dovrebbe restituire: 20251109101656
```

### 3. Verifica Stato Migration

```bash
# Elenca lo stato di tutte le migration
bundle exec rake db:migrate:status

# Output atteso: tutte le migration devono avere status "up"
```

### 4. Inizializzazione Nuovo Database

Per inizializzare un nuovo database da zero:

```bash
# Metodo 1: Usando il comando postal
bin/postal initialize

# Metodo 2: Usando rake direttamente
bundle exec rake db:create postal:update
```

**Cosa succede:**
1. Viene creato il database se non esiste
2. Il task `postal:update` verifica se ci sono migration già applicate
3. Se NO → carica lo schema completo da `db/schema.rb` (più veloce)
4. Se SI → applica solo le migration mancanti con `db:migrate`

### 5. Aggiornamento Database Esistente

Per aggiornare un database esistente con nuove migration:

```bash
# Metodo 1: Usando il comando postal
bin/postal update
# oppure
bin/postal upgrade

# Metodo 2: Usando rake direttamente
bundle exec rake postal:update
```

**Cosa succede:**
1. Verifica quali migration sono già state applicate
2. Applica solo le migration nuove/mancanti
3. Aggiorna anche i database dei messaggi di ogni server

### 6. Verifica dei Campi nel Database

#### Verifica campo Truemail

```bash
bundle exec rails runner "puts Server.column_names.include?('truemail_enabled')"
# Output atteso: true
```

#### Verifica campi DMARC

```bash
bundle exec rails runner "puts Domain.column_names.include?('dmarc_status') && Domain.column_names.include?('dmarc_error')"
# Output atteso: true
```

#### Verifica campi MTA-STS e TLS-RPT

```bash
bundle exec rails runner "puts Domain.column_names.select { |c| c.start_with?('mta_sts_', 'tls_rpt_') }"
# Output atteso: ["mta_sts_enabled", "mta_sts_mode", "mta_sts_max_age", "mta_sts_mx_patterns", "mta_sts_status", "mta_sts_error", "tls_rpt_enabled", "tls_rpt_email", "tls_rpt_status", "tls_rpt_error"]
```

## Troubleshooting

### Problema: La versione dello schema non corrisponde all'ultima migration

**Soluzione:**
```bash
# 1. Verifica quali migration mancano
bundle exec rake db:migrate:status

# 2. Applica le migration mancanti
bundle exec rake db:migrate

# 3. Verifica che lo schema sia stato aggiornato
bundle exec rails runner "puts ActiveRecord::Base.connection.migration_context.current_version"
```

### Problema: Il database non esiste

**Soluzione:**
```bash
# Inizializza il database da zero
bin/postal initialize
```

### Problema: Migration fallita

**Soluzione:**
```bash
# 1. Verifica l'errore nei log
tail -f log/development.log

# 2. Fai rollback dell'ultima migration
bundle exec rake db:rollback

# 3. Correggi il problema nella migration

# 4. Riapplica la migration
bundle exec rake db:migrate
```

## File Importanti

- **`db/schema.rb`**: Schema del database (NON modificare manualmente!)
- **`db/migrate/*.rb`**: File delle migration (in ordine cronologico)
- **`lib/tasks/postal.rake`**: Task custom di Postal, include `postal:update`
- **`config/database.yml`**: Configurazione del database

## Best Practices

1. **NON modificare mai `db/schema.rb` direttamente**
   - Questo file è auto-generato da Rails
   - Le modifiche verranno sovrascritte

2. **Creare sempre migration per cambiamenti al database**
   ```bash
   bundle exec rails generate migration AddFieldToTable field:type
   ```

3. **Testare le migration in development prima del deploy**
   ```bash
   # Applica la migration
   bundle exec rake db:migrate
   
   # Testa il rollback
   bundle exec rake db:rollback
   
   # Riapplica
   bundle exec rake db:migrate
   ```

4. **Verificare sempre lo stato dopo deploy**
   ```bash
   bin/postal update
   bundle exec rake db:migrate:status
   ```

## Riepilogo Migration Recenti

| Timestamp | Nome | Descrizione |
|-----------|------|-------------|
| 20251109101656 | add_dmarc_fields_to_domains | Aggiunge campi DMARC validation |
| 20251107000001 | add_mta_sts_and_tls_rpt_to_domains | Aggiunge supporto MTA-STS e TLS-RPT |
| 20250915065902 | add_priority_to_server | Aggiunge priorità ai server |
| 20250716102600 | add_truemail_enabled_to_servers | **Integrazione Truemail** |

## Conclusione

✅ Il processo di inizializzazione del database di Postal è configurato correttamente per eseguire tutte le migration.

✅ Lo schema attuale (versione: 20251109101656) include tutte le migration disponibili.

✅ Il sistema usa un approccio intelligente: carica lo schema completo per nuovi database, applica solo le migration mancanti per database esistenti.

