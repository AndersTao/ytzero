# YT Zero til Apple TV

En enkel, native tvOS-app (SwiftUI) til YT Zero, med samme oplevelse som TV-siden
`/tv.html`:

- **Sidebjælke:** Apples egen sidebjælke (`TabView` med `.sidebarAdaptable`)
  med Main, Anbefalinger, Shorts, Planlagt og Abonnementer og, under "Mine
  playlister", profilens egne playlister med antal videoer. Den foldes ind
  til en knap øverst til venstre. Op fra øverste række åbner den direkte, og
  Select på et sted folder den ind igen. Øverst i sidebjælken (tvOS 27) står
  billedet af den, der ser med, og Opdater, som opdaterer det sted, der vises.
  Før tvOS 27 har hver skærm sin egen Opdater-knap.
- **Forside:** "Fortsæt med at se" øverst, så "Gemt til senere" (videoer gemt
  med browserudvidelsens højreklik) og Main nedenunder. En video står kun i én
  række. Hvert kort viser miniature, kanal og titel. Klik afspiller.
- **Anbefalinger, Shorts og Planlagt** som på nettet. Opdater på Shorts tjekker
  også abonnementerne for nye videoer.
- **Abonnementer:** de fulgte kanaler med billede, navn og seneste video,
  nyeste først. Select åbner kanalens videoer.
- **Playliste:** Videoerne i et gitter, senest tilføjet først. Klik afspiller.
- **Top Shelf:** Når YT Zero ligger i øverste række på Apple TV'ets
  hjemmeskærm, viser feltet over den "Fortsæt med at se" (med hvor langt du
  er nået), "Gemt til senere" og det nyeste fra Main. Select eller Play på en video åbner appen og
  afspiller den derfra, hvor du slap.
- **Langt tryk på et kort:** Markér som set eller Afvis (i en playliste kun
  Markér som set).
- **Opdater og profilbillede:** i sidebjælken (før tvOS 27 øverst til højre).
  Opdater på Main tjekker abonnementerne og henter igen; billedet åbner
  "Hvem ser med?".
- **Hvem ser med?** fylder hele skærmen: store runde profilbilleder, der
  løfter sig med systemets lys og skygge, når fjernbetjeningen står på dem,
  "Tilføj profil" til sidst og "Log ud" nedenunder. Et langt tryk på en profil
  fjerner den fra Apple TV'et.
- **Afspiller i fuld skærm:**
  - Højre spoler 30 s frem, og venstre 15 s tilbage.
  - Klik eller Play/Pause sætter pause og starter igen.
  - Hold Select nede for Markér som set eller Afvis (som LG's taster 2 og 1).
  - Menu går tilbage.
- **Fremskridt:** Videoen fortsætter, hvor du slap, positionen gemmes undervejs,
  og en færdigset video markeres som set.
- **Undertekster** er slået fra.

Appen er på engelsk og dansk og følger Apple TV'ets sprog.

## iPhone og iPad

Samme projekt har også en app til iPhone og iPad (`YTZeroiOS`, iOS 17 eller
nyere, så den også kører på ældre iPads). Den deler server, login, forside-
logik og afspilning (`PlayerModel`) med Apple TV-appen, så den får samme
hurtige start, 1080p og fortsæt. Kun skærmene er lavet til touch:

- **Forside:** "Fortsæt med at se" som vandret række og Main nedenunder med
  skillelinje. Main har én kolonne på iPhone og flere på iPad.
- **Tryk** afspiller, og **tryk og hold** giver Markér som set og Afvis.
- **Træk ned** henter listerne igen. **Opdater-knappen** får også serveren til
  at tjekke kanalerne (cirka 30 sekunder).
- **Afspiller:** Apples egen afspiller med spoling, AirPlay og billede i
  billede. Lyden fortsætter, når skærmen slukkes, og låseskærmen viser titel
  og kanal.
- **Login:** Appen viser en kode og åbner godkendelsessiden i browseren på
  telefonen selv. Bagefter vender du tilbage til appen, der fortsætter af sig
  selv.

Byg den som Apple TV-appen. Vælg skemaet **YTZeroiOS**, og sæt
`YTZERO_IOS_BUNDLE_ID` i `Config/Local.xcconfig`.

### Fra Safari og YouTube-appen

Appen har to udvidelser, der bruger appens eget login. Du logger altså ikke
ind i Safari, og de gemmer som den profil, der ser med i appen.

- **Safari-udvidelsen** (`YTZeroSafari`): Slå den til under *Indstillinger →
  Apps → Safari → Udvidelser → YT Zero*. På en video på YouTube åbner du den
  fra sidemenuen i adresselinjen:
  - **Gem til senere** lægger videoen i "Gemt til senere", rækken på Main.
  - **Åbn i YT Zero** sætter videoen på pause og åbner den i appen, der hvor
    du var nået til. Safari spørger først, om siden må åbnes i YT Zero.
- **Del** (`YTZeroShare`): "YT Zero" i delingsarket fra Safari, YouTube-appen
  eller andre steder med et YouTube-link gemmer videoen til senere og lukker
  af sig selv.

Udvidelserne finder serverens adresse og sessionen i en App Group, som appen
deler med dem (`YTZERO_IOS_APP_GROUP`, som standard
`group.<YTZERO_IOS_BUNDLE_ID>`). Xcode opretter den, første gang du bygger med
automatisk signering. Sessionen ligger i Keychain i samme gruppe. En app, der
var logget ind før udvidelserne kom, flytter den derover ved næste start.

Linket `ytzero://play?v=<id>&t=<sekunder>` åbner appen og afspiller videoen,
som det gør på Apple TV'et.

## Profiler

"Hvem ser med?" (på Apple TV hele skærmen, på iPhone og iPad øverst i
Indstillinger): vælg en profil, og forsiden begynder forfra som den profil.

- **Server, hvor en session kan skifte profil** (intet login, fælles login,
  OIDC via gateway): listen er serverens profiler, og sessionen skifter selv.
- **Server, hvor hver session hører til én profil** (login pr. profil, OIDC i
  "mapped"-tilstand): appen har en session pr. profil i Keychain. **Tilføj
  profil** viser en ny kode, som godkendes på telefonen hos den, der skal
  tilføjes. Serveren knytter den nye session til enhedens andre, så den ved,
  hvilke profiler der er parret her. **Fjern** logger profilen ud på enheden.
- **Børneprofil:** At forlade en børneprofil kræver børnesikringens PIN-kode.
  Serveren tjekker den og tæller forkerte forsøg, som i webklienten.

## Sådan virker det

- **Top Shelf:** Udvidelsen `YTZeroTopShelf` henter intet selv. Appen gemmer
  listerne og et billede pr. video i App Group'ens mappe, hver gang forsiden
  ændrer sig, og beder systemet om at hente Top Shelf igen. Udvidelsen har
  derfor hverken serveradresse eller session. Når du logger ud, ryddes
  mappen.
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
   eget domæne. Filen committes ikke. Appen og dens Top Shelf deler en App
   Group, som hedder `group.<dit bundle-id>`, medmindre du sætter
   `YTZERO_APP_GROUP`. Xcode opretter den på din konto første gang, du bygger
   til et Apple TV (med automatisk signering; fra kommandolinjen med
   `-allowProvisioningUpdates`).
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

`YTZeroiOSUITests` åbner den første video i "Fortsæt med at se", lader den
spille og lukker den igen (skemaet `YTZeroiOS` og en iPhone- eller
iPad-simulator, med de samme to miljøvariabler som herunder).

`YTZeroTVUITests` trykker sig gennem forsiden, menuen ved langt tryk og
afspilleren med Siri Remote og gemmer et skærmbillede af hvert trin.
`testSidebarOpensAPlaylist` åbner sidebjælken og en playliste og kræver, at
profilen har en playliste ved navn "Weekend" med mindst én video.
`TopShelfUITests` går fra hjemmeskærmen op i YT Zeros Top Shelf, vælger den
første video i "Fortsæt med at se" og ser, at appen afspiller den. Det kræver,
at YT Zero ligger i øverste række på simulatorens hjemmeskærm. Den tester
også linket `ytzero://play?v=…` direkte.
`ExtensionsUITests` logger ind som et menneske (skriver adressen og godkender
koden via serveren), deler en video til "YT Zero" fra Safari og ser, at
serveren har den i "Gemt til senere". Bagefter åbner den
`ytzero://play?v=…`, og afspilleren skal komme frem.
`SafariExtensionUITests` slår Safari-udvidelsen til i Indstillinger og bruger
dens popup: Gem til senere og Åbn i YT Zero. Den kører efter
`ExtensionsUITests`, der logger appen ind. Begge skal bruge
`TEST_RUNNER_YTZERO_UITEST_SERVER` med en server, der godkender uden login
(`YTZERO_AUTH_DISABLE=1`) og kan nå YouTube.
`ProfilesUITests` (på begge platforme) skifter profil i "Hvem ser med?" og skal
også have `YTZERO_UITEST_TOKENS`: sessioner for flere profiler, parret sammen
med den første (kommasepareret, den første en børneprofil). Testen
skal bruge en server og en session til den, fx en testserver og en token fra
TV-pairing:

```bash
TEST_RUNNER_YTZERO_UITEST_SERVER=http://localhost:3001 TEST_RUNNER_YTZERO_UITEST_TOKEN=<token> xcodebuild test -project YTZeroTV.xcodeproj -scheme YTZeroTV -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```
