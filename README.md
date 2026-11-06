# Armonia

Client musicale personale per iPhone, in stile BitChord: cerca e ascolta il catalogo di YouTube Music senza pubblicità, con radio automatica, preferiti e playlist salvati sul telefono.

> Uso personale. Non è affiliato a YouTube/Google e non può andare sull'App Store.

## Cosa fa (v0.1)

- Ricerca di brani
- Riproduzione in background, controlli nella schermata di blocco, Centro di Controllo e cuffie
- Radio automatica: tocchi un brano e la coda si riempie con brani simili
- Coda modificabile (riordina, elimina, salta)
- Preferiti, ascoltati di recente, playlist locali (esportabili in JSON)
- Uscita AirPlay / Bluetooth

## Come si compila (senza Mac)

Ogni `push` sul ramo `main` avvia GitHub Actions, che compila l'app su un Mac virtuale.
Il file `Armonia.ipa` si trova in:

- **Releases** del repository (più comodo), oppure
- **Actions → ultimo run → Artifacts → Armonia-ipa**

Se la compilazione fallisce, nello stesso run c'è l'artifact `build-log` con gli errori.

## Installazione su iPhone da Windows (Sideloadly)

1. Installa **iTunes** e **iCloud** nelle versioni scaricate dal sito Apple (non quelle del Microsoft Store).
2. Installa **Sideloadly** da sideloadly.io.
3. Collega l'iPhone con il cavo e tocca "Autorizza" sul telefono.
4. Trascina `Armonia.ipa` in Sideloadly, inserisci il tuo Apple ID e premi **Start**.
5. Sull'iPhone:
   - Impostazioni → Generali → **VPN e gestione dispositivi** → autorizza il tuo Apple ID
   - Impostazioni → Privacy e sicurezza → **Modalità sviluppatore** → attiva e riavvia (solo la prima volta)

Con un Apple ID gratuito l'app scade dopo **7 giorni**: basta ripetere il passo 4 (i dati restano se non la elimini).
Sideloadly può farlo da solo con l'opzione di aggiornamento automatico se il PC è acceso sulla stessa rete Wi-Fi.

## Se smette di funzionare

La parte che si rompe è quella che parla con YouTube, tutta in `Armonia/Innertube.swift`:

- **La ricerca non va** → aggiornare `musicVersion`.
- **I brani non partono** ("Brano non riproducibile") → aggiornare le versioni in `playerClients`
  (i valori aggiornati si trovano di solito nei progetti open source come yt-dlp o Metrolist).

## Struttura

```
project.yml                 progetto Xcode (generato da XcodeGen in cloud)
.github/workflows/build.yml compilazione automatica dell'IPA
Armonia/
  ArmoniaApp.swift          avvio e schede
  Innertube.swift           ricerca, radio e flussi audio da YouTube Music
  PlayerManager.swift       player, coda, schermata di blocco
  LibraryStore.swift        preferiti, recenti, playlist
  Views/                    interfaccia SwiftUI
```
