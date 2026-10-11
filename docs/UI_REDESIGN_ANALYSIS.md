# Analisi per il redesign dell'interfaccia

Data: 11 ottobre 2026. Baseline: `main`, commit `19110e9`, release 0.2.11.

## Obiettivo e perimetro

Migliorare gerarchia, leggibilità e coerenza dell'interfaccia StoryGraph per KOReader mantenendo le funzioni esistenti. Questa analisi prepara il redesign; non introduce modifiche al codice applicativo.

Le osservazioni derivano dal codice e dai test, non da un'ispezione visiva su dispositivo. Dimensioni dello schermo, versione KOReader e modalità di input del dispositivo principale restano da definire prima della verifica del layout.

## Struttura del progetto

Il plugin è scritto in Lua e utilizza i widget nativi di KOReader. Non è una UI web: il redesign riguarda menu, dialoghi, liste e controlli renderizzati sul lettore.

| Area | File principali | Responsabilità |
| --- | --- | --- |
| Integrazione | `main.lua` | Eventi KOReader, azioni dispatcher, evidenziazioni, ciclo di vita e sincronizzazione |
| Menu | `storygraph/lib/ui/hardcover_menu.lua` | Menu principale, stati, recensioni, impostazioni, account e aggiornamenti |
| Progressi e note | `storygraph/lib/ui/journal_dialog.lua`, `update_double_spin_widget.lua` | Nota, data, percentuale/pagina e selettore con conversione locale/edizione |
| Ricerca e collegamento | `storygraph/lib/ui/search_dialog.lua`, `search_menu.lua` | Risultati, metadati, selezione del libro o dell'edizione |
| Rendering liste | `storygraph/vendor/listmenu.lua`, `covermenu.lua` | Impaginazione, copertine, focus e aggiornamento delle immagini |
| Operazioni pendenti | `storygraph/lib/ui/sync_queue_menu.lua` | Stato delle operazioni, anteprima note e recupero manuale |
| Coordinamento dialoghi | `storygraph/lib/ui/dialog_manager.lua` | Conferme, preparazione note e salvataggio delle operazioni |
| Logica applicativa | API, cache, impostazioni, mapper, coda e scheduler in `storygraph/lib/` | Dati, persistenza, rete, retry e regole di sincronizzazione |

I nomi `hardcover_*` sono ereditati dal progetto originario. Rinominare i moduli non è necessario per il redesign.

## Interfaccia attuale e opportunità

### Menu principale e stato del libro

Il menu presenta prima la coda, poi collegamento ed edizione, tracking automatico, stato, salto alla posizione remota, impostazioni e informazioni. Le voci relative al libro dipendono dalla presenza di un documento.

L'azione «Update progress» apre il dialogo unificato progressi/note, ma si trova dentro «Update status», insieme a stati, proprietà e preferiti. La recensione appare nello stesso sottomenu quando lo stato lo consente. La gerarchia rende meno evidente il compito quotidiano di aggiornare la lettura.

Proposta: dare evidenza a progressi/note e organizzare le azioni in gruppi leggibili: lettura, collegamento, sincronizzazione e configurazione. L'eventuale spostamento di un'azione deve mantenere esattamente le condizioni attuali di disponibilità, conferma e aggiornamento cache. Aprire il sottomenu stato oggi avvia anche un caricamento cache: non si può assumere che spostare una voce sia soltanto un cambiamento di layout.

La pressione prolungata sulla voce del libro collegato elimina il collegamento. Questo comportamento deve essere preservato e documentato nella matrice di verifica; sostituirlo o aggiungere una nuova azione richiederebbe una decisione di scope.

### Dialogo progressi e note

Il dialogo deriva da `InputDialog`: campo nota, selettore percentuale/pagine, pulsanti progresso e data. Il titolo iniziale è «StoryGraph: Add note», anche se un invio con testo vuoto rappresenta un aggiornamento del progresso. La tastiera viene aperta alla visualizzazione.

Proposta: un titolo che rappresenti entrambi gli usi, etichette esplicite per progresso e data, spaziature coerenti e una gerarchia chiara tra controlli e testo. Alcune misure sono numeri fissi, altre seguono il ridimensionamento dello schermo; occorre controllarle su risoluzioni diverse.

Preservare apertura della tastiera, testo selezionato, informazioni di posizione, data, cambio unità, conversioni e conferma quando il progresso scelto è inferiore a quello remoto. Ridurre le interazioni o cambiare la gestione della tastiera sarebbe una scelta di comportamento ulteriore.

### Ricerca libri e scelta dell'edizione

I risultati combinano titolo, anno, ISBN, formato, lingua, pubblicazione ed editore. I metadati sono concatenati in righe; nella modalità con copertine il campo di presentazione `authors` viene anche usato per quei dettagli. Esistono due percorsi di rendering: lista con copertine e menu standard in modalità compatibilità.

Proposta: gerarchia stabile tra titolo e dati dell'edizione, separatori leggibili, selezione corrente riconoscibile e gestione dei testi lunghi. Utilizzare soltanto informazioni già disponibili; non aggiungere richieste di rete per decorare le righe. Mantenere entrambi i percorsi di rendering.

Le liste vendor contengono anche gestione immagini, cache e focus: intervenire lì soltanto quando il risultato non è ottenibile nei moduli UI del plugin.

### Sincronizzazione pendente

Ogni operazione mostra nome del file, tipo e stato in una singola etichetta. Gli stati distinguono attesa normale, retry, verifica della consegna, recupero manuale e ricollegamento dell'edizione; esiste anche un avviso globale per le credenziali.

Proposta: rendere distinguibili identità del documento, tipo di aggiornamento e stato, evitando di comprimere tutto sullo stesso piano visivo. Preservare l'ordine fornito dalla coda e tutte le scelte esistenti.

«In attesa di verifica» non equivale a «da reinviare». Le conferme per dichiarare una nota già presente o autorizzarne il reinvio sono parte della protezione contro i duplicati e devono mantenere il significato attuale.

### Recensioni e impostazioni

La recensione contiene valutazione, moods, ritmo, caratteristiche dei personaggi, temi, pensieri e azioni di salvataggio/annullamento. Le impostazioni combinano collegamento automatico, tracking, Wi-Fi, conferme, compatibilità, note, account e aggiornamenti.

Proposta: raggruppamenti e separatori coerenti, nomenclatura uniforme e maggiore leggibilità dei valori. Mantenere campi, opzioni, valori predefiniti, intervalli e momenti di salvataggio. Non sostituire l'autenticazione tramite cookie né riprogettare la logica recensioni.

## Direzione consigliata

Un redesign incrementale con widget KOReader esistenti è il percorso con minore superficie di regressione. La proposta visiva privilegia contrasto, tipografia, spaziatura e bordi; non dipende dal colore per comunicare stati. Evitare animazioni e caricamenti aggiuntivi.

Un pannello completamente personalizzato darebbe più libertà grafica, ma richiederebbe più lavoro su focus, tastiera, gesti, ridisegno dello schermo e compatibilità. Non è necessario come punto di partenza.

## Vincoli funzionali

- Mantenere callback, eventi dispatcher, azioni delle evidenziazioni e disponibilità per stato del libro.
- Mantenere API, payload, unità, arrotondamenti e mapping delle pagine.
- Mantenere schema della coda, persistenza, ordine, retry e verifiche della consegna.
- Mantenere comportamento offline, Wi-Fi automatico e gestione sospensione/ripresa.
- Mantenere impostazioni e blocchi versione, incluse le eccezioni già previste.
- Mantenere conferme, recupero manuale e distinzione tra salvataggio locale e consegna remota.
- Non introdurre chiamate di rete aggiuntive all'apertura delle schermate.

Il codice UI non è separato completamente dalla logica: `hardcover_menu.lua` contiene mutazioni API, `journal_dialog.lua` conversioni e controlli, `dialog_manager.lua` costruzione e salvataggio delle operazioni. Non serve un refactoring generale; ogni intervento deve distinguere presentazione e comportamento nel punto modificato.

## Sequenza di lavoro e verifica

1. Definire layout di menu, dialogo progressi/note e ricerca → verificare che ogni azione attuale abbia una destinazione e le stesse condizioni di disponibilità.
2. Implementare una schermata alla volta nei moduli UI → verificare con `scripts/test.sh` e controllare il diff per evitare modifiche alla logica.
3. Verificare i confini modificati → controllare callback, abilitazione delle azioni e dati inviati; aggiungere test mirati dove la nuova composizione rischia di cambiare queste proprietà.
4. Verificare la resa su KOReader → testo lungo, copertine mancanti, modalità compatibilità, focus, tastiera, tocchi e pressione prolungata, orientamento e risoluzioni supportate.
5. Eseguire lo smoke test di `TESTING.md` → verificare collegamento, progressi, note offline, coda e cambio edizione sul dispositivo/account di test.

Matrice minima: nessun documento; documento non collegato; documento collegato nei diversi stati di lettura; plugin bloccato; credenziali scadute; coda vuota; retry; nota con consegna incerta; edizione sospesa; ricerca in entrambe le modalità.

## Verifica della baseline

- Aggiornamento: `git pull --ff-only`, riuscito da `9feb22f` a `19110e9`.
- Test: `scripts/test.sh`, **245 successi, 0 fallimenti, 0 errori, 0 pending**.
- Sintassi: lo stesso script verifica tutti i file Lua non ignorati, controllo riuscito.
- Il repository era pulito prima dell'aggiornamento. L'unica aggiunta locale di questa analisi è questo documento.
- Nessuna verifica visiva su KOReader o prova con mutazioni live StoryGraph è stata eseguita. I test automatici non certificano la resa sul dispositivo.
