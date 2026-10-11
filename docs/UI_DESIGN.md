# Scelte di interfaccia

L'interfaccia introdotta nella 0.3.0 usa i widget nativi di KOReader e separa le operazioni di lettura dalla configurazione.

- Il menu principale mostra il riepilogo del libro, progressi e note, stato e recensione, salto alla posizione StoryGraph e sincronizzazione pendente.
- Il pulsante delle impostazioni nella barra del titolo raccoglie collegamento, cambio edizione, tracking, account, aggiornamenti e informazioni sul plugin. Il riepilogo principale mostra lo stato del tracking senza modificarlo.
- Il dialogo progressi e note colloca i controlli di progresso e data sopra il testo della nota.
- La ricerca delle edizioni distingue titolo, metadati ed edizione collegata; la coda separa il documento dal tipo e dallo stato dell'operazione.
- Il layout privilegia leggibilità e contrasto senza affidarsi al colore per distinguere gli stati.

La riorganizzazione conserva disponibilità delle azioni, callback, conferme, conversioni delle pagine e comportamento di sincronizzazione. La pressione prolungata sul libro collegato nelle impostazioni continua a rimuovere il collegamento.

I controlli automatici e la verifica manuale su KOReader sono descritti in [TESTING.md](../TESTING.md). I test con widget simulati non certificano il rendering sul dispositivo.
