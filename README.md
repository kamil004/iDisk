# iDisk — Narzędzia do zarządzania dyskami na macOS

**iDisk** to aplikacja macOS napisana w Swift/SwiftUI, która oferuje kompletne narzędzia do diagnostyki, testowania i zarządzania dyskami — zarówno wewnętrznymi, jak i zewnętrznymi (USB, USB-C, karta SD, NVMe).

Wersja: **0.4.5** · macOS 14+ · Swift 5.10

---

## 📸 Zrzuty ekranu

| # | Opis |
|---|------|
| 1 | [Ekran główny — SMART](iDisk/main1.jpg) — widok dysków i danych SMART |
| 2 | [Szczegóły SMART](iDisk/main2.jpg) — panel szczegółowych atrybutów SMART |
| 3 | [Test prędkości](iDisk/main3.jpg) — benchmark odczytu/zapisu |
| 4 | [Formatowanie](iDisk/main4.jpg) — formatowanie i niskopoziomowe nadpisywanie |
| 5 | [Obraz dysku](iDisk/main5.jpg) — tworzenie i przywracanie obrazów |

---

## ✨ Funkcje

### 1. 📊 Dyski i SMART — diagnostyka zdrowotna

Wyświetla wszystkie podłączone dyski (wewnętrzne i zewnętrzne) z danymi **SMART** (Self-Monitoring, Analysis and Reporting Technology).

- **Automatyczne wykrywanie** — lista dysków aktualizowana po podłączeniu/zamontowaniu
- **Pełne dane SMART** — model, serial, firmware, typ interfejsu (SATA, NVMe, USB bridge), pojemność
- **Stan zdrowotny** — „Sprawny" / „USZKODZONY" / „Niedostępne" z wizualnym oznaczeniem
- **Kluczowe atrybuty SMART** — godziny pracy (z konwersją na lata/dni), mocne sektory, temperatura, cykle zasilania
- **Tabela wszystkich atrybutów** — ID, wartość bieżąca, najgorsza, próg, wartość surowa
- **Surowy wynik smartctl** — rozwijany panel z pełnym outputem narzędzia
- **Obsługa mostków USB** — automatyczne próbowanie trybów `-d sat`, `-d auto` dla dysków zewnętrznych

> **Wymaganie:** narzędzie `smartctl` z [smartmontools](https://www.smartmontools.org/). Zainstaluj przez: `brew install smartmontools`

---

### 2. ⚡ Test prędkości — benchmark I/O

Precyzyjny benchmark odczytu i zapisu z pominięciem cache systemowego (`F_NOCACHE`), używający surowych liczników I/O.

- **Tryb testu:**
  - **Wolumen / dysk** — wybierz zamontowany wolumen z listy
  - **Katalog** — wybierz dowolny folder na dysku
- **Rozmiar testu:** 256 MB, 512 MB, 1 GB, 2 GB, 4 GB
- **Rozmiar bloku:** 1 MiB, 32 MiB, 64 MiB (zapis sekwencyjny)
- **Test szybki** — tylko sekwencyjny zapis/odczyt (bez losowych 4 KiB)
- **Test pełny** — dodaje losowy zapis/odczyt 4 KiB (symulacja obciążenia produkcyjnego)
- **Wyniki z paskami:**
  - Zapis sekwencyjny (blok wybranego rozmiaru)
  - Odczyt sekwencyjny
  - Zapis losowy 4K (opcjonalnie)
  - Odczyt losowy 4K (opcjonalnie)
- **Animowane paki postępu** z maksymalną skalą dostosowaną do najlepszych wyników
- **Pliki tymczasowe** są automatycznie usuwane po teście

---

### 3. 💾 Formatowanie — wolumeny i niskopoziomowe nadpisywanie

Zaawansowane narzędzie do formatowania dysków wymiennych (pendrive, karty SD, dyski zewnętrzne).

- **Wykrywanie dysków** — automatyczna lista zewnętrznych urządzeń z informacjami (interfejs, system plików, pojemność, liczba wolumenów)
- **Obsługa wolumenów** — wybór konkretnego wolumenu lub całego dysku (bez partycji)
- **Systemy plików:**
  - **APFS** — nowoczesny format Apple (dla SSD/NVMe)
  - **Mac OS Extended (Journaled)** — klasyczny HFS+ (dla kompatybilności)
  - **exFAT** — uniwersalny (Windows + macOS), obsługa > 4 GB plików
  - **MS-DOS (FAT32)** — maksymalna kompatybilność, limit 4 GB pliku
- **Nazwa wolumenu** — dowolna nazwa do nadania po formacie
- **Low Level Format** — nadpisanie całego dysku zerami, kasuje partycje i wszystkie dane bezpowrotnie, następnie tworzy nowy system plików
- **Czyszczenie indeksu Spotlight** — usuwa `.Spotlight-V100` i blokuje ponowne indeksowanie (przez `.metadata_never_index`)
- **Montowanie / odmontowywanie** — ręczna kontrola nad zamontowaniem dysku
- **Wykres prędkości w czasie** — wykres liniowy z oknem 60 sekund, pokazujący zmianę prędkości zapisu (MiB/s) w czasie rzeczywistym
- **ETA** — szacowany czas pozostały do zakończenia operacji
- **Log operacji** — szczegółowy zapis wszystkich kroków z podziałką czasową

---

### 4. 🧪 Prawdziwa pojemność — wykrywanie fałszywych nośników

Test, który wypełnia wolne miejsce na nośniku danymi i weryfikuje ich integralność — wykrywa dyski, które **zgłaszają większą pojemność niż faktycznie mają**.

- **Tryby testu:**
  - **1× — tylko zapis wolnego miejsca** — szybki test podstawowy
  - **2.2× — wykrywa zamianę/powielenie danych** — dwukrotne wypełnienie wychwytuje firmware „zawijające" adresy (typowe dla podróbek)
- **Rozmiar pliku testowego:** 64 MB, 128 MB, 256 MB, 512 MB, 1 GB (im mniejszy, tym dokładniejsze wykrycie granicy)
- **Deterministyczny wzorzec** — zapisuje powtarzalny pattern, czyta i porównuje bajt po bajcie
- **Wyniki:**
  - Deklarowane wolne miejsce vs zapisano vs poprawne dane
  - Ilość uszkodzonych/brakujących danych
  - Czas zapisu i odczytu + średnie prędkości
  - **Werdykt:** Pojemność zgodna / Nośnik mniejszy / Fałszywa pojemność
- **Opcjonalne usuwanie** — pliki testowe mogą być usunięte po zakończeniu
- **Log szczegółowy** — każdy krok zapisywany z informacjami o postępie

> **Idealne do weryfikacji tanich pendrive'ów i kart SD z rynku — wykrywa podróbki 500 GB / 1 TB, które w rzeczywistości mają 32 GB.**

---

### 5. 🖼️ Obraz dysku — tworzenie i przywracanie

Tworzenie i przywracanie pełnych obrazów dysków i wolumenów w formatach DMG lub IMG.

- **Zakres:**
  - **Cały dysk** — kopia bajt-po-bajcie całego urządzenia
  - **Wolumen** — tylko wybrany zamontowany wolumen
- **Formaty:**
  - **DMG (UDZO)** — skompresowany, mniejszy plik, natywny format Apple
  - **IMG (UDTO)** — surowy, 1:1 bez kompresji (identyczny z urządzeniem, sprawdzony przez `cmp`)
- **Tworzenie obrazu:**
  - Wybór źródła (dysk/wolumen) i formatu
  - Wybieranie pliku docelowego z domyślną nazwą (z timestampem)
  - Postęp w czasie rzeczywistym z prędkością i ETA
  - Automatyczne odmontowanie i ponowne zamontowanie źródła
- **Przywracanie obrazu:**
  - Wybór pliku obrazu i dysku docelowego
  - Kopiowanie surowe przez `/dev/r*` (szybkie, bajt-po-bajcie)
  - Detekcja braku uprawnień z instrukcją konfiguracji FDA
- **Sprawdzenie uprawnień FDA** — diagnostyka Pełnego Dostępu do Dysku (TCC.db probe, designated requirement)
- **Bezpieczeństwo** — walidacja że obraz ≠ dysk docelowy, potwierdzenie przed operacją

> **Uwaga o uprawnieniach:** Tworzenie obrazów (DMG i IMG) działa bez dodatkowych uprawnień. Przywracanie obrazu na dysk wymaga **Pełnego dostępu do dysku** w Ustawieniach systemowych.

---

## 🛠️ Budowanie z źródła

```bash
# Klonowanie
git clone https://github.com/kamil004/iDisk.git
cd iDisk

# Budowanie (wymaga Xcode 15+ / Swift 5.10)
swift build

# Uruchomienie aplikacji
swift run iDisk

# Uruchomienie narzędzi pomocniczych
swift run BenchTest
swift run DumpDevices

# Testy jednostkowe
swift test
```

---

## 📦 Instalacja

1. Pobierz najnowszą wersję z [Releases](https://github.com/kamil004/iDisk/releases)
2. Rozpakuj archiwum `.zip`
3. Przenieś `iDisk.app` do `Applications`
4. Otwórz aplikację — pierwszego uruchomienia mogą wymagać uprawnień:
   - **Pełny dostęp do dysku** — dla przywracania obrazów (Ustawienia → Prywatność i bezpieczeństwo)
   - **smartctl** — dla funkcji SMART (`brew install smartmontools`)

---

## 🏗️ Architektura

| Target | Opis |
|--------|------|
| `Core` | Biblioteka współdzielona — logika biznesowa (SMART, benchmark, formatowanie, pojemność, obrazowanie) |
| `iDisk` | Aplikacja główna — interfejs SwiftUI z 5 zakładkami |
| `BenchTest` | Narzędzie CLI do testowania benchmarku |
| `DumpDevices` | Narzędzie CLI do debugowania wykrywania urządzeń |
| `CoreTests` | Testy jednostkowe (25 testów) |

### Kluczowe komponenty Core

- `Smart.swift` — parsowanie outputu `smartctl`, modelowanie atrybutów, lokalizacja polskich etykiet
- `Benchmark.swift` — benchmark z `F_NOCACHE`, wyrównane alokacje, test sekwencyjny i losowy 4K
- `CapacityTest.swift` — test pojemności z deterministycznymi wzorcami i weryfikacją integralności
- `Formatter.swift` — formatowanie przez `diskutil`, low-level format przez `dd`, wykresy prędkości
- `Devices.swift` — wykrywanie urządzeń przez IOKit (`IOServiceMatching("IOBSDNameMatching")`)
- `DiskImager.swift` — tworzenie/przywracanie obrazów przez `hdiutil` i `dd`

---

## 📄 Licencja

© 2025 Kamil Gorecki. Wszystkie prawa zastrzeżone.
