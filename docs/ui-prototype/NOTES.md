# Prototipo UI — prima e dopo

Domanda: la nuova gerarchia rende più comprensibili le funzioni esistenti?

Mockup usa e getta in HTML/CSS/JavaScript, senza dipendenze o connessioni a StoryGraph. Le etichette sono italiane per facilitare il confronto; la traduzione del plugin non fa parte della proposta. La vista Prima ricostruisce l'organizzazione dal codice, non è uno screenshot.

Avvio dalla radice del repository:

```sh
python3 -m http.server 8765 --directory docs/ui-prototype --bind 127.0.0.1
```

Aprire http://127.0.0.1:8765. Funziona anche aprendo direttamente index.html.

Modalità: `?variant=compare`, `?variant=before`, `?variant=after`. Schermate: `screen=home`, `journal`, `editions`, `queue`, `review`, `settings`.

Usare le schede per cambiare schermata, il selettore per confrontare le versioni e le frecce della barra inferiore (o della tastiera) per cambiare vista. Le azioni sono dimostrative: alcune navigano, altre mostrano un dettaglio o un messaggio. Non riproducono l'intero flusso applicativo.

La proposta mette progressi/note nel menu principale, ma conserva nella futura implementazione le condizioni di disponibilità già esistenti e il caricamento dei dati necessario. La recensione è mostrata nella scheda dedicata per esplorarne il layout: la sua disponibilità nel plugin resta condizionata allo stato del libro. I dettagli della coda sono spiegazioni schematiche; non sostituiscono le conferme reali.

Decisione sul redesign: approvata dall'utente e implementata nei widget KOReader per la versione 0.3.0. Il prototipo resta archiviato qui come riferimento del confronto prima/dopo; la verifica dell'interfaccia nativa è descritta in TESTING.md.

## Revisione: impostazioni separate

La vista Dopo non contiene più la voce Impostazioni nel menu principale. Un pulsante dedicato nella barra del titolo apre la schermata di configurazione. Il menu resta focalizzato sul libro e sulle operazioni correnti; la vista Prima conserva la struttura originaria.

Anche il toggle del tracking automatico è spostato nelle impostazioni, nel gruppo Questo libro. Il menu mostra soltanto il suo stato attuale nel riepilogo del libro.

## Revisione: collegamento e informazioni fuori dal menu principale

Anche il gruppo Collegamento (libro collegato e cambio edizione) si trova ora nella schermata Impostazioni. Informazioni sul plugin è nel gruppo Plugin della stessa schermata. Il menu principale conserva riepilogo, azioni di lettura e coda di sincronizzazione. La vista Prima resta invariata.
