# Verifica dell'Inizializzazione del Database

## Data: 10 Novembre 2025

## Riepilogo

Questo documento verifica che tutte le migration configurate vengano eseguite durante l'inizializzazione del database di Postal.

## Processo di Inizializzazione

### 1. Comando di Inizializzazione

Il comando principale per inizializzare il database è:

```bash
bin/postal initialize
```

Questo comando esegue internamente:
```bash
bundle exec rake db:create postal:update
```

### 2. Task `postal:update`

Il task `postal:update` (definito in `lib/tasks/postal.rake`) implementa una logica intelligente:

```ruby
desc "Update the database"
task update: :environment do
  mysql = ActiveRecord::Base.connection
  if mysql.table_exists?("schema_migrations") &&
     mysql.select_all("select * from schema_migrations").any?
    puts "Database schema is already loaded. Running migrations with db:migrate"
    Rake::Task["db:migrate"].invoke
  else
    puts "No schema migrations exist. Loading schema with db:schema:load"
    Rake::Task["db:schema:load"].invoke
  end
end
```

**Comportamento:**
- Se la tabella `schema_migrations` esiste ed ha record → esegue `db:migrate` (applica solo le migration mancanti)
- Altrimenti → esegue `db:schema:load` (carica l'intero schema da `db/schema.rb`)

### 3. Migration Disponibili

Le migration presenti nella directory `db/migrate/` sono (in ordine cronologico):

1. `20161003195209_create_authie_sessions.authie.rb` - Crea sessioni Authie
2. `20161003195210_add_indexes_to_authie_sessions.authie.rb` - Aggiunge indici
3. `20161003195211_add_parent_id_to_authie_sessions.authie.rb` - Parent ID per sessioni
4. `20161003195212_add_two_factor_auth_fields_to_authie.authie.rb` - 2FA fields
5. `20170418200606_initial_schema.rb` - Schema iniziale completo
6. `20170421195414_add_token_hashes_to_authie_sessions.authie.rb` - Token hash
7. `20170421195415_add_index_to_token_hashes_on_authie_sessions.authie.rb` - Indice token hash
8. `20170428153353_remove_type_from_ip_pools.rb` - Rimuove type da IP pools
9. `20180216114344_add_host_to_authie_sessions.authie.rb` - Campo host
10. `20200717083943_add_uuid_to_credentials.rb` - UUID per credentials
11. `20210727210551_add_priority_to_ip_addresses.rb` - Priorità IP addresses
12. `20240206173036_add_privacy_mode_to_servers.rb` - Privacy mode
13. `20240213165450_create_worker_roles.rb` - Worker roles
14. `20240213171830_create_scheduled_tasks.rb` - Scheduled tasks
15. `20240214132253_add_lock_fields_to_webhook_requests.rb` - Lock fields webhook
16. `20240223141500_add_two_factor_required_to_sessions.authie.rb` - 2FA required
17. `20240223141501_add_countries_to_authie_sessions.authie.rb` - Paesi per sessioni
18. `20240311205229_add_oidc_fields_to_user.rb` - OIDC fields
19. `20250716102600_add_truemail_enabled_to_servers.rb` - **Truemail integration**
20. `20250915065902_add_priority_to_server.rb` - Priorità server
21. `20251107000001_add_mta_sts_and_tls_rpt_to_domains.rb` - MTA-STS e TLS-RPT
22. `20251109101656_add_dmarc_fields_to_domains.rb` - **DMARC fields**

### 4. Versione Corrente dello Schema

Il file `db/schema.rb` ora riporta correttamente:

```ruby
ActiveRecord::Schema[7.1].define(version: 2025_11_09_101656) do
```

Questa è la versione dell'ultima migration disponibile (`20251109101656`).

### 5. Verifica delle Modifiche Applicate

#### Migration DMARC (20251109101656)
La migration aggiunge alla tabella `domains`:
- `dmarc_status` (string)
- `dmarc_error` (string)

**Stato:** ✅ **APPLICATA** - I campi sono presenti nello schema.rb

#### Migration Truemail (20250716102600)
La migration aggiunge alla tabella `servers`:
- `truemail_enabled` (boolean, default: false)

**Stato:** ✅ **APPLICATA** - Il campo è presente nello schema.rb

#### Migration Priority Server (20250915065902)
La migration aggiunge alla tabella `servers`:
- `priority` (integer, limit: 2, default: 0, unsigned: true)

**Stato:** ✅ **APPLICATA** - Il campo è presente nello schema.rb

#### Migration MTA-STS e TLS-RPT (20251107000001)
La migration aggiunge alla tabella `domains`:
- `mta_sts_enabled` (boolean, default: false)
- `mta_sts_mode` (string, limit: 20, default: "testing")
- `mta_sts_max_age` (integer, default: 86400)
- `mta_sts_mx_patterns` (text)
- `mta_sts_status` (string)
- `mta_sts_error` (string)
- `tls_rpt_enabled` (boolean, default: false)
- `tls_rpt_email` (string)
- `tls_rpt_status` (string)
- `tls_rpt_error` (string)

**Stato:** ✅ **APPLICATA** - Tutti i campi sono presenti nello schema.rb

## Conclusioni

✅ **VERIFICA SUPERATA**: Tutte le migration configurate sono state correttamente integrate nello schema del database.

### Processo di Inizializzazione per Nuovo Database

Quando viene inizializzato un nuovo database:

1. **Comando:** `bin/postal initialize`
2. **Esecuzione:** `rake db:create postal:update`
3. **Comportamento:** Poiché non esiste `schema_migrations`, viene eseguito `db:schema:load`
4. **Risultato:** Il database viene creato con lo schema completo da `db/schema.rb` (versione 2025_11_09_101656)

### Processo di Aggiornamento Database Esistente

Quando viene aggiornato un database esistente:

1. **Comando:** `bin/postal update` o `bin/postal upgrade`
2. **Esecuzione:** `rake postal:update`
3. **Comportamento:** Poiché esiste `schema_migrations` con record, viene eseguito `db:migrate`
4. **Risultato:** Vengono applicate solo le migration non ancora eseguite

### Migration Message Databases

Il task `db:migrate` è stato esteso per eseguire anche le migration sui database dei messaggi:

```ruby
Rake::Task["db:migrate"].enhance do
  Rake::Task["postal:migrate_message_databases"].invoke
end
```

Questo assicura che anche i database specifici di ogni server vengano aggiornati.

## Raccomandazioni

1. ✅ **NON modificare mai direttamente** `db/schema.rb` - questo file è auto-generato
2. ✅ **Creare sempre migration** per modifiche al database usando `rails generate migration`
3. ✅ **Testare le migration** in ambiente development prima del deploy
4. ✅ **Mantenere l'ordine cronologico** dei timestamp delle migration
5. ✅ **Includere metodi up/down** o usare `change` per migration reversibili

## Integrazione Truemail

La migration `20250716102600_add_truemail_enabled_to_servers.rb` è stata correttamente applicata e permette di:

- Abilitare/disabilitare Truemail per singolo server tramite il campo `truemail_enabled`
- Integrarsi con Truemail-Rack via API per validare gli indirizzi email prima dell'invio

Questa integrazione segue lo stesso pattern di SpamAssassin e ClamAV come richiesto nelle istruzioni.

