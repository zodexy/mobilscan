# SuGaR / 2DGS "Okosba" - Optimalizációs Stratégia

**Cél:** Költséghatékony, skálázható és gyors 3D Mesh kinyerés Gaussian Splatting technológiából, kiküszöbölve a magas szerverköltségeket és a COLMAP hibáit, hogy WASD-vel bejárható, Polycamet verő minőséget kapjunk.

## 1. COLMAP Elhagyása (ARKit Poses)
- **Probléma:** A COLMAP lassú (15-30 perc) és gyakran elrontja a kamera pozíciókat ("gömb" hiba).
- **Megoldás:** Az iOS appból kinyert ARKit Transform mátrixok és LiDAR mélységadatok közvetlen betáplálása a betanítási pipeline-ba.
- **Eredmény:** Azonnali inicializálás, nulla SfM (Structure from Motion) számítási idő a szerveren, stabilabb geometria.

## 2. Low-Res Betanítás, High-Res Textúrázás
- **Probléma:** 4K képeken betanítani a GS-t irdatlan mennyiségű VRAM-ot és GPU időt igényel.
- **Megoldás:** 
  1. A GS/SuGaR betanítását alacsony felbontású (pl. 512x512) képeken végezzük el. Ekkor a cél csak a megfelelő térbeli geometria (váz) elsajátítása.
  2. A kinyert Mesh-re utólagosan, hagyományos algoritmusokkal húzzuk rá az eredeti 4K felbontású képeket (Texture Baking).
- **Eredmény:** Brutális gyorsulás a tanulási fázisban, miközben a végső textúra minősége tűéles marad.

## 3. Early Stopping (Iterációk Vágása)
- **Probléma:** A kutatási referenciák 30,000 iterációig tanítják a modellt.
- **Megoldás:** B2B/B2C consumer alkalmazáshoz a mesh kinyeréséhez elegendő 3,000 - 5,000 iteráció is. A felület ezen a ponton már kellően összeáll.
- **Eredmény:** A Modal GPU bérlési idejének drasztikus (akár 80-90%-os) csökkentése.

## 4. 2D Gaussian Splatting (2DGS) Preferálása a SuGaR helyett
- **Probléma:** A SuGaR 3D gömbökből próbál felületet (mesh-t) csinálni, ami komplex és utófeldolgozás-igényes.
- **Megoldás:** 2DGS technológia vizsgálata. A 2DGS lapos "korongokat" használ, amelyek természetes módon rásimulnak a felületekre.
- **Eredmény:** Gyorsabb és tisztább Mesh extrakció kevesebb számítási kapacitással.

## 5. Serverless GPU (Modal)
- **Probléma:** Egy állandóan pörgő, dedikált AI GPU szerver havi $1000-2000.
- **Megoldás:** A projektben lévő `modal_app.py` architektúra megtartása. A10G vagy L4 GPU-k indítása csak arra a 2-3 percre, amíg a scan lefut.
- **Eredmény:** Extrém olcsó, 5-10 centes feldolgozási költség per scan.

---
**Következő technikai lépés:** Az iOS app oldalán biztosítani, hogy a képkockák mellé a pontos ARKit kamera póz (4x4 Transform Matrix) és az intrinsics adatok kimentésre kerüljenek, kompatibilis formátumban.
