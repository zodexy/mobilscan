# Scaniverse-szerű élő scan app – 2DGS-re optimalizálva (felhős feldolgozással)

> Cél: olyan mobil scanner, amelynek a felhasználói élménye megegyezik a Scaniverse splat-módjával (REC → mozgás a tárgy körül → élő, egyre élesedő előnézet → Stop → feldolgozás), de a begyűjtött adat **2D Gaussian Splatting (2DGS)** felhős tanítására van optimalizálva.
>
> Fontos: a Scaniverse-ről csak a felhasználói felületet láttam a videóban. A belső működésre vonatkozó részek **tervezési javaslatok**, nem a Scaniverse forráskódjának leírása. A 2DGS parancssori flagek és alapértékek verziónként változhatnak, ezeket mindig ellenőrizd az aktuális repo README-jében.

---

## Tartalom

1. [Alapgondolat: mit csinál a telefon, mit a felhő](#1-alapgondolat)
2. [Mi a különbség 2DGS és 3DGS adatigénye között](#2-2dgs-specifikus-adatigény)
3. [Rendszerarchitektúra](#3-rendszerarchitektúra)
4. [UX és állapotgép](#4-ux-és-állapotgép)
5. [Kamera- és szenzorkonfiguráció](#5-kamera--és-szenzorkonfiguráció)
6. [Pózkövetés](#6-pózkövetés)
7. [Keyframe-kiválasztás](#7-keyframe-kiválasztás)
8. [Élő előnézet (nem tanított splat)](#8-élő-előnézet)
9. [Lefedettség-számítás és vezetés](#9-lefedettség-számítás-és-vezetés)
10. [Csomagformátum és tárolás a telefonon](#10-csomagformátum)
11. [Feltöltés](#11-feltöltés)
12. [Felhős pipeline](#12-felhős-pipeline)
13. [Koordináta- és kameramodell-konverzió (ARKit → COLMAP)](#13-koordináta-konverzió)
14. [2DGS tanítás és mesh-kinyerés](#14-2dgs-tanítás-és-mesh-kinyerés)
15. [Minőségkapuk és hibakezelés](#15-minőségkapuk-és-hibakezelés)
16. [Tesztelés és mérőszámok](#16-tesztelés-és-mérőszámok)
17. [Megvalósítási ütemterv](#17-ütemterv)
18. [Gyakori hibák ellenőrzőlistája](#18-ellenőrzőlista)

---

## 1. Alapgondolat

A Scaniverse a videó alapján a **telefonon** mutat élő splat-szerű előnézetet, és a végső, teljes minőségű tanítást külön lépésben végzi („Process Now / Process Later"). A te esetedben a végső tanítás a felhőben fut 2DGS-sel, ezért a felelősség így oszlik meg:

| Réteg | Hol fut | Feladat | Minőségi elvárás |
|---|---|---|---|
| **Élő réteg** | Telefon | Pózkövetés, keyframe-gyűjtés, mélység, gyors surfel-előnézet, lefedettség és minőség visszajelzés | Gyors (30 fps UI), nem a végső minőség |
| **Csomagoló réteg** | Telefon | Adat rendezése, ellenőrzése, feltöltése | Megbízható, folytatható |
| **Feldolgozó réteg** | Felhő (GPU) | Pózfinomítás, 2DGS tanítás, mesh, tömörítés | Maximális minőség |

**Aranyszabály:** a telefon dolga nem a szép kép, hanem az, hogy a felhőnek **éles, jól kiosztott, pontosan pozicionált képeket** adjon. Egy rossz scanen a legjobb 2DGS-tanítás sem segít, egy jó scanen már az alapbeállítás is szép eredményt ad.

---

## 2. 2DGS-specifikus adatigény

A 2DGS a 3D Gauss-ellipszoidok helyett lapos, 2D Gauss-korongokat (surfelt) használ, amelyeknek van normálvektoruk. Ettől a geometria pontosabb, de az adatra a következő következményei vannak:

1. **Pózpontosság kritikus.** A 2DGS mélység-normál konzisztencia és eloszlás (distortion) regularizációt használ, ezért a néhány pixeles pózhiba felület-zajként vagy „duplázott" felületként jelentkezik. Ez érzékenyebb, mint a sima 3DGS.
2. **Többszögű lefedettség kell minden felületre.** A surfel normálisát csak akkor lehet jól megbecsülni, ha ugyanazt a felületdarabot több, egymástól eltérő irányból is látjuk. Egyetlen irányból (például csak körbejárás egy magasságon) a normálok bizonytalanok maradnak.
3. **Mozgáselmosódás és rossz élesség közvetlenül rontja a geometriát**, mert a regularizáció az elmosódott képekhez is illeszkedni próbál.
4. **Konzisztens megvilágítás és expozíció** kell. Az expozícióváltozás a színek mellett a felület-illesztést is zavarja.
5. **Mozgó objektumok** (ember, háziállat, függöny) szellemképet és hibás felületet okoznak.
6. **Tükröző, átlátszó, textúra nélküli felületek** problémásak (üveg, fényes fém, fehér fal). Az appnak ezt jeleznie kell, nem tudja megoldani.
7. **Metrikus skála hasznos**, mert a mesh-kinyerés (TSDF) paraméterei (voxelméret, truncation) méterben adhatók meg. Az ARKit/ARCore pózai metrikus skálájúak, ezt érdemes megtartani.
8. **Több, de nem túl sok kép:** tipikusan 100–400 jó kép elég egy tárgyhoz vagy kisebb térhez, egy nagyobb szobához 400–800. A felesleges, közel azonos képek csak idő- és tárhelypazarlás, a hiányzó szögek viszont nem pótolhatók.

Az ebből adódó **mobilos követelmények**: pontos pózok, éles és jól kiosztott keyframe-ek, lefedettség-vezetés, zárolt expozíció, mélységadat (ha van LiDAR), és mindezek metrikus, időbélyeges mentése.

---

## 3. Rendszerarchitektúra

```
┌──────────────────────────── TELEFON ────────────────────────────┐
│                                                                  │
│  Kamera + IMU (+LiDAR)                                           │
│        │                                                         │
│        ▼                                                         │
│  Pózkövetés (ARKit/ARCore VIO, loop closure)                     │
│        │                                                         │
│        ├──► Minőségmérők (élesség, blur, fény, parallaxis)       │
│        │                                                         │
│        ▼                                                         │
│  Keyframe-választó ──► Lemezre írás (kép, póz, mélység, meta)    │
│        │                                                         │
│        ├──► Élő surfel-előnézet (Metal/Vulkan)                   │
│        └──► Lefedettség-térkép ──► UI visszajelzés               │
│                                                                  │
│  Stop ──► Véglegesítés ──► Csomag (zip/tar) ──► Feltöltő         │
└──────────────────────────────────┬───────────────────────────────┘
                                   │  (resumable, chunked upload)
                                   ▼
┌───────────────────────────── FELHŐ ─────────────────────────────┐
│  Objektumtár (S3/GCS)  ──►  Job-sor  ──►  GPU worker            │
│                                                                  │
│  Worker lépései:                                                 │
│   1. Validálás + minőségkapuk                                    │
│   2. Előfeldolgozás (kép-konverzió, maszkok, mélység)            │
│   3. Pózfinomítás (COLMAP / GLOMAP, ARKit-pózokkal)              │
│   4. Init pontfelhő (LiDAR + triangulált pontok)                 │
│   5. 2DGS tanítás (gyors előnézet → teljes)                      │
│   6. Mesh-kinyerés (TSDF) + tisztítás                            │
│   7. Tömörítés, thumbnail, megosztható formátum                  │
│                                                                  │
│  Értesítés (push/webhook)  ──►  Telefon: „Kész"                  │
└──────────────────────────────────────────────────────────────────┘
```

**Ajánlott technológia**

- iOS: Swift, ARKit (VIO + LiDAR), Metal, AVFoundation, `URLSession` háttér-feltöltés.
- Android: Kotlin, ARCore (Depth API), Vulkan/OpenGL ES, WorkManager a feltöltéshez.
- Cross-platform megoldás esetén is érdemes a capture magját natívban írni, mert a pózkövetéshez és a kamera-vezérléshez natív hozzáférés kell.
- Backend: bármilyen (Python/FastAPI, Go, Node), az objektumtárba presigned multipart feltöltéssel.
- GPU worker: Docker, CUDA, COLMAP (vagy GLOMAP), 2DGS repo, Open3D/trimesh a mesh-utómunkához.

---

## 4. UX és állapotgép

A videóban látott folyamat leképezése:

```
IDLE ─► READY ─► RECORDING ⇄ PAUSED
                    │           │
                    │           └─► RELOCALIZING ─► PAUSED/RECORDING
                    ▼
                FINALIZING ─► COMPLETE (Process Now / Process Later)
                                   │
                          PACKAGING ─► UPLOADING ─► QUEUED ─► PROCESSING ─► DONE
                                                                     └─► FAILED (ok + újrapróbálás)
```

### Képernyők és viselkedés

**READY (felvétel előtt)**
- Teljes képernyős kamera, felül X és `00:00:00` időzítő, alul REC gomb.
- Tipp: „Irányítsd a kamerát a tárgyra, majd nyomd meg a REC-et."
- Ilyenkor már fut a pózkövetés, hogy a REC megnyomásakor már stabil legyen. A REC gomb csak akkor aktív, ha a követés `normal` állapotú, és van elég jellemzőpont. Különben szürke, és rövid magyarázat jelenik meg („Mozgasd kicsit a telefont, amíg a követés stabil lesz").
- Módválasztó (javasolt): **Tárgy** (objektum-központú) és **Tér** (szoba/környezet). A két mód más lefedettség-logikát használ (9. fejezet).

**RECORDING**
- REC → stop gomb (piros négyzet), mellette szünet gomb. Az időzítő zöld.
- Tipp: „Járd körül a tárgyat, minden oldalról, magasan és alacsonyan."
- Az élő nézet a **rekonstruált surfel-felhő** renderelése a jelenlegi kamerapózból, nem a nyers kamerakép. Az újonnan látott területek fokozatosan „megjelennek", a hiányos részek halványak vagy üresek.
- Felül vagy alul kis lefedettség-jelző (gyűrű vagy dóm, lásd 9. fejezet), és egysoros dinamikus tanács („Lassíts", „Menj lejjebb", „Túl sötét").

**PAUSED**
- A rögzítés áll, de a követési munkamenet **él marad**. Folytatáskor a rendszer ellenőrzi, hogy a póz a régi koordinátarendszerben van-e. Ha nem, RELOCALIZING állapot: szellemkép a legutóbbi jó nézetről, és „Térj vissza ide" felirat, amíg a relokalizáció nem sikerül.

**FINALIZING / COMPLETE**
- Stop után rövid véglegesítés (utolsó keyframe-ek kiírása, statisztikák, előnézeti kép).
- A „Scan Complete" képernyőn az élő rekonstrukció sötétített előnézete, két gomb: **Process Now** (azonnali feltöltés és feldolgozás) és **Process Later** (a csomag a Library-ben marad, később, például Wi-Fi-n és töltés közben indul).
- Ha a minőségpontszám alacsony, itt figyelmeztess: „A scan hiányos a bal oldalon. Folytatod?" és kínálj **Folytatás** gombot (ugyanabba a munkamenetbe rögzít tovább, ha a relokalizáció sikerül).

**Megszakítások kezelése**
- Bejövő hívás, alkalmazásváltás, lezárt képernyő: a munkamenet automatikusan szünetel, és mentsd le az állapotot. Az adat folyamatosan lemezre íródik, így összeomlás után az app felajánlhatja a folytatást vagy a mentett rész feldolgozását.
- X gomb: mindig megerősítés („Biztosan elveted?").

---

## 5. Kamera- és szenzorkonfiguráció

### 5.1 Felbontás és formátum

| Beállítás | Javaslat | Indok |
|---|---|---|
| Keyframe-felbontás | 1920×1440 (ARKit alapértelmezett) vagy magas felbontású still (iOS 16+ `captureHighResolutionFrame`, jellemzően 4032×3024) | 2DGS-hez általában 1600–2000 px szélesség elég; a felhő úgyis leskálázhatja |
| Élő előnézeti feldolgozás | Nagyon kicsi (pl. 256×192 mélység, 480 px kép) | A telefon ne terhelődjön |
| Képformátum a csomagban | JPEG, minőség ≥ 92, sRGB | A felhő-oldali eszközök (COLMAP, PyTorch) natívan olvassák; HEIC-et szerveren kell konvertálni |
| Képforgatás | **Ne forgasd el a képet.** Mentsd a szenzor natív tájolásában, és mentsd mellé a tájolást | Az ARKit intrinsics és pózok a natív (landscape) képhez tartoznak |

Méretbecslés: 300 keyframe × ~1,5 MB (1920×1440) ≈ 450 MB. A 4K-s stillekkel ez a duplája-háromszorosa, ezért legyen beállítás („Gyors / Kiegyensúlyozott / Maximális minőség").

### 5.2 Expozíció, fókusz, fehéregyensúly

A 2DGS érzékeny az expozíciós ingadozásra, ezért a felvétel alatt:

- **Expozíció zárolása** a REC megnyomásakor (iOS-en az ARKit kameraeszköze a `ARSession.configurableCaptureDeviceForPrimaryCamera` segítségével elérhető, ezen állítható az expozíció-mód és a fókusz).
- **Fókusz zárolása** (vagy folyamatos AF, ha a tárgy távolsága nagyon változik; ilyenkor a gyűjtött képek fókusztávolság-ingadozását jelezni kell a metaadatban).
- **Fehéregyensúly zárolása.**
- Ha az expozíciót zárolod, figyelmeztess, ha a jelenet fényereje nagyon változik (például árnyékba mész): „Világítás változott, a szín eltérhet."
- Mentsd el minden képhez: `exposureDuration`, ISO (ha elérhető), fényerő-becslés. A felhő ezt normalizálásra vagy szűrésre használhatja.

### 5.3 Szenzoradatok

- **IMU** (gyro + gyorsulásmérő): 100–200 Hz, időbélyegezve. Az ARKit belül használja, de a szögsebességet érdemes te is naplózni a blur-becsléshez.
- **LiDAR / mélység**: iPhone Pro és iPad Pro esetén `ARFrame.sceneDepth` (kb. 256×192, float32 méter) és `confidenceMap`. Csak a magas konfidenciájú pixeleket használd. Android-on ARCore Depth API.
- **GPS/földrajzi pozíció** (opcionális): a térképes megosztáshoz, felhasználói engedéllyel.
- **Eszközmodell, OS-verzió, kamera-intrinsics** minden képhez.

---

## 6. Pózkövetés

### 6.1 Miért a platform VIO-ját használd

Az ARKit és ARCore kész, jól hangolt vizuális-inerciális odometriát ad metrikus skálával és loop closure-rel. Ennek saját megírása hónapokat visz el, és valószínűleg gyengébb lesz. **Javasolt út:** platform-VIO valós időben, majd felhős finomítás (12. fejezet).

### 6.2 Követési állapot kezelése

Naplózd minden frame-hez a követési állapotot (`normal`, `limited(reason)`, `notAvailable`), és:

- `limited` vagy `notAvailable` alatt **ne írj ki keyframe-et**.
- Ha 1–2 másodpercnél tovább tart a `limited`, automatikusan PAUSED + RELOCALIZING.
- A követés-elvesztést írd a metaadatba időbélyeggel, így a felhő tudja, hol lehet ugrás a pózokban (például szegmentálhatja a szekvenciát).

### 6.3 Drift

A VIO-drift hosszú scanen centiméteres, akár nagyobb hibát halmozhat fel. Ezért:

- Ösztönözd a felhasználót, hogy **zárja be a hurkot** (térjen vissza a kiindulási nézethez). A lefedettség-vezetés eleve körbejárást kér, ez természetesen zárja a hurkot.
- A csomagban legyen **minden keyframe pózja az ARKit szerinti becsléssel**, a felhő ezt csak kiindulásnak veszi, és bundle adjustmenttel finomítja.
- Tér-módban nagy, hosszú scanek esetén fontold meg az almunkamenetekre bontást (szakaszos scan, később összefűzés).

---

## 7. Keyframe-kiválasztás

A cél nem az, hogy sok képet gyűjts, hanem hogy **kevés, éles, jól elosztott** képet.

### 7.1 Feltételek egy új keyframe-hez

Egy frame akkor lesz keyframe, ha **mind** teljesül:

1. **Követés:** `normal` állapot és elegendő jellemzőpont.
2. **Mozgás az előző keyframe-hez képest:** elmozdulás ≥ `d_min` **vagy** forgás ≥ `θ_min`.
   - Tárgy-mód kiindulás: `d_min` = 0,05–0,10 m, `θ_min` = 5–8°.
   - Tér-mód kiindulás: `d_min` = 0,15–0,30 m, `θ_min` = 8–12°.
3. **Élesség:** a becsült mozgáselmosódás kisebb, mint ~1,0–1,5 pixel (lásd 7.2), és/vagy a Laplace-variancia egy küszöb felett van.
4. **Expozíció:** nincs túl- vagy alulexponálás (hisztogram-alapú ellenőrzés), nincs expozíció-ugrás.
5. **Időköz:** legalább 0,25–0,3 s telt el az előző keyframe óta, de ha mozgás közben 1,0 s-nál régebben volt keyframe, engedj lazább küszöböt.
6. **Új információ:** a frame új, vagy alul-lefedett felületet lát (lásd 9. fejezet). Ha a felhasználó egy már jól lefedett területet néz, ritkítsd a keyframe-eket.

**Cél:** mozgás közben 1,5–3 keyframe/s, állva vagy nagyon lassan mozogva 0. Egy 40 másodperces scanből így 80–150 jó kép lesz.

### 7.2 Mozgáselmosódás becslése képfeldolgozás nélkül

A blur (pixelben) közelíthető a szögsebességből és az expozíciós időből:

```
blur_px ≈ ω[rad/s] × t_exp[s] × f_px
```

ahol `ω` a kamera szögsebessége (az IMU-ból vagy az egymást követő pózok különbségéből), `t_exp` az expozíciós idő (az `ARCamera.exposureDuration` iOS-en), `f_px` a fókusztávolság pixelben. A haladó mozgás (transzláció) blur-je ennél kisebb hatású közeli tárgyaknál, ezt a `v / z × t_exp × f_px` kifejezéssel lehet becsülni, ahol `v` a sebesség, `z` a tárgytávolság (mélységből).

Ez olcsó, és **azonnal** működik, vagyis már a keyframe-döntés előtt kiszűri a rossz frame-eket. Kiegészítésként a keyframe-jelölt képre lefuttatható egy Laplace-variancia (leskálázott szürkeárnyalatos képen, Accelerate/vImage vagy Metal Performance Shaders használatával).

### 7.3 Váz (Swift-pszeudokód)

```swift
struct KeyframeDecision { let accept: Bool; let reason: String }

final class KeyframeSelector {
    var lastKF: (T: simd_float4x4, time: TimeInterval)?
    var params: Params   // mode-függő küszöbök

    func evaluate(frame: ARFrame,
                  angularVelocity: Float,       // rad/s
                  linearSpeed: Float,           // m/s
                  medianDepth: Float,           // m
                  sharpness: Float?,            // opcionális Laplace-var
                  coverageGain: Float) -> KeyframeDecision {

        guard case .normal = frame.camera.trackingState else {
            return .init(accept: false, reason: "tracking")
        }

        let f = frame.camera.intrinsics[0][0]      // fx pixelben
        let texp = Float(frame.camera.exposureDuration)
        let blurRot = angularVelocity * texp * f
        let blurTrans = (linearSpeed / max(medianDepth, 0.2)) * texp * f
        if max(blurRot, blurTrans) > params.maxBlurPx {
            return .init(accept: false, reason: "blur")
        }
        if let s = sharpness, s < params.minSharpness {
            return .init(accept: false, reason: "sharpness")
        }

        guard let last = lastKF else { return .init(accept: true, reason: "first") }

        let dt = frame.timestamp - last.time
        if dt < params.minInterval { return .init(accept: false, reason: "interval") }

        let (dist, angle) = relativeMotion(last.T, frame.camera.transform)
        let moved = dist >= params.minDist || angle >= params.minAngle
        let stale = dt > params.maxInterval
        let useful = coverageGain >= params.minCoverageGain

        if (moved && useful) || (stale && moved) {
            return .init(accept: true, reason: "ok")
        }
        return .init(accept: false, reason: "no-new-info")
    }
}
```

---

## 8. Élő előnézet

### 8.1 Miért nem tanítunk splatot a telefonon

Az élő előnézetnek egyetlen célja van: a felhasználó **lássa, mit rögzített eddig, és mi hiányzik**. Ehhez nem kell valódi 2DGS-tanítás. A telefonos tanítás melegít, akkumulátort visz, és mégsem érné el a felhős minőséget. A 2DGS ráadásul felület-alapú (surfel), ezért az élő előnézet is természetes módon **surfel-alapú** lehet.

### 8.2 Javasolt élő renderer: mélységből épített surfel-felhő

**Bemenet:** minden N-edik frame (nem csak a keyframe-ek) mélységtérképe + színe + pózja.
**Ha nincs LiDAR:** ritka jellemzőpontok az ARKit `rawFeaturePoints`-ből, vagy egy könnyű monokuláris mélységbecslő (metrikus skálára illesztve a VIO pontjaihoz). Ez gyengébb, ezt a felhasználónak is jelezni kell, mert a lefedettség-becslés kevésbé pontos.

**Lépések:**
1. Mélység-pixelek visszavetítése 3D-be a pózzal és az intrinsics-szel (32–64 pixeles rács elég).
2. Szín mintavételezése a kamerakép megfelelő pontjából.
3. Normál becslése a mélység gradiensből (szomszédos pontok keresztszorzata).
4. **Voxel-hash deduplikálás** (1–2 cm-es rács). Egy voxelben a pont pozícióját, színét és normálját fut. átlagolással frissítjük, és számoljuk a megfigyelések számát.
5. Renderelés: minden voxelből egy korong (surfel), sugara ≈ `z × pixelméret / f` skálázva, Gauss-szerű átlátszósági lecsengéssel. Ezt a Metal/Vulkan GPU-n **point sprite vagy instanced quad** technikával kell rajzolni.
6. Puha kinézet: kis fényesség-blur és alpha-keverés, így kapod a videón látható „festékfoltos" splat-hatást.

**Teljesítménykorlátok:**
- Legfeljebb ~300–600 ezer surfel az élő nézetben.
- A régi, sokszor megfigyelt területeket egyszerűsíteni (nagyobb voxel) lehet.
- Belső renderfelbontás lehet a képernyő fele, majd felskálázás.
- Hőállapot-figyelés: ha a készülék melegszik, csökkentsd az előnézet frissítési gyakoriságát, **de a nyers rögzítést soha ne**.

### 8.3 Vizuális visszajelzés az előnézeten

- Jól lefedett felület: telt színek.
- Kevéssé lefedett (kevés megfigyelés vagy szűk szögtartomány): halványabb, kicsit átlátszó, esetleg finom „szemcsés" textúra.
- Nem látott: üres/sötét.

Így a felhasználó ösztönösen a halvány részek felé mozog, ez pótolja a videón látható szöveges tippet.

---

## 9. Lefedettség-számítás és vezetés

Ez a modul dönti el, hogy a 2DGS-nek használható adat lesz-e. Két mód:

### 9.1 Tárgy-mód (objektum-központú)

1. **Középpont kijelölése:** a felhasználó a REC előtt rátap a tárgyra (raycast a mélységre vagy az ARKit síkra), vagy a kép közepén lévő mélységi medián adja a célpontot.
2. **Dóm-modell:** a tárgy körüli képzeletbeli félgömbön (vagy teljes gömbön, ha körbejárható alulról is) `N_az × N_el` cellát definiálunk, például **24 azimut × 4 elevációs sáv** (például 10°, 30°, 50°, 70° a vízszinteshez képest).
3. Minden keyframe a `(azimut, eleváció)` cellába kerül, ahonnan a tárgyat nézi. Egy cella „kész", ha van benne legalább 1–2 éles keyframe, és a szomszédos cellák között nincs túl nagy szögugrás.
4. **UI:** kis gyűrű/dóm ikon a képernyő sarkában, a kész cellák kitöltve. A hiányzó cellák felé nyíl vagy szöveg mutat („Menj lejjebb a bal oldalon").
5. **Távolság:** ellenőrizd, hogy a tárgy ne legyen túl közel (a fókuszhatár alatt) vagy túl messze (kevés pixel jut rá). Kiindulás: a tárgy a kép magasságának 40–80%-át töltse ki.

### 9.2 Tér-mód (szoba, környezet)

A dóm itt nem alkalmazható. Helyette **felület-központú lefedettség**:

1. A voxelrács (2–5 cm) minden felülettel érintett voxeléhez tároljuk a **megfigyelési irányokat** egy kis oktaéderes/ikozaéderes irányhisztogramban (például 16 irány-bin).
2. Egy voxel **„jól lefedett"**, ha legalább 3–4 különböző irány-binből látták, és a megfigyelési irányok közti maximális szög legalább 30–40°.
3. Az összesített haladás: a jól lefedett voxelek aránya az összes megfigyelt voxel között. Mivel a nevező (a ténylegesen létező felület) ismeretlen, egészítsd ki **határ- (frontier) detektálással**: azok a megfigyelt voxelek, amelyeknek a szomszédai üresek, valószínűleg a scan széléhez vagy hiányzó részhez tartoznak. Ezeket jelöld az előnézeten.
4. **Padló és plafon** külön kezelendő: külön tipp („Nézz a padlóra is").

### 9.3 Dinamikus tanácsok (küszöbértékek kiindulásnak)

| Feltétel | Üzenet | Hatás |
|---|---|---|
| `blur_px > 1,5` | „Lassíts" | Keyframe nem íródik |
| Átlagfényesség nagyon alacsony / ISO magas | „Túl sötét, keress több fényt" | Figyelmeztetés |
| Kevés jellemzőpont (fehér fal, homogén felület) | „Nézz textúrásabb rész felé" | Figyelmeztetés |
| Csak forgás, kevés transzláció (parallaxis hiánya) | „Lépj oldalra, ne csak fordulj" | Keyframe nem íródik |
| Tárgy túl közel | „Húzódj hátrébb" | Figyelmeztetés |
| Követés `limited` | „Mozgasd lassabban / nézz jól megvilágított részre" | Pause 1–2 s után |
| Hiányzó dómcella / alacsony lefedettségű régió | „Menj [irány]" nyíllal | Vezetés |
| Mozgó objektum észlelve (nagy inkonzisztencia a mélységek között) | „Valami mozog a képen" | Figyelmeztetés + jelölés a metaadatban |
| Tükröző/átlátszó felület gyanú (mélység-instabilitás) | „Üveg vagy tükör problémás lehet" | Figyelmeztetés |

A tanácsokat **korlátozd egyszerre egyre**, prioritási sorrenddel, és legalább 1,5–2 másodpercig tartsd látható állapotban, hogy ne villogjon a felület.

---

## 10. Csomagformátum

Az adatot folyamatosan írd lemezre, a szerver-oldali feldolgozás pedig ezt a struktúrát várja:

```
scan_<uuid>/
├── manifest.json
├── images/
│   ├── 000001.jpg
│   ├── 000002.jpg
│   └── ...
├── depth/                 # opcionális (LiDAR/ToF)
│   ├── 000001.depth       # float16 vagy float32, méter, sor-major
│   └── ...
├── confidence/            # opcionális
│   ├── 000001.png         # 8 bit: 0=alacsony, 1=közepes, 2=magas
│   └── ...
├── poses.jsonl            # egy sor / keyframe
├── imu.bin                # opcionális, időbélyegezett IMU-napló
├── live_points.ply        # opcionális, az élő surfel-felhő exportja
└── thumbnail.jpg
```

### 10.1 `manifest.json`

```json
{
  "schema_version": 1,
  "scan_id": "b1f2...",
  "created_at": "2026-09-28T16:20:00Z",
  "mode": "object",
  "device": { "model": "iPhone15,3", "os": "iOS 18.x", "has_lidar": true },
  "app_version": "0.1.0",
  "image": {
    "width": 1920, "height": 1440,
    "format": "jpeg", "orientation": "sensor_native_landscape"
  },
  "depth": { "width": 256, "height": 192, "unit": "meter", "dtype": "float32" },
  "coordinate_system": {
    "source": "ARKit",
    "camera_axes": "x-right, y-up, z-backward",
    "world_up": "+Y",
    "scale": "metric"
  },
  "num_keyframes": 214,
  "duration_s": 40.6,
  "tracking_loss_events": [ { "t": 17.2, "duration_s": 0.8 } ],
  "capture_settings": { "exposure_locked": true, "focus_locked": true, "wb_locked": true },
  "quality": {
    "coverage_score": 0.87,
    "mean_blur_px": 0.6,
    "rejected_frames": { "blur": 310, "tracking": 42, "no-new-info": 520 }
  },
  "subject_center": [0.12, 0.45, -0.80],
  "gps": null
}
```

### 10.2 `poses.jsonl` egy sora

```json
{
  "id": "000001",
  "timestamp": 12.3456,
  "T_c2w": [ 0.99,0.01,-0.02,0, -0.01,0.99,0.03,0, 0.02,-0.03,0.99,0, 0.10,0.55,-0.20,1 ],
  "intrinsics": { "fx": 1445.2, "fy": 1445.2, "cx": 960.1, "cy": 720.3, "w": 1920, "h": 1440 },
  "tracking": "normal",
  "exposure_s": 0.0083,
  "iso": 80,
  "angular_velocity": 0.12,
  "median_depth": 1.35
}
```

Megjegyzés: az `T_c2w` az ARKit **oszlop-major** 4×4 mátrixa (`simd_float4x4`), tehát a sorrend a mátrix oszlopai egymás után. Dokumentáld ezt a manifestben, mert ez az egyik leggyakoribb hibaforrás.

---

## 11. Feltöltés

- **Megszakítható, folytatható (resumable) feltöltés:** objektumtár multipart feltöltése presigned URL-ekkel, részenként (például 8–16 MB-os chunkok), chunk-szintű újrapróbálkozással.
- **Háttérfeltöltés:** iOS-en háttér `URLSession`, Androidon WorkManager/foreground service, hogy a felhasználó zárolhassa a telefont.
- **Feltételek:** alapértelmezés szerint csak Wi-Fi-n és töltés közben (beállítható), „Process Now" esetén azonnal.
- **Integritás:** minden fájlhoz checksum (például SHA-256) a manifestben, a szerver ellenőrzi.
- **Kétlépcsős feltöltés (opcionális gyorsítás):** először a manifest + kis felbontású képek + pózok (gyors előfeldolgozás és előzetes minőségellenőrzés), majd a teljes felbontású csomag. Így a szerver már korán tud „ez a scan használhatatlan" visszajelzést adni.
- **Adatvédelem:** a felhasználónak világosan kell tudnia, mi töltődik fel (képek, GPS), és mennyi ideig tárolja a szerver. Legyen törlési lehetőség.

---

## 12. Felhős pipeline

### 12.1 Lépések áttekintése

1. **Validálás és minőségkapuk** (15. fejezet).
2. **Előfeldolgozás:** képek konvertálása/leskálázása, mélység- és konfidenciatérképek dekódolása, opcionális maszkok (ég, felhasználó keze, hátrahagyott tárgyak).
3. **Pózfinomítás:** az ARKit-pózok pontosítása bundle adjustmenttel.
4. **Kezdeti pontfelhő (2DGS inicializálás).**
5. **2DGS tanítás** (gyors előnézeti kör, majd teljes).
6. **Mesh-kinyerés** (TSDF-fúzióval) és tisztítás.
7. **Tömörítés, thumbnailek, csomagolás, értesítés.**

### 12.2 Pózfinomítás – három stratégia

A 2DGS pózérzékenysége miatt ez a legfontosabb felhős lépés. Három út, és a **hibrid** az ajánlott.

**A) ARKit-pózok bizalma + triangulálás (gyors, robusztus)**
1. Az ARKit-pózokból (13. fejezet) állítsd elő a COLMAP `cameras.txt`, `images.txt` fájlokat (üres `points3D.txt`).
2. `colmap feature_extractor` a képekre.
3. `colmap spatial_matcher` vagy `sequential_matcher` (vagy saját, póz-alapú szomszédpár-lista az `exhaustive_matcher` helyett, ami sokkal gyorsabb).
4. `colmap point_triangulator` **rögzített pózokkal**: az ARKit pózokból triangulál 3D pontokat.
5. Opcionálisan `colmap bundle_adjuster` a pózok finomításával (kis szabadsággal) vagy anélkül.

Előny: metrikus skála megmarad, gyors, kevés hibalehetőség. Hátrány: az ARKit-drift megmarad, ha nem futtatsz BA-t.

**B) Teljes SfM (COLMAP vagy GLOMAP) az ARKit-pózoktól függetlenül**
1. Teljes feature-illesztés és inkrementális/globális SfM.
2. Az eredményt **Sim(3) illesztéssel** igazítsd az ARKit-pózokhoz (a kamerapozíciók pontfelhőire), így visszakapod a metrikus skálát és a gravitáció-irányt.

Előny: általában pontosabb belső konzisztencia. Hátrány: lassabb, és kevés textúrájú jeleneteknél elbukhat.

**C) Hibrid (ajánlott)**
1. Futtasd a B) utat. Ha a regisztrált képek aránya ≥ 95% és az átlagos újravetítési hiba < 1 px, használd ezt (Sim(3)-mal az ARKit-skálára igazítva).
2. Ha nem sikerül, essen vissza az A) útra bundle adjustmenttel.
3. Mindkét esetben írd a jobra a döntést és a statisztikákat a jobnaplóba.

### 12.3 Kezdeti pontfelhő

A 3DGS/2DGS kódbázisok tipikusan a COLMAP ritka pontfelhőjéből (`points3D`) inicializálnak. Ez textúrátlan felületeken kevés pontot ad. Javítás:

- **LiDAR-mélységből fúzionált pontfelhő** (például 100–300 ezer pont, voxel-szűrt, színnel és normállal) hozzáadása a triangulált pontokhoz. Ez sokat segít, mert a surfelek már közel a valódi felülethez indulnak.
- A pontokat írd a `sparse/0/points3D.ply` fájlba (vagy a repo által elfogadott formátumban; a 3DGS-származék kódok általában felismerik a `points3D.ply`-t, de **ellenőrizd az aktuális repo dataset-olvasóját**).
- Ha nincs mélység: MVS-sel (például COLMAP `patch_match_stereo`) vagy egy modern mélység-/pontfelhő-becslő hálóval készíthetsz sűrűbb kezdeti felhőt.

### 12.4 Opcionális mélység- és normál-prior

Az alap 2DGS nem használ mélység-felügyeletet. Ha van LiDAR, **bővítheted a tanítást** egy mélység-veszteséggel (például skála-igazított L1 a renderelt és a LiDAR-mélység között, csak a magas konfidenciájú pixeleken). Ez textúrátlan területeken stabilabb geometriát adhat, de saját fejlesztés, mérd, hogy tényleg javít-e.

### 12.5 Infrastruktúra

- **Sor:** SQS/Pub/Sub/Redis, a job állapota: `uploaded → validating → sfm → training_preview → training_final → meshing → done | failed`.
- **GPU worker:** Docker-kép rögzített CUDA/PyTorch/COLMAP/2DGS verziókkal (a 2DGS CUDA-rasterizerét a worker képében kell lefordítani).
- **Skálázás:** worker-autoskálázás a sor hossza alapján, spot/preemptible példányok checkpointtal.
- **Kétlépcsős eredmény (UX):** gyors, kis felbontású és kevés iterációs tanítás (néhány perc) → az app már ezt mutatja, majd a teljes minőségű kimenet cseréli le.
- **Állapotjelzés:** push-értesítés vagy webhook, és pollingolható státusz-endpoint (`GET /scans/{id}` → állapot, becsült hátralévő idő, hibaok).

---

## 13. Koordináta-konverzió

### 13.1 Kamera-koordinátarendszerek

| | ARKit | COLMAP |
|---|---|---|
| Kamera X | jobbra | jobbra |
| Kamera Y | **fel** | **le** |
| Kamera Z | **hátrafelé** (a kamera a −Z felé néz) | **előre** (a kamera a +Z felé néz) |
| Póz jelentése | camera-to-world | world-to-camera |
| Forgás a fájlban | mátrix | kvaternió `QW QX QY QZ` |

A konverzió: a kamera-oldali tengelyeket meg kell fordítani (Y és Z előjele), majd invertálni a pózt.

### 13.2 Python-példa

```python
import numpy as np
from scipy.spatial.transform import Rotation as Rot

FLIP_YZ = np.diag([1.0, -1.0, -1.0])

def arkit_c2w_to_colmap(T_c2w_colmajor):
    """T_c2w_colmajor: 16 float, ARKit oszlop-major camera-to-world."""
    T = np.array(T_c2w_colmajor, dtype=np.float64).reshape(4, 4).T  # -> sor-major
    R_c2w = T[:3, :3] @ FLIP_YZ           # kameratengelyek átfordítása
    t_c2w = T[:3, 3]
    R_w2c = R_c2w.T
    t_w2c = -R_w2c @ t_c2w
    qx, qy, qz, qw = Rot.from_matrix(R_w2c).as_quat()  # scipy: x,y,z,w
    return (qw, qx, qy, qz), t_w2c

def write_colmap_text(poses, out_dir, image_ext=".jpg"):
    """poses: lista a poses.jsonl sorairól (dict)."""
    cam = poses[0]["intrinsics"]
    with open(f"{out_dir}/cameras.txt", "w") as f:
        f.write("# CAMERA_ID MODEL WIDTH HEIGHT PARAMS[]\n")
        f.write(f'1 PINHOLE {cam["w"]} {cam["h"]} '
                f'{cam["fx"]} {cam["fy"]} {cam["cx"]} {cam["cy"]}\n')
    with open(f"{out_dir}/images.txt", "w") as f:
        f.write("# IMAGE_ID QW QX QY QZ TX TY TZ CAMERA_ID NAME\n")
        for i, p in enumerate(poses, start=1):
            (qw, qx, qy, qz), t = arkit_c2w_to_colmap(p["T_c2w"])
            f.write(f'{i} {qw} {qx} {qy} {qz} {t[0]} {t[1]} {t[2]} 1 '
                    f'{p["id"]}{image_ext}\n\n')   # üres sor: nincs 2D pont
    open(f"{out_dir}/points3D.txt", "w").close()
```

### 13.3 Kritikus részletek

- **Intrinsics a képhez tartozik.** Ha a képet leskálázod, skálázd az `fx, fy, cx, cy` értékeket is ugyanazzal az arányszámmal. Ha külön magas felbontású stillt használsz, annak az intrinsics-ét (és pózát) használd, ne az élő frame-ét.
- **Tájolás:** az ARKit `capturedImage` mindig a szenzor natív (landscape) tájolásában van, függetlenül a telefon tartásától. Ne forgasd, vagy ha mégis, az intrinsics-et és a pózt is konzisztensen kell forgatni. A legegyszerűbb: soha ne forgasd el.
- **Kameramodell:** az iPhone-képek gyakorlatilag torzításmentesek a platform feldolgozása után, ezért `PINHOLE` modell megfelel. Ha a felhős BA finomítja az intrinsics-et (`SIMPLE_RADIAL`), az utolsó lépésben **undistortolni kell** a képeket (`colmap image_undistorter`), mert a 2DGS pinhole-modellt vár.
- **Mátrix-sorrend:** a `simd_float4x4` oszlop-major, egy elgépelt transzponálás teljesen szétrombolja a scant.
- **Ellenőrzés:** konverzió után mindig renderelj kamera-frustumokat (például Open3D-vel), és nézd meg, hogy körbejárják-e a tárgyat, a helyes irányba néznek-e.

---

## 14. 2DGS tanítás és mesh-kinyerés

### 14.1 Adatkönyvtár a tanításhoz

```
dataset/
├── images/                 # undistortolt, pinhole
│   ├── 000001.jpg
│   └── ...
└── sparse/
    └── 0/
        ├── cameras.bin (vagy .txt)
        ├── images.bin  (vagy .txt)
        ├── points3D.bin (vagy .txt)
        └── points3D.ply   # ha a LiDAR-kiegészített init-et használod
```

### 14.2 Tanítási parancsok (a hivatalos repo alapján; ellenőrizd az aktuális README-t)

```bash
# Tanítás
python train.py -s dataset -m output/scan_001 \
    --depth_ratio 0 \        # 0: átlag-mélység (korlátlan/nyitott jelenetek), 1: medián-mélység (korlátos, tárgy-jelenetek)
    --lambda_normal 0.05 \
    --lambda_dist 1000       # korlátos/tárgy-jelenet kiindulási érték; nyitott jeleneteknél kisebb (pl. 100)

# Mesh-kinyerés TSDF-fel
python render.py -m output/scan_001 -s dataset \
    --skip_train --skip_test \
    --depth_ratio 1 \
    --voxel_size 0.004 --sdf_trunc 0.02 --depth_trunc 3.0
```

Megjegyzések:

- A `--depth_ratio` a TSDF-hez használt mélység típusát választja. Tárgyaknál (korlátos jelenet) a medián-mélység általában élesebb felületet ad, nyitott jelenetnél az átlag-mélység stabilabb. Próbáld ki mindkettőt a saját adatodon.
- A `lambda_dist` (eloszlás-regularizáció) és `lambda_normal` (normál-konzisztencia) értékeit **méréssel hangold**, mert jelenettípustól függenek.
- A mesh-paraméterek (`voxel_size`, `sdf_trunc`, `depth_trunc`) méterben értendők, ezért fontos a metrikus skála. Ha a jelenet nem metrikus, ezeket a jelenet méretéhez kell igazítani. Tárgy-módban a `depth_trunc` a kamera–tárgy távolság 1,5–2-szerese legyen, tér-módban a szoba mérete.
- Iterációszám: alapértelmezés 30 000. A gyors előnézethez 5 000–10 000 iteráció és kisebb felbontás (`-r 2` vagy `-r 4`) elég.

### 14.3 Hangolási szempontok

| Probléma | Lehetséges ok | Teendő |
|---|---|---|
| Duplázott felületek, „héjak" | Pózhiba, vagy kevés `lambda_dist` | Jobb pózfinomítás; `lambda_dist` növelése |
| Zajos, buborékos felület | Alacsony lefedettség, blur | Több szög, éles képek; `lambda_normal` növelése |
| Lebegő artefaktok | Rossz init, háttérpontok | Maszkolás, init-szűrés, tisztítás utólag |
| Lyukak a meshben | Hiányzó lefedettség | Az appban jobb lefedettség-vezetés |
| Torz mesh a szélén | `depth_trunc` túl nagy/kicsi | Állítsd a jelenet méretéhez |
| Színingadozás | Expozíció-változás | Expozíciózár az appban; felhős normalizálás |

### 14.4 Mesh-utómunka

- Legnagyobb összefüggő komponens megtartása, lebegő darabok törlése (Open3D/trimesh).
- Opcionális egyszerűsítés/simítás.
- Export: `.ply` és `.glb`/`.obj`. A splat-kimenet (surfelek) külön tömörített formátumban a webes nézőhöz.

---

## 15. Minőségkapuk és hibakezelés

A felhő az első lépésben automatikusan ellenőriz, és **konkrét, a felhasználónak szóló üzenettel** utasít el vagy figyelmeztet.

| Ellenőrzés | Kiindulási küszöb | Ha nem teljesül |
|---|---|---|
| Keyframe-ek száma | ≥ 60 (tárgy), ≥ 120 (tér) | Elutasítás: „Túl kevés kép, készíts hosszabb scant" |
| Regisztrált képek aránya az SfM után | ≥ 90–95% | Figyelmeztetés vagy elutasítás |
| Átlagos újravetítési hiba (reprojection error) | < 1,0 px | Figyelmeztetés, hibrid fallback |
| Átlagos élesség / blur | a képek ≥ 90%-a a küszöb alatt | Elutasítás vagy szűrés |
| Lefedettség-pontszám (appból + szerveroldali ellenőrzés) | ≥ 0,7 | Javaslat az újrascannelésre |
| Póz-ugrások (követés-vesztés miatt) | nincs nagy ugrás | Szekvencia-szegmentálás, vagy figyelmeztetés |
| Kép-fényesség / expozíció-szórás | a szórás korlátos | Figyelmeztetés |
| Fájlintegritás | checksum egyezik | Újrafeltöltés kérése |

**Hibaüzenetek az appban** legyenek emberiek és cselekvésre irányuljanak („A bal oldal nincs lefedve, próbáld újra a tárgy körüli teljes körrel"), ne technikai kódok.

**Újrapróbálkozás:** az átmeneti hibák (hálózat, worker leáll) automatikusan újrapróbálkozzanak, a végleges hibáknál a felhasználó kapjon „Újrapróbálom" és „Törlöm" lehetőséget.

---

## 16. Tesztelés és mérőszámok

### 16.1 Felhős minőség

- **Hold-out nézetek:** minden 8. képet ne használj tanításra, és mérd rajtuk a PSNR/SSIM/LPIPS értékeket.
- **Geometria:** ha van LiDAR, hasonlítsd a 2DGS-mesh pontjait a LiDAR-fúzióhoz (Chamfer-távolság), vagy ismert méretű tárgy (például egy 10 cm-es kocka) mérete alapján ellenőrizd a metrikus pontosságot.
- **Regisztrációs mutatók:** regisztrált képek aránya, reprojection error.

### 16.2 Capture-minőség

- Az appból számolt **lefedettség-pontszám** és a végső PSNR/Chamfer közötti korreláció. Ha nincs összefüggés, a pontszámot át kell hangolni.
- **Felhasználói tesztek:** különböző tárgytípusok (kicsi tárgy, bútor, szoba, kültéri), különböző felhasználók, különböző fényviszonyok, és mérd, hány scan sikeres első próbára.
- **Teljesítmény:** akkumulátor-fogyasztás, hőmérséklet, képkockasebesség 5 perces scan alatt régebbi készülékeken is.

### 16.3 Regressziós tesztkészlet

Tarts fenn 10–20 referencia-scant (a nyers csomaggal), amelyeken minden pipeline-változtatás után lefuttatod a felhős feldolgozást, és összehasonlítod a mérőszámokat.

---

## 17. Ütemterv

**1. mérföldkő: Adatgyűjtő MVP (2–4 hét)**
- ARKit-session, kamera-előnézet, REC/STOP/szünet, időzítő.
- Keyframe-kiválasztás (mozgás + blur-becslés), lemezre írás, manifest és poses.jsonl.
- Kézi feltöltés, és a felhős oldalon a konverter (13. fejezet) + COLMAP + 2DGS futtatása scripttel.
- **Cél:** egy scan végigmegy az egész láncon, és látod az eredményt.

**2. mérföldkő: Élő előnézet és vezetés (3–5 hét)**
- Mélység-alapú surfel-renderer Metalban, voxel-hash.
- Lefedettség-modul (tárgy-dóm, majd tér-mód), dinamikus tanácsok.
- Expozíció/fókusz zárolása, hőkezelés.

**3. mérföldkő: Robusztus feltöltés és felhő (3–4 hét)**
- Resumable háttérfeltöltés, job-sor, GPU worker konténer, státuszkövetés, értesítések.
- Minőségkapuk és felhasználóbarát hibaüzenetek.
- Kétlépcsős (gyors + teljes) tanítás.

**4. mérföldkő: Minőség és finomítás (folyamatos)**
- Hibrid pózfinomítás, LiDAR-kiegészített init, opcionális mélység-prior.
- Hangolás a jelenettípusokra, mesh-utómunka, tömörített megosztási formátum.
- Android-támogatás, ha szükséges.

---

## 18. Ellenőrzőlista

**Capture (app)**
- [ ] Expozíció, fókusz, fehéregyensúly zárolva a felvétel alatt
- [ ] Keyframe csak `normal` követési állapotban íródik
- [ ] Blur-becslés szűri a homályos képeket
- [ ] Keyframe-ek eloszlása lefedettség-alapú, nem csak időalapú
- [ ] A kép natív tájolásban mentve, intrinsics a mentett képhez tartozik
- [ ] Minden keyframe-hez: póz, intrinsics, időbélyeg, expozíció, követési állapot
- [ ] Mélység + konfidencia mentve (ha van)
- [ ] Folyamatos lemezre írás, összeomlás-helyreállítás
- [ ] Szünet/folytatás relokalizációval
- [ ] Hőkezelés: az előnézet csökken, a rögzítés nem

**Feltöltés**
- [ ] Resumable, chunkolt, checksummal
- [ ] Háttérben is fut
- [ ] Wi-Fi/töltés szabály beállítható

**Felhő**
- [ ] Validálás és minőségkapuk az elején
- [ ] ARKit → COLMAP konverzió ellenőrizve (frustum-vizualizáció)
- [ ] Hibrid pózfinomítás, Sim(3)-illesztés a metrikus skálához
- [ ] Undistortolt, pinhole képek a 2DGS-nek
- [ ] LiDAR-kiegészített init (opcionális, de ajánlott)
- [ ] `depth_ratio`, `lambda_dist`, `lambda_normal` jelenettípusonként hangolva
- [ ] Mesh-paraméterek (`voxel_size`, `sdf_trunc`, `depth_trunc`) a jelenet méretéhez igazítva
- [ ] Gyors előnézeti kör + teljes kör
- [ ] Értesítés és hibaüzenetek a felhasználónak

---

### Zárásként

A Scaniverse-hez hasonló élményt a **jó élő visszajelzés** adja (a felhasználó lássa, mi hiányzik), a 2DGS-hez szükséges minőséget pedig a **pontos pózok, éles és több szögből készült képek, zárolt expozíció és a felhős pózfinomítás**. Ha ezek megvannak, a tanítás már csak hangolás kérdése. A fejlesztést érdemes az adatgyűjtő MVP-vel kezdeni, és minél előbb végigvinni egy valódi scant a teljes láncon, mert a legtöbb hiba (koordináta-konverzió, intrinsics, tájolás) csak így derül ki.
