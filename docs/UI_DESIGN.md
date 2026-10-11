# Scelte di interfaccia

L'interfaccia introdotta nella 0.3.0 usa i widget nativi di KOReader e separa le operazioni di lettura dalla configurazione.

- Il menu principale mostra il riepilogo del libro, progressi e note, stato e recensione, salto alla posizione StoryGraph e sincronizzazione pendente.
- La schermata principale usa una scheda con bordo nero sottile, copertina incorporata nel documento locale, titolo a 26 e dettagli neri a 20 su righe separate. In assenza di copertina compare un segnaposto; non vengono aggiunte richieste di rete. Le etichette di gruppo sono a 16 e le azioni touch a 22. Progressi e note è il pulsante principale scuro, accompagnato da una spiegazione della nota facoltativa; le altre azioni sono righe senza riquadri, con separatori sottili, etichette allineate e frecce sul lato destro. Il contenuto scorre sugli schermi piccoli, senza la barra di paginazione delle liste.
- Il pulsante delle impostazioni nella barra del titolo raccoglie collegamento, cambio edizione, tracking, account, aggiornamenti e informazioni sul plugin. Il riepilogo principale mostra lo stato del tracking senza modificarlo.
- Il dialogo progressi e note colloca i controlli di progresso e data sopra il testo della nota.
- La ricerca delle edizioni distingue titolo, metadati ed edizione collegata; la coda separa il documento dal tipo e dallo stato dell'operazione.
- Il layout privilegia leggibilità e contrasto senza affidarsi al colore per distinguere gli stati.

La riorganizzazione conserva disponibilità delle azioni, callback, conferme, conversioni delle pagine e comportamento di sincronizzazione. La pressione prolungata sul libro collegato nelle impostazioni continua a rimuovere il collegamento.

I controlli automatici e la verifica manuale su KOReader sono descritti in [TESTING.md](../TESTING.md). I test con widget simulati non certificano il rendering sul dispositivo.
