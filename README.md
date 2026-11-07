# Armonia

Client musicale personale per iPhone, in stile BitChord: cerca e ascolta il catalogo di YouTube Music senza pubblicità, con radio automatica, preferiti e playlist salvati sul telefono.

> Uso personale. Non è affiliato a YouTube/Google e non può andare sull'App Store.

## Cosa fa (v0.2)

- Ricerca completa: brani, artisti, album e playlist
- Pagine artista (brani più ascoltati, album, singoli, artisti simili) e album
- Riproduzione in background, controlli nella schermata di blocco, Centro di Controllo e cuffie
- Radio automatica: tocchi un brano e la coda si riempie con brani simili
- Download per l'ascolto offline (brani, album, playlist)
- Import delle playlist di Spotify (link pubblico o CSV di exportify.app)
- Import dei tuoi file FLAC/ALAC/MP3 dall'app File, riprodotti in qualità originale
- Coda modificabile, preferiti, recenti, playlist locali (esportabili in JSON)
- Uscita AirPlay / Bluetooth

YouTube Music non offre audio lossless: lo streaming e i download sono AAC (di solito 128 kbps).

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

La parte che si rompe è quella che parla con YouTube.

**Prima prova (senza reinstallare):** modifica `clients.json` in questo repository.
L'app lo legge a ogni avvio, quindi basta chiuderla del tutto e riaprirla.

- **La ricerca non va** → aggiornare `musicVersion`.
- **I brani non partono** ("Brano non riproducibile") → aggiornare `playerClients`.
  Il messaggio d'errore dice cosa ha risposto ogni client (es. `VISIONOS: audio rifiutato (403)`).
  I valori aggiornati si trovano in yt-dlp, file `yt_dlp/extractor/youtube/_base.py`.

I valori di riserva, usati se `clients.json` non è raggiungibile, sono in `Armonia/Innertube.swift`.

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
