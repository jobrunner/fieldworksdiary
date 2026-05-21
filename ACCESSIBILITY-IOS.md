# Accessibility Rules für Refactoring — iOS / Swift

Diese Regeln gelten für **alle** UI-Refactorings in diesem Repository
(SwiftUI und UIKit).
Bei Konflikt mit Style-Vorgaben oder Design-Tokens **gewinnt diese Datei** —
in dem Fall ist das Design-System der Bug, nicht die Komponente.

---

## Zielbild & Testkriterien

Eine Komponente gilt als zugänglich, wenn auf allen folgenden Stufen
**nichts abgeschnitten wird, kein Tap-Target unter Mindestgröße fällt
und die VoiceOver-Ausgabe sinnvoll bleibt**:

- **Dynamic Type** von `xSmall` bis `accessibility5` (AX5) ohne Clipping.
- **VoiceOver** aktiv: jede interaktive Komponente hat Label, Trait und ggf. Value.
- **Reduce Motion** aktiv: keine essenziellen Übergänge gehen verloren.
- **Increase Contrast** aktiv: Borders und Text bleiben gut lesbar.
- **Tap-Target ≥ 44 × 44 pt** (Apple HIG).

---

## 1. Layout & Dynamic Type

### 1.1 SwiftUI

**Tun:**

- Schriften über semantische Styles: `.font(.body)`, `.font(.headline)`,
  `.font(.title2)` — skalieren automatisch.
- Eigene Größen mit Skalierungsanker:
  `Font.custom("Inter", size: 16, relativeTo: .body)`.
- Mit Text mitwachsende Dimensionen:
  `@ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 24`.
- Mehrere Layouts je Schriftgröße via `ViewThatFits`
  (horizontaler Stack normal, vertikaler Stack auf AX-Größen).
- `.lineLimit(nil)` oder weglassen statt `.lineLimit(1)`.
- Bei festen Breiten: `.frame(minWidth: …, maxWidth: .infinity)` und wrappen lassen.

**Lassen:**

- `.font(.system(size: 16))` ohne `relativeTo:` — ignoriert Dynamic Type.
- `.frame(height: 44)` auf Buttons mit Text → `.frame(minHeight: 44)`.
- `.fixedSize()` auf Text in begrenzten Containern → Clipping bei AX-Größen.
- Hartkodierte Spacing-Werte für Layouts, die mit Schrift atmen sollten —
  `@ScaledMetric` nehmen.

### 1.2 UIKit

**Tun:**

- `label.font = UIFont.preferredFont(forTextStyle: .body)`
- `label.adjustsFontForContentSizeCategory = true`
- `label.numberOfLines = 0` als Default
- Auto Layout über intrinsic content size; keine festen Höhen-Constraints
  auf Text-Containern.
- Auf `UIContentSizeCategoryDidChangeNotification` reagieren, wenn das Layout
  bei AX-Größen umgebaut werden muss.

**Lassen:**

- `UIFont.systemFont(ofSize: 14)` → durch `preferredFont(forTextStyle:)` ersetzen.
- Feste Höhen-Constraints auf Labels und Text-Buttons.

## 2. VoiceOver / Accessibility API

### 2.1 SwiftUI

**Tun:**

- `.accessibilityLabel("Warenkorb öffnen")` auf Icon-only-Buttons.
- `.accessibilityHint("Öffnet die Warenkorb-Übersicht")` **nur**, wenn die
  Aktion nicht aus dem Label hervorgeht.
- `.accessibilityValue("3 Artikel")` für Stepper, Slider, Counter.
- `.accessibilityHidden(true)` auf rein dekorative Bilder.
- Gruppieren: `.accessibilityElement(children: .combine)` auf Cards/Rows,
  damit VoiceOver einmal die ganze Karte vorliest, nicht jedes Atom.
- Header markieren: `.accessibilityAddTraits(.isHeader)` auf Section-Titel.
- Statusansagen: `AccessibilityNotification.Announcement("In den Warenkorb gelegt").post()`
  (iOS 17+) bzw. `UIAccessibility.post(notification: .announcement, argument: ...)`.
- Modal-Inhalt: `.accessibilityAddTraits(.isModal)`.
- Wenn visuelle Reihenfolge ≠ logische Reihenfolge:
  `.accessibilitySortPriority(...)`.

**Lassen:**

- `Image(systemName: "cart")` als Button-Inhalt **ohne** `.accessibilityLabel`
  → VoiceOver sagt sonst „cart" statt der Aktion.
- `.accessibilityLabel` auf Views, die schon sichtbaren Text haben.
- Custom-„Buttons" aus `TapGesture` auf `Rectangle` — echten `Button` nehmen,
  bringt Rolle und Fokus-Verhalten gratis.

### 2.2 UIKit

**Tun:**

- `isAccessibilityElement = true` auf Custom-Views, die als Einheit gelesen werden sollen.
- `accessibilityLabel`, `accessibilityHint`, `accessibilityValue`,
  `accessibilityTraits` explizit setzen.
- Bei Composite-Views mit mehreren sinnvollen Sub-Elementen:
  `accessibilityElements = [...]` in der gewünschten Reihenfolge.
- Nach Navigationswechseln:
  `UIAccessibility.post(notification: .screenChanged, argument: focusedView)`.

## 3. System-Settings respektieren

```swift
@Environment(\.accessibilityReduceMotion)              private var reduceMotion
@Environment(\.accessibilityReduceTransparency)        private var reduceTransparency
@Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
@Environment(\.colorSchemeContrast)                    private var contrast       // .standard / .increased
@Environment(\.accessibilityInvertColors)              private var invertColors
@Environment(\.dynamicTypeSize)                        private var dynamicTypeSize // iOS 15+
```

- `reduceMotion` → Animation auslassen oder `.transaction { $0.animation = nil }`.
- `differentiateWithoutColor` → zusätzliches Icon/Shape für Status
  (rot/grün allein reicht nicht).
- `contrast == .increased` → kräftigere Borders, weniger Transparenz, höhere Opacity.
- `dynamicTypeSize.isAccessibilitySize` → ggf. komplettes Layout umstellen
  (`ViewThatFits`, vertikale statt horizontale Stacks).

## 4. Interaktion

- Tap-Target ≥ **44 × 44 pt** (Apple HIG); bei kleineren visuellen Elementen
  per `.contentShape(Rectangle())` + Padding vergrößern.
- Custom-Gesten haben einen Standard-Pfad (Button oder Menü).
- Swipe-Aktionen in Listen zusätzlich über `.contextMenu` anbieten.

## 5. Anti-Pattern-Checkliste (Search & Destroy)

Vor jedem PR per Grep prüfen:

```
.font(.system(size:           → relativeTo: ergänzen oder semantischen Style nehmen
UIFont.systemFont(ofSize:     → preferredFont(forTextStyle:) ersetzen
.frame(height:                → minHeight: prüfen, wenn Text drin
.lineLimit(1)                 → Truncation gewollt? Dokumentieren.
.fixedSize(                   → Clipping-Risiko bei AX-Größen
Image(systemName:.*Button     → .accessibilityLabel vorhanden?
isAccessibilityElement = false → Begründung als Kommentar?
```

---

## Was Claude Code beim Refactoring konkret tun soll

1. **Diese Datei lesen, bevor eine UI-Komponente angefasst wird.**
2. Nach dem Refactoring die **Anti-Pattern-Checkliste** per Grep über die
   geänderten Dateien laufen lassen.
3. Bei layout- oder schriftrelevanten Änderungen im PR-Body kurz vermerken,
   auf welchen Stufen geprüft wurde (z. B. „getestet bei AX3",
   „VoiceOver-Pass via Accessibility Inspector").
4. Bei Unsicherheit: **SwiftUI-Built-in bevorzugen** (`Button`, `Label`,
   `Toggle`, `Stepper` …) — bringt korrekte Traits und Fokus-Verhalten gratis.
5. Wo möglich UI-Tests ergänzen, die mit aktiviertem VoiceOver oder bei
   AX5-Schrift laufen, und vor dem PR einmal durch den Accessibility Inspector
   klicken.
