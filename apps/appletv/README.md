# YT Zero til Apple TV

En enkel, native tvOS-app (SwiftUI) til YT Zero, med samme oplevelse som TV-siden
`/tv.html`:

- **Forside:** "Fortsæt med at se" øverst og Main nedenunder. Hvert kort viser
  miniature, kanal og titel. Klik afspiller.
- **Langt tryk på et kort:** Markér som set eller Afvis.
- **Øverst:** Opdater, som tjekker abonnementerne og henter igen, og
  Indstillinger med log ud og skift server.
- **Afspiller i fuld skærm:**
  - Højre spoler 30 s frem, og venstre 15 s tilbage.
  - Klik eller Play/Pause sætter pause og starter igen.
  - Menu går tilbage.
- **Fremskridt:** Videoen fortsætter, hvor du slap, positionen gemmes undervejs,
  og en færdigset video markeres som set.
- **Undertekster** er slået fra.

Appen er på engelsk og dansk og følger Apple TV'ets sprog.

## Sådan virker det

- **Første start:** Du skriver adressen på din YT Zero-server. Intet er bygget
  ind i appen.
- **Login:** Appen bruger serverens TV-pairing. Den viser en QR-kode og en
  kode, du godkender på telefonen, og den session, du får tilbage, gemmes i
  Keychain.
- **Afspilning:** Videoerne afspilles i AVPlayer via serveren, som henter
  med yt-dlp og sender videre, mens det kommer ind. Det er samme vej, som
  Invidious-klienter som Yattee bruger. Serveren skal derfor have yt-dlp.
  - Først `{"source":"relay-hls"}`: billede (H.264, op til 1080p) og lyd
    hentes hver for sig og afspilles som én HLS-strøm. Appen sender sin
    startposition med (`start`). Serveren svarer 202, indtil der er hentet
    nok til at starte der. Ligger stedet langt inde i en video, der ikke er
    hentet endnu, begynder serveren også at hente fra stedet selv, så det
    tager sekunder i stedet for minutter.
  - Sporene hentes som YouTubes visionOS-klient, fordi standardklienterne
    får en reklame-ventetid på cirka 6 sekunder før første byte.
    `YTZERO_RELAY_HLS_PLAYER_CLIENT` vælger en anden klient (tom = yt-dlp's
    eget valg). `YTZERO_RELAY_HLS_TAIL_AFTER_MB` (standard 32) er, hvor langt
    foran hentningen stedet skal ligge, før der hentes fra midten.
  - En stream, der er live nu, spilles via serverens live-vej (YouTubes egen
    live-HLS sendt videre).
  - Hvis det ikke kan lade sig gøre, bruges `{"source":"relay"}`: YouTubes
    samlede fil, som kun findes i 360p.
  - Begge dele gemmes i Invidious-cachen (`YTZERO_INVIDIOUS_CACHE_MB`,
    standard 4096). En times 1080p fylder omkring 1 GB, så sæt den højere,
    hvis du ser lange videoer.

## Byg og installér

Du skal bruge en Mac med Xcode (tvOS 26 SDK) og en Apple Developer-konto.

1. **Signering:** Kopiér `Config/Local.xcconfig.example` til
   `Config/Local.xcconfig`, og udfyld dit team-id og et bundle-id under dit
   eget domæne. Filen committes ikke.
2. **Par Apple TV med Mac'en:**
   - På Apple TV: åbn *Indstillinger → Fjernbetjeninger og enheder →
     Fjern-app og enheder*.
   - I Xcode: åbn *Window → Devices and Simulators*, og vælg dit Apple TV.
3. **Byg og kør:** Åbn `YTZeroTV.xcodeproj`, vælg dit Apple TV som mål, og tryk
   **Run**.
4. **TestFlight (valgfrit):**
   - Opret appen i App Store Connect med samme bundle-id.
   - Vælg *Product → Archive* og derefter *Distribute App → TestFlight*.

Med en betalt udviklerkonto holder en installation fra Xcode i et år.

## Udvikling

Projektet genereres fra `project.yml` med [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Kør `xcodegen generate` i denne mappe, når du tilføjer eller flytter filer.

Byg fra kommandolinjen uden signering:

```bash
xcodebuild -project YTZeroTV.xcodeproj -scheme YTZeroTV -sdk appletvsimulator -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

### UI-test i simulatoren

`YTZeroTVUITests` trykker sig gennem forsiden, menuen ved langt tryk og
afspilleren med Siri Remote og gemmer et skærmbillede af hvert trin. Testen
skal bruge en server og en session til den, fx en testserver og en token fra
TV-pairing:

```bash
TEST_RUNNER_YTZERO_UITEST_SERVER=http://localhost:3001 TEST_RUNNER_YTZERO_UITEST_TOKEN=<token> xcodebuild test -project YTZeroTV.xcodeproj -scheme YTZeroTV -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```
