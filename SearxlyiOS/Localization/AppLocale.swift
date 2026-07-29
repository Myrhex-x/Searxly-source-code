//
//  AppLocale.swift
//  SearxlyiOS
//
//  Language for the whole product:
//    • Default = **System** (device preferred language — any locale iOS exposes, not a short list).
//    • Optional override in Settings ▸ Language (App Language / Search Results).
//  Content (SearXNG, Wikipedia/Grokipedia, AI prompts, Accept-Language) always gets a real
//  language code for *any* system language. Chrome strings use `L()` with fr/es/de tables and
//  fall back to English when a translation isn't shipped yet.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppLocale {
    static let shared = AppLocale()

    private static let overrideKey = "searxly.ios.appLanguage"

    /// "" = follow the system. Otherwise an ISO language code from `supported`.
    var override: String {
        didSet {
            UserDefaults.standard.set(override, forKey: Self.overrideKey)
            if override.isEmpty {
                // Restore true system language for Form chrome / WebKit Accept-Language.
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                // Prefer the override, keep system language as secondary for fallbacks.
                var langs = [override]
                let sys = Self.systemLanguageCode
                if sys != override { langs.append(sys) }
                if !langs.contains("en") { langs.append("en") }
                UserDefaults.standard.set(langs, forKey: "AppleLanguages")
            }
        }
    }

    /// Active language code right now: optional override, else the device's preferred language
    /// (Korean, Japanese, Portuguese, … — not limited to languages we ship UI strings for).
    var languageCode: String {
        if !override.isEmpty { return Self.normalizeLanguageCode(override) }
        return Self.systemLanguageCode
    }

    /// English display name for model prompts ("Korean", "Japanese", "Portuguese", …) for *any* code.
    var languageNameForModel: String {
        Self.englishLanguageName(for: languageCode)
    }

    /// Wikipedia subdomain language (handles aliases like nb→no, iw→he).
    var wikipediaLanguageCode: String {
        Self.wikipediaCode(for: languageCode)
    }

    /// BCP-47 style tag for Accept-Language (keeps region when the system has one).
    var acceptLanguageHeader: String {
        if !override.isEmpty {
            return "\(override),\(Self.systemLanguageTag);q=0.8,en;q=0.5"
        }
        return "\(Self.systemLanguageTag),en;q=0.5"
    }

    private init() {
        override = UserDefaults.standard.string(forKey: Self.overrideKey) ?? ""
    }

    // MARK: - System resolution (any language)

    /// Primary language subtag of the device's preferred language (e.g. `ko`, `ja`, `zh`, `pt`).
    nonisolated static var systemLanguageCode: String {
        normalizeLanguageCode(systemLanguageTag)
    }

    /// Full preferred tag when available (`zh-Hans-CN`, `pt-BR`, `en-GB`, …).
    nonisolated static var systemLanguageTag: String {
        if let tag = Locale.preferredLanguages.first, !tag.isEmpty {
            return tag
        }
        if let code = Locale.current.language.languageCode?.identifier {
            return code
        }
        return "en"
    }

    /// Strip script/region to a stable language code SearXNG / Wikipedia understand.
    nonisolated static func normalizeLanguageCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "en" }
        // Locale parses BCP-47 properly (unlike String.prefix(2), which breaks 3-letter codes).
        let locale = Locale(identifier: trimmed.replacingOccurrences(of: "_", with: "-"))
        let code = locale.language.languageCode?.identifier
            ?? trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            ?? trimmed
        let lower = code.lowercased()
        switch lower {
        case "iw": return "he"   // legacy Hebrew
        case "in": return "id"   // legacy Indonesian
        case "ji": return "yi"   // legacy Yiddish
        case "jw": return "jv"   // legacy Javanese
        default: return lower
        }
    }

    /// English name for LLMs / debugging — works for every ISO code the system knows.
    nonisolated static func englishLanguageName(for code: String) -> String {
        let c = normalizeLanguageCode(code)
        return Locale(identifier: "en").localizedString(forLanguageCode: c)
            ?? Locale.current.localizedString(forLanguageCode: c)
            ?? c
    }

    /// Native endonym for pickers ("日本語", "한국어", "Português").
    nonisolated static func nativeLanguageName(for code: String) -> String {
        let c = normalizeLanguageCode(code)
        return Locale(identifier: c).localizedString(forLanguageCode: c)
            ?? englishLanguageName(for: c)
    }

    /// Wikipedia / MediaWiki language path segment.
    nonisolated static func wikipediaCode(for code: String) -> String {
        switch normalizeLanguageCode(code) {
        case "nb", "nn": return "no"   // Bokmål/Nynorsk → no.wikipedia.org
        case "zh": return "zh"
        default: return normalizeLanguageCode(code)
        }
    }

    /// Languages offered for optional override. Includes a broad world list + every language the
    /// user has enabled on the device. Content still follows *any* system language even if it is
    /// not listed here (System / Automatic resolve via `systemLanguageCode`).
    nonisolated static let supported: [SearchLanguage] = {
        var codes = Set(coreLanguageCodes)
        for pref in Locale.preferredLanguages {
            codes.insert(normalizeLanguageCode(pref))
        }
        // OS catalog: every identifier that yields a real language name.
        for id in Locale.availableIdentifiers {
            let code = normalizeLanguageCode(id)
            guard (2...3).contains(code.count), code != "und" else { continue }
            let en = englishLanguageName(for: code)
            let native = nativeLanguageName(for: code)
            // Keep codes the system can actually name (filters garbage like "mul").
            if en != code || native != code { codes.insert(code) }
        }

        let preferred = Locale.preferredLanguages.map { normalizeLanguageCode($0) }
        return codes.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? Int.max
            let ib = preferred.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return nativeLanguageName(for: a)
                .localizedCaseInsensitiveCompare(nativeLanguageName(for: b)) == .orderedAscending
        }
        .map { SearchLanguage(code: $0, label: nativeLanguageName(for: $0)) }
    }()

    /// Broad set used by search engines and Wikipedia (any system language still works beyond this).
    nonisolated private static let coreLanguageCodes: [String] = [
        "en", "fr", "es", "de", "it", "pt", "nl", "pl", "ru", "uk", "be", "tr", "ar", "he", "fa",
        "hi", "bn", "ta", "te", "mr", "gu", "pa", "ur", "kn", "ml", "or", "as", "ne", "si",
        "ja", "ko", "zh", "th", "vi", "id", "ms", "tl", "jv", "su",
        "sv", "da", "fi", "no", "nb", "nn", "is", "fo",
        "cs", "sk", "ro", "hu", "el", "bg", "hr", "sr", "bs", "sl", "mk", "sq", "lt", "lv", "et",
        "ca", "eu", "gl", "ga", "cy", "gd", "br", "mt", "lb", "rm",
        "az", "ka", "hy", "kk", "uz", "ky", "tg", "tk", "mn", "tt", "ba", "cv",
        "sw", "am", "om", "ti", "so", "rw", "rn", "ny", "sn", "zu", "xh", "st", "tn", "ts",
        "yo", "ig", "ha", "ff", "wo", "bm",
        "my", "km", "lo", "bo", "dz", "ug", "ps", "sd", "ku", "ckb", "yi", "la", "eo", "af",
    ]
}

/// Translate an interface string. The English text is the key; unknown key or language falls
/// back to English. Calling this inside a view body subscribes the view to language changes.
/// Content language (search / wiki / AI) still follows `AppLocale.languageCode` for *any* system
/// language even when no chrome translation exists.
@MainActor
func L(_ english: String) -> String {
    let lang = AppLocale.shared.languageCode
    guard lang != "en" else { return english }
    // Prefer exact code, then generic base (pt-BR→pt already normalized).
    if let t = L10nTable.strings[english]?[lang] { return t }
    return english
}

/// Interface translations. Keys are the English strings as written in code.
/// Covered: fr, es, de (others fall back to English until their tables land).
enum L10nTable {
    nonisolated static let strings: [String: [String: String]] = [
        // ── Tabs & menus ──
        "New Tab": ["fr": "Nouvel onglet", "es": "Nueva pestaña", "de": "Neuer Tab"],
        "New Private Tab": ["fr": "Nouvel onglet privé", "es": "Nueva pestaña privada", "de": "Neuer privater Tab"],
        "Close Tab": ["fr": "Fermer l'onglet", "es": "Cerrar pestaña", "de": "Tab schließen"],
        "Close All Tabs": ["fr": "Fermer tous les onglets", "es": "Cerrar todas las pestañas", "de": "Alle Tabs schließen"],
        "Close Other Tabs": ["fr": "Fermer les autres onglets", "es": "Cerrar otras pestañas", "de": "Andere Tabs schließen"],
        "Recently Closed": ["fr": "Fermés récemment", "es": "Cerradas recientemente", "de": "Kürzlich geschlossen"],
        "Close Tabs & Clear Data": ["fr": "Fermer les onglets et effacer les données", "es": "Cerrar pestañas y borrar datos", "de": "Tabs schließen & Daten löschen"],
        "Duplicate Tab": ["fr": "Dupliquer l'onglet", "es": "Duplicar pestaña", "de": "Tab duplizieren"],
        "Switch to Tab": ["fr": "Passer à l'onglet", "es": "Cambiar a pestaña", "de": "Zu Tab wechseln"],
        "Search Tabs": ["fr": "Rechercher dans les onglets", "es": "Buscar pestañas", "de": "Tabs durchsuchen"],
        // ── Page actions ──
        "Settings": ["fr": "Réglages", "es": "Ajustes", "de": "Einstellungen"],
        "Find on Page…": ["fr": "Rechercher dans la page…", "es": "Buscar en la página…", "de": "Auf der Seite suchen…"],
        "Text Size": ["fr": "Taille du texte", "es": "Tamaño del texto", "de": "Textgröße"],
        "Smaller": ["fr": "Plus petit", "es": "Más pequeño", "de": "Kleiner"],
        "Larger": ["fr": "Plus grand", "es": "Más grande", "de": "Größer"],
        "Default Size": ["fr": "Taille par défaut", "es": "Tamaño predeterminado", "de": "Standardgröße"],
        "Request Desktop Website": ["fr": "Version pour ordinateur", "es": "Versión de escritorio", "de": "Desktop-Website anfordern"],
        "Request Mobile Website": ["fr": "Version mobile", "es": "Versión móvil", "de": "Mobile Website anfordern"],
        "Copy Link": ["fr": "Copier le lien", "es": "Copiar enlace", "de": "Link kopieren"],
        "Copy Clean Link": ["fr": "Copier le lien nettoyé", "es": "Copiar enlace limpio", "de": "Bereinigten Link kopieren"],
        "Share…": ["fr": "Partager…", "es": "Compartir…", "de": "Teilen…"],
        "Open in Safari": ["fr": "Ouvrir dans Safari", "es": "Abrir en Safari", "de": "In Safari öffnen"],
        "Add Bookmark": ["fr": "Ajouter aux signets", "es": "Añadir marcador", "de": "Lesezeichen hinzufügen"],
        "Remove Bookmark": ["fr": "Supprimer le signet", "es": "Eliminar marcador", "de": "Lesezeichen entfernen"],
        "Open in New Tab": ["fr": "Ouvrir dans un nouvel onglet", "es": "Abrir en nueva pestaña", "de": "In neuem Tab öffnen"],
        "Open in Private Tab": ["fr": "Ouvrir dans un onglet privé", "es": "Abrir en pestaña privada", "de": "In privatem Tab öffnen"],
        "Lower Shields for This Site": ["fr": "Baisser les boucliers pour ce site", "es": "Bajar escudos para este sitio", "de": "Schilde für diese Website senken"],
        "Raise Shields for This Site": ["fr": "Relever les boucliers pour ce site", "es": "Subir escudos para este sitio", "de": "Schilde für diese Website aktivieren"],
        // ── Common buttons ──
        "Cancel": ["fr": "Annuler", "es": "Cancelar", "de": "Abbrechen"],
        "Open": ["fr": "Ouvrir", "es": "Abrir", "de": "Öffnen"],
        "Done": ["fr": "OK", "es": "OK", "de": "Fertig"],
        "Clear": ["fr": "Effacer", "es": "Borrar", "de": "Löschen"],
        "Go Back": ["fr": "Retour", "es": "Volver", "de": "Zurück"],
        "Try Again": ["fr": "Réessayer", "es": "Reintentar", "de": "Erneut versuchen"],
        "Use HTTP": ["fr": "Utiliser HTTP", "es": "Usar HTTP", "de": "HTTP verwenden"],
        // ── Search ──
        "Web": ["fr": "Web", "es": "Web", "de": "Web"],
        "Images": ["fr": "Images", "es": "Imágenes", "de": "Bilder"],
        "Videos": ["fr": "Vidéos", "es": "Vídeos", "de": "Videos"],
        "News": ["fr": "Actualités", "es": "Noticias", "de": "News"],
        "Searching…": ["fr": "Recherche…", "es": "Buscando…", "de": "Suche läuft…"],
        "Try again": ["fr": "Réessayer", "es": "Reintentar", "de": "Erneut versuchen"],
        "Search or enter address": ["fr": "Rechercher ou saisir une adresse", "es": "Buscar o escribir dirección", "de": "Suchen oder Adresse eingeben"],
        "Search Searxly": ["fr": "Rechercher sur Searxly", "es": "Buscar en Searxly", "de": "Mit Searxly suchen"],
        "Open site": ["fr": "Ouvrir le site", "es": "Abrir sitio", "de": "Website öffnen"],
        "Search again": ["fr": "Rechercher à nouveau", "es": "Buscar de nuevo", "de": "Erneut suchen"],
        "Recent Searches": ["fr": "Recherches récentes", "es": "Búsquedas recientes", "de": "Letzte Suchen"],
        "Copy": ["fr": "Copier", "es": "Copiar", "de": "Kopieren"],
        "Read on": ["fr": "Lire sur", "es": "Leer en", "de": "Weiterlesen auf"],
        // ── Home / stats ──
        "trackers blocked": ["fr": "traqueurs bloqués", "es": "rastreadores bloqueados", "de": "Tracker blockiert"],
        // ── Panels ──
        "Page Info": ["fr": "Infos de la page", "es": "Información de la página", "de": "Seiteninfo"],
        "Shields": ["fr": "Boucliers", "es": "Escudos", "de": "Schilde"],
        "Site Settings": ["fr": "Réglages du site", "es": "Ajustes del sitio", "de": "Website-Einstellungen"],
        "Privacy Report": ["fr": "Rapport de confidentialité", "es": "Informe de privacidad", "de": "Datenschutzbericht"],
        "Reset Statistics": ["fr": "Réinitialiser les statistiques", "es": "Restablecer estadísticas", "de": "Statistiken zurücksetzen"],
        "Bookmarks": ["fr": "Signets", "es": "Marcadores", "de": "Lesezeichen"],
        "History": ["fr": "Historique", "es": "Historial", "de": "Verlauf"],
        "Clear History": ["fr": "Effacer l'historique", "es": "Borrar historial", "de": "Verlauf löschen"],
        // ── Settings labels ──
        "App Language": ["fr": "Langue de l'app", "es": "Idioma de la app", "de": "App-Sprache"],
        "System": ["fr": "Système", "es": "Sistema", "de": "System"],
        "Search Results": ["fr": "Résultats de recherche", "es": "Resultados de búsqueda", "de": "Suchergebnisse"],
        "Automatic": ["fr": "Automatique", "es": "Automático", "de": "Automatisch"],
        "Safe Search": ["fr": "Recherche sécurisée", "es": "Búsqueda segura", "de": "Sichere Suche"],
        "Search": ["fr": "Recherche", "es": "Búsqueda", "de": "Suche"],
        "Language": ["fr": "Langue", "es": "Idioma", "de": "Sprache"],
        "Appearance": ["fr": "Apparence", "es": "Apariencia", "de": "Darstellung"],
        "Privacy": ["fr": "Confidentialité", "es": "Privacidad", "de": "Datenschutz"],
        "Security": ["fr": "Sécurité", "es": "Seguridad", "de": "Sicherheit"],
        "Data": ["fr": "Données", "es": "Datos", "de": "Daten"],
        "About": ["fr": "À propos", "es": "Acerca de", "de": "Über"],
        "Version": ["fr": "Version", "es": "Versión", "de": "Version"],
        "Small": ["fr": "Petit", "es": "Pequeño", "de": "Klein"],
        "Default": ["fr": "Par défaut", "es": "Predeterminado", "de": "Standard"],
        "Large": ["fr": "Grand", "es": "Grande", "de": "Groß"],
        "Extra Large": ["fr": "Très grand", "es": "Muy grande", "de": "Sehr groß"],
        // ── Intelligence ──
        "Intelligence": ["fr": "Intelligence", "es": "Inteligencia", "de": "Intelligenz"],
        "Apple Intelligence": ["fr": "Apple Intelligence", "es": "Apple Intelligence", "de": "Apple Intelligence"],
        "Summarize Page": ["fr": "Résumer la page", "es": "Resumir página", "de": "Seite zusammenfassen"],
        "Page Summary": ["fr": "Résumé de la page", "es": "Resumen de la página", "de": "Seitenzusammenfassung"],
        "Reading the page…": ["fr": "Lecture de la page…", "es": "Leyendo la página…", "de": "Seite wird gelesen…"],
        "Summarizing…": ["fr": "Résumé en cours…", "es": "Resumiendo…", "de": "Wird zusammengefasst…"],
        "Generated on this iPhone — the page never leaves your device.":
            ["fr": "Généré sur cet iPhone — la page ne quitte jamais votre appareil.",
             "es": "Generado en este iPhone — la página nunca sale de tu dispositivo.",
             "de": "Auf diesem iPhone erstellt — die Seite verlässt dein Gerät nie."],
        "There isn't enough readable text on this page to summarize.":
            ["fr": "Cette page ne contient pas assez de texte lisible pour un résumé.",
             "es": "Esta página no tiene suficiente texto legible para resumir.",
             "de": "Diese Seite enthält nicht genug lesbaren Text für eine Zusammenfassung."],
        "Private search & browsing": ["fr": "Recherche et navigation privées", "es": "Búsqueda y navegación privadas", "de": "Private Suche & Browsing"],
        "AI Overview": ["fr": "Aperçu IA", "es": "Resumen de IA", "de": "KI-Überblick"],
        "Generate": ["fr": "Générer", "es": "Generar", "de": "Erstellen"],
        "The overview couldn't be generated.": ["fr": "L'aperçu n'a pas pu être généré.", "es": "No se pudo generar el resumen.", "de": "Der Überblick konnte nicht erstellt werden."],
        "Generated on-device from these results — may contain mistakes.":
            ["fr": "Généré sur l'appareil à partir de ces résultats — peut contenir des erreurs.",
             "es": "Generado en el dispositivo a partir de estos resultados — puede contener errores.",
             "de": "Auf dem Gerät aus diesen Ergebnissen erstellt — kann Fehler enthalten."],
        "AI Overview, generating": ["fr": "Aperçu IA, génération en cours", "es": "Resumen de IA, generando", "de": "KI-Überblick, wird erstellt"],
        "Generate AI overview of the search results": ["fr": "Générer l'aperçu IA des résultats", "es": "Generar el resumen de IA de los resultados", "de": "KI-Überblick zu den Ergebnissen erstellen"],
        "Tries the overview again": ["fr": "Réessaie l'aperçu", "es": "Reintenta el resumen", "de": "Versucht den Überblick erneut"],
        "Source": ["fr": "Source", "es": "Fuente", "de": "Quelle"],
        "Sources": ["fr": "Sources", "es": "Fuentes", "de": "Quellen"],
        "You": ["fr": "Vous", "es": "Tú", "de": "Du"],
        "Answer": ["fr": "Réponse", "es": "Respuesta", "de": "Antwort"],
        "Ask About This Page": ["fr": "Poser une question sur la page", "es": "Preguntar sobre esta página", "de": "Fragen zu dieser Seite"],
        "Ask about this page…": ["fr": "Poser une question sur la page…", "es": "Pregunta sobre esta página…", "de": "Frage zu dieser Seite…"],
        "What are the key points?": ["fr": "Quels sont les points clés ?", "es": "¿Cuáles son los puntos clave?", "de": "Was sind die Kernpunkte?"],
        "Explain this simply": ["fr": "Explique simplement", "es": "Explícalo de forma sencilla", "de": "Einfach erklären"],
        "Any caveats or criticism mentioned?": ["fr": "Des réserves ou critiques mentionnées ?", "es": "¿Se mencionan objeciones o críticas?", "de": "Werden Einwände oder Kritik erwähnt?"],
        "menu": ["fr": "menu", "es": "menú", "de": "Menü"],
        "Reader": ["fr": "Lecteur", "es": "Lector", "de": "Reader"],
        "No readable article on this page.": ["fr": "Aucun article lisible sur cette page.", "es": "No hay un artículo legible en esta página.", "de": "Kein lesbarer Artikel auf dieser Seite."],
        "Private tabs are locked": ["fr": "Les onglets privés sont verrouillés", "es": "Las pestañas privadas están bloqueadas", "de": "Private Tabs sind gesperrt"],
        "Private": ["fr": "Privé", "es": "Privado", "de": "Privat"],
        "Private Mode": ["fr": "Mode privé", "es": "Modo privado", "de": "Privater Modus"],
        "Leave Private Mode": ["fr": "Quitter le mode privé", "es": "Salir del modo privado", "de": "Privaten Modus verlassen"],
        "Browsing": ["fr": "Navigation", "es": "Navegación", "de": "Surfen"],
        "Private Tab": ["fr": "Onglet privé", "es": "Pestaña privada", "de": "Privater Tab"],
        "Private Tab, locked": ["fr": "Onglet privé, verrouillé", "es": "Pestaña privada, bloqueada", "de": "Privater Tab, gesperrt"],
        "Tab": ["fr": "Onglet", "es": "Pestaña", "de": "Tab"],
        "Reading List": ["fr": "Liste de lecture", "es": "Lista de lectura", "de": "Leseliste"],
        "Downloads": ["fr": "Téléchargements", "es": "Descargas", "de": "Downloads"],
        "Unlock": ["fr": "Déverrouiller", "es": "Desbloquear", "de": "Entsperren"],
        "Sync": ["fr": "Synchronisation", "es": "Sincronización", "de": "Sync"],
        "Receive": ["fr": "Recevoir", "es": "Recibir", "de": "Empfangen"],
        "Send": ["fr": "Envoyer", "es": "Enviar", "de": "Senden"],
        "Receive from Another Device": ["fr": "Recevoir d'un autre appareil", "es": "Recibir de otro dispositivo", "de": "Von anderem Gerät empfangen"],
        "Send from This iPhone": ["fr": "Envoyer depuis cet iPhone", "es": "Enviar desde este iPhone", "de": "Von diesem iPhone senden"],
        "Choose Sync File": ["fr": "Choisir le fichier de synchro", "es": "Elegir archivo de sincronización", "de": "Sync-Datei wählen"],
        "Merge": ["fr": "Fusionner", "es": "Combinar", "de": "Zusammenführen"],
        "Your code": ["fr": "Votre code", "es": "Tu código", "de": "Dein Code"],
        "New Code": ["fr": "Nouveau code", "es": "Código nuevo", "de": "Neuer Code"],
        "Share Encrypted File": ["fr": "Partager le fichier chiffré", "es": "Compartir archivo cifrado", "de": "Verschlüsselte Datei teilen"],
        "Couldn't read that file.": ["fr": "Impossible de lire ce fichier.", "es": "No se pudo leer el archivo.", "de": "Datei konnte nicht gelesen werden."],
        "Couldn't prepare the sync file.": ["fr": "Impossible de préparer le fichier.", "es": "No se pudo preparar el archivo.", "de": "Sync-Datei konnte nicht erstellt werden."],
        "Merged %d bookmarks and %d history items from %@.":
            ["fr": "%d signets et %d éléments d'historique fusionnés depuis %@.",
             "es": "%d marcadores y %d elementos del historial combinados desde %@.",
             "de": "%d Lesezeichen und %d Verlaufseinträge von %@ zusammengeführt."],
        "Step 1": ["fr": "Étape 1", "es": "Paso 1", "de": "Schritt 1"],
        "Step 2": ["fr": "Étape 2", "es": "Paso 2", "de": "Schritt 2"],
        "Sync your bookmarks and history between your devices without a server or account. One device makes an encrypted file and a code; the other opens the file and enters the code. The file is useless to anyone without the code, and nothing is ever uploaded.":
            ["fr": "Synchronisez signets et historique entre vos appareils, sans serveur ni compte. Un appareil crée un fichier chiffré et un code ; l'autre ouvre le fichier et saisit le code. Le fichier est inutilisable sans le code, et rien n'est jamais téléversé.",
             "es": "Sincroniza marcadores e historial entre tus dispositivos sin servidor ni cuenta. Un dispositivo crea un archivo cifrado y un código; el otro abre el archivo e introduce el código. El archivo es inútil sin el código y nada se sube nunca.",
             "de": "Synchronisiere Lesezeichen und Verlauf zwischen deinen Geräten — ohne Server oder Konto. Ein Gerät erstellt eine verschlüsselte Datei und einen Code; das andere öffnet die Datei und gibt den Code ein. Ohne Code ist die Datei nutzlos, und nichts wird je hochgeladen."],
        "On your other device, choose Send, then AirDrop the file to this iPhone (or save it to Files). Here, pick that file.":
            ["fr": "Sur l'autre appareil, choisissez Envoyer, puis AirDrop le fichier vers cet iPhone (ou enregistrez-le dans Fichiers). Ici, sélectionnez ce fichier.",
             "es": "En el otro dispositivo, elige Enviar y pasa el archivo por AirDrop a este iPhone (o guárdalo en Archivos). Aquí, selecciona ese archivo.",
             "de": "Wähle auf dem anderen Gerät Senden und schicke die Datei per AirDrop an dieses iPhone (oder sichere sie in Dateien). Wähle die Datei dann hier aus."],
        "Enter the code shown on the sending device.":
            ["fr": "Saisissez le code affiché sur l'appareil expéditeur.",
             "es": "Introduce el código mostrado en el dispositivo emisor.",
             "de": "Gib den Code ein, der auf dem sendenden Gerät angezeigt wird."],
        "You'll enter this code on the receiving device. Generate a fresh one any time.":
            ["fr": "Vous saisirez ce code sur l'appareil destinataire. Générez-en un nouveau à tout moment.",
             "es": "Introducirás este código en el dispositivo receptor. Genera uno nuevo cuando quieras.",
             "de": "Diesen Code gibst du auf dem empfangenden Gerät ein. Erzeuge jederzeit einen neuen."],
        "AirDrop the file to your other device, then enter the code above in Searxly there.":
            ["fr": "Envoyez le fichier par AirDrop à l'autre appareil, puis saisissez-y le code ci-dessus dans Searxly.",
             "es": "Pasa el archivo por AirDrop al otro dispositivo y allí introduce el código de arriba en Searxly.",
             "de": "Schicke die Datei per AirDrop an das andere Gerät und gib dort den obigen Code in Searxly ein."],
        "Bookmarks:": ["fr": "Signets :", "es": "Marcadores:", "de": "Lesezeichen:"],
        "History:": ["fr": "Historique :", "es": "Historial:", "de": "Verlauf:"],
        "Retry": ["fr": "Réessayer", "es": "Reintentar", "de": "Erneut versuchen"],
        "Any time": ["fr": "Toute période", "es": "Cualquier fecha", "de": "Beliebige Zeit"],
        "24 hours": ["fr": "24 heures", "es": "24 horas", "de": "24 Stunden"],
        "Week": ["fr": "Semaine", "es": "Semana", "de": "Woche"],
        "Month": ["fr": "Mois", "es": "Mes", "de": "Monat"],
        "Year": ["fr": "Année", "es": "Año", "de": "Jahr"],
        "Top": ["fr": "À la une", "es": "Destacados", "de": "Top"],
        "Official site": ["fr": "Site officiel", "es": "Sitio oficial", "de": "Offizielle Website"],
        "From your library": ["fr": "Depuis votre bibliothèque", "es": "De tu biblioteca", "de": "Aus deiner Mediathek"],
        "Dark Mode for Websites": ["fr": "Mode sombre pour les sites", "es": "Modo oscuro para sitios web", "de": "Dunkelmodus für Websites"],
        "Translate Page": ["fr": "Traduire la page", "es": "Traducir página", "de": "Seite übersetzen"],
        "Ask About These Results": ["fr": "Interroger ces résultats", "es": "Preguntar sobre estos resultados", "de": "Zu diesen Ergebnissen fragen"],
        "News Overview": ["fr": "Aperçu de l'actualité", "es": "Resumen de noticias", "de": "News-Überblick"],
        "Brief": ["fr": "Résumé", "es": "Resumen", "de": "Kurzfassung"],
        "Recent": ["fr": "Récent", "es": "Reciente", "de": "Zuletzt"],
        "Remove": ["fr": "Supprimer", "es": "Eliminar", "de": "Entfernen"],
        "Recent search": ["fr": "Recherche récente", "es": "Búsqueda reciente", "de": "Letzte Suche"],
        "News Brief": ["fr": "Résumé de l'actualité", "es": "Resumen de noticias", "de": "News-Kurzfassung"],
        "Today's news": ["fr": "L'actualité du jour", "es": "Las noticias de hoy", "de": "Die News von heute"],
        "Pages you visit here aren't saved to history, and their cookies vanish when you leave Private Mode.":
            ["fr": "Les pages visitées ici ne sont pas enregistrées dans l'historique, et leurs cookies disparaissent quand vous quittez le mode privé.",
             "es": "Las páginas que visitas aquí no se guardan en el historial, y sus cookies desaparecen al salir del modo privado.",
             "de": "Hier besuchte Seiten landen nicht im Verlauf, und ihre Cookies verschwinden, wenn du den privaten Modus verlässt."],
        "Summarizes today's news on-device": ["fr": "Résume l'actualité du jour sur l'appareil", "es": "Resume las noticias de hoy en el dispositivo", "de": "Fasst die heutigen News auf dem Gerät zusammen"],
        "Generated on-device from the stories below — may contain mistakes.":
            ["fr": "Généré sur l'appareil à partir des articles ci-dessous — peut contenir des erreurs.",
             "es": "Generado en el dispositivo a partir de las noticias siguientes — puede contener errores.",
             "de": "Auf dem Gerät aus den folgenden Meldungen erstellt — kann Fehler enthalten."],
        "Reading the coverage…": ["fr": "Lecture de la couverture…", "es": "Leyendo la cobertura…", "de": "Berichterstattung wird gelesen…"],
        "Generated on-device from this story's coverage — may contain mistakes.":
            ["fr": "Généré sur l'appareil à partir de la couverture de cet article — peut contenir des erreurs.",
             "es": "Generado en el dispositivo a partir de la cobertura de esta noticia — puede contener errores.",
             "de": "Auf dem Gerät aus der Berichterstattung erstellt — kann Fehler enthalten."],
        "The brief came back empty. Close and try again.":
            ["fr": "Le résumé est revenu vide. Fermez et réessayez.",
             "es": "El resumen llegó vacío. Cierra e inténtalo de nuevo.",
             "de": "Die Kurzfassung kam leer zurück. Schließen und erneut versuchen."],
        "generating": ["fr": "génération en cours", "es": "generando", "de": "wird erstellt"],
        "Ask more": ["fr": "Poser une question", "es": "Preguntar más", "de": "Mehr fragen"],
        "Explain This": ["fr": "Expliquer", "es": "Explicar", "de": "Erklären"],
        "Voice search": ["fr": "Recherche vocale", "es": "Búsqueda por voz", "de": "Sprachsuche"],
        "Scan Code": ["fr": "Scanner un code", "es": "Escanear código", "de": "Code scannen"],
        "Listening…": ["fr": "Je vous écoute…", "es": "Escuchando…", "de": "Ich höre zu…"],
        "Preparing…": ["fr": "Préparation…", "es": "Preparando…", "de": "Vorbereiten…"],
        "Stop and search": ["fr": "Arrêter et rechercher", "es": "Detener y buscar", "de": "Stoppen und suchen"],
        "Recognized on this device — your voice never leaves it.":
            ["fr": "Reconnue sur cet appareil — votre voix ne le quitte jamais.",
             "es": "Reconocida en este dispositivo — tu voz nunca sale de él.",
             "de": "Auf diesem Gerät erkannt — deine Stimme verlässt es nie."],
        "Searxly needs microphone and speech access for voice search. You can allow both in iOS Settings.":
            ["fr": "Searxly a besoin du micro et de la reconnaissance vocale pour la recherche vocale. Autorisez-les dans Réglages iOS.",
             "es": "Searxly necesita acceso al micrófono y al reconocimiento de voz. Permítelos en Ajustes de iOS.",
             "de": "Searxly braucht Mikrofon- und Spracherkennungszugriff für die Sprachsuche. Erlaube beides in den iOS-Einstellungen."],
        "On-device dictation isn't available for your language on this device.":
            ["fr": "La dictée sur appareil n'est pas disponible pour votre langue sur cet appareil.",
             "es": "El dictado en el dispositivo no está disponible para tu idioma en este dispositivo.",
             "de": "Diktat auf dem Gerät ist für deine Sprache auf diesem Gerät nicht verfügbar."],
        "Couldn't hear anything. Try again.":
            ["fr": "Rien entendu. Réessayez.",
             "es": "No se oyó nada. Inténtalo de nuevo.",
             "de": "Nichts gehört. Versuch es noch einmal."],
        "Camera access is off. Allow it for Searxly in iOS Settings to scan codes.":
            ["fr": "L'accès caméra est désactivé. Autorisez-le pour Searxly dans Réglages iOS pour scanner des codes.",
             "es": "El acceso a la cámara está desactivado. Permítelo para Searxly en Ajustes de iOS para escanear códigos.",
             "de": "Kamerazugriff ist aus. Erlaube ihn für Searxly in den iOS-Einstellungen, um Codes zu scannen."],
        "Scanning isn't supported on this device.":
            ["fr": "Le scan n'est pas pris en charge sur cet appareil.",
             "es": "El escaneo no es compatible con este dispositivo.",
             "de": "Scannen wird auf diesem Gerät nicht unterstützt."],
        "Translate This": ["fr": "Traduire", "es": "Traducir", "de": "Übersetzen"],
        "Explain this passage from the page: “%@”":
            ["fr": "Explique ce passage de la page : « %@ »",
             "es": "Explica este pasaje de la página: «%@»",
             "de": "Erkläre diese Passage der Seite: „%@“"],
        "Chat about these search results, on-device": ["fr": "Discuter de ces résultats, sur l'appareil", "es": "Charla sobre estos resultados, en el dispositivo", "de": "Über diese Ergebnisse chatten, auf dem Gerät"],
        "Show Original": ["fr": "Afficher l'original", "es": "Mostrar original", "de": "Original anzeigen"],
        "There's no translatable text on this page.":
            ["fr": "Aucun texte traduisible sur cette page.",
             "es": "No hay texto traducible en esta página.",
             "de": "Auf dieser Seite gibt es keinen übersetzbaren Text."],
        "Couldn't translate this page — it may already be in your language, or the language pair isn't supported on-device.":
            ["fr": "Impossible de traduire cette page — elle est peut-être déjà dans votre langue, ou la paire de langues n'est pas prise en charge sur l'appareil.",
             "es": "No se pudo traducir esta página — puede que ya esté en tu idioma, o el par de idiomas no es compatible en el dispositivo.",
             "de": "Diese Seite konnte nicht übersetzt werden — sie ist vielleicht schon in deiner Sprache, oder das Sprachpaar wird auf dem Gerät nicht unterstützt."],
        "Darkens light websites; pages that are already dark are left alone. Runs entirely on this device. New tabs pick it up immediately — reload open tabs to apply.":
            ["fr": "Assombrit les sites clairs ; les pages déjà sombres restent telles quelles. Fonctionne entièrement sur cet appareil. Les nouveaux onglets l'appliquent immédiatement — rechargez les onglets ouverts pour l'appliquer.",
             "es": "Oscurece los sitios claros; las páginas ya oscuras se dejan igual. Funciona por completo en este dispositivo. Las pestañas nuevas lo aplican de inmediato — recarga las abiertas para aplicarlo.",
             "de": "Dunkelt helle Websites ab; bereits dunkle Seiten bleiben unverändert. Läuft vollständig auf diesem Gerät. Neue Tabs übernehmen es sofort — offene Tabs zum Anwenden neu laden."],
        "Back": ["fr": "Retour", "es": "Atrás", "de": "Zurück"],
        "Forward": ["fr": "Avancer", "es": "Adelante", "de": "Vorwärts"],
        "Bookmarks and history": ["fr": "Signets et historique", "es": "Marcadores e historial", "de": "Lesezeichen und Verlauf"],
        "trackers blocked on this page": ["fr": "traqueurs bloqués sur cette page", "es": "rastreadores bloqueados en esta página", "de": "Tracker auf dieser Seite blockiert"],
        "New tab": ["fr": "Nouvel onglet", "es": "Pestaña nueva", "de": "Neuer Tab"],
        "Private tab": ["fr": "Onglet privé", "es": "Pestaña privada", "de": "Privater Tab"],
        "Close tab": ["fr": "Fermer l'onglet", "es": "Cerrar pestaña", "de": "Tab schließen"],
        "View": ["fr": "Affichage", "es": "Vista", "de": "Ansicht"],
        "Tabs": ["fr": "Onglets", "es": "Pestañas", "de": "Tabs"],
        "Copied": ["fr": "Copié", "es": "Copiado", "de": "Kopiert"],
        "Regenerate": ["fr": "Régénérer", "es": "Regenerar", "de": "Neu erstellen"],
        "Available": ["fr": "Disponible", "es": "Disponible", "de": "Verfügbar"],
        "Apple Intelligence is turned off": ["fr": "Apple Intelligence est désactivé", "es": "Apple Intelligence está desactivado", "de": "Apple Intelligence ist deaktiviert"],
        "Downloading the on-device model…": ["fr": "Téléchargement du modèle sur l'appareil…", "es": "Descargando el modelo en el dispositivo…", "de": "Modell wird auf das Gerät geladen…"],
        "Not supported on this device": ["fr": "Non pris en charge sur cet appareil", "es": "No compatible con este dispositivo", "de": "Auf diesem Gerät nicht unterstützt"],
        "iOS is downloading Apple's on-device model in the background. It goes fastest on Wi-Fi with the iPhone charging. This screen updates automatically.":
            ["fr": "iOS télécharge le modèle d'Apple en arrière-plan. C'est plus rapide en Wi-Fi avec l'iPhone en charge. Cet écran se met à jour automatiquement.",
             "es": "iOS está descargando el modelo de Apple en segundo plano. Va más rápido con Wi-Fi y el iPhone cargando. Esta pantalla se actualiza sola.",
             "de": "iOS lädt Apples Modell im Hintergrund. Am schnellsten geht es im WLAN mit angeschlossenem Ladegerät. Dieser Bildschirm aktualisiert sich automatisch."],
        "Turn on Apple Intelligence in Settings ▸ Apple Intelligence & Siri, then come back here.":
            ["fr": "Activez Apple Intelligence dans Réglages ▸ Apple Intelligence et Siri, puis revenez ici.",
             "es": "Activa Apple Intelligence en Ajustes ▸ Apple Intelligence y Siri, y vuelve aquí.",
             "de": "Aktiviere Apple Intelligence in Einstellungen ▸ Apple Intelligence & Siri und komm dann hierher zurück."],

        // ── SERP chrome (was missing → always fell back to English) ──
        "All": ["fr": "Tout", "es": "Todo", "de": "Alle"],
        "Top stories": ["fr": "À la une", "es": "Noticias destacadas", "de": "Top-Meldungen"],
        "In the news": ["fr": "Dans l'actualité", "es": "En las noticias", "de": "In den Nachrichten"],
        "More news": ["fr": "Plus d'actus", "es": "Más noticias", "de": "Mehr News"],
        "sources": ["fr": "sources", "es": "fuentes", "de": "Quellen"],
        "See all": ["fr": "Tout voir", "es": "Ver todo", "de": "Alle anzeigen"],
        "No results": ["fr": "Aucun résultat", "es": "Sin resultados", "de": "Keine Ergebnisse"],
        "No results for “%@”.":
            ["fr": "Aucun résultat pour « %@ ».",
             "es": "No hay resultados para “%@”.",
             "de": "Keine Ergebnisse für „%@“."],
        "Search failed. Check your connection, or the instance in Settings.":
            ["fr": "Échec de la recherche. Vérifiez la connexion ou l'instance dans Réglages.",
             "es": "Error de búsqueda. Revisa la conexión o la instancia en Ajustes.",
             "de": "Suche fehlgeschlagen. Prüfe die Verbindung oder die Instanz in den Einstellungen."],
        "TOP STORY": ["fr": "À LA UNE", "es": "DESTACADA", "de": "TOP-STORY"],
        "Full coverage": ["fr": "Couverture complète", "es": "Cobertura completa", "de": "Vollständige Berichterstattung"],
        "Latest": ["fr": "Dernières", "es": "Últimas", "de": "Aktuell"],
        "Topics": ["fr": "Sujets", "es": "Temas", "de": "Themen"],
        "Refresh news": ["fr": "Actualiser les actus", "es": "Actualizar noticias", "de": "News aktualisieren"],
        "Headlines from your search instance.":
            ["fr": "Titres depuis votre instance de recherche.",
             "es": "Titulares de tu instancia de búsqueda.",
             "de": "Schlagzeilen von deiner Suchinstanz."],
        "Kept in memory only — never saved, off in private tabs.":
            ["fr": "Gardés en mémoire seulement — jamais enregistrés, désactivés en privé.",
             "es": "Solo en memoria — nunca se guardan; desactivado en pestañas privadas.",
             "de": "Nur im Speicher — nie gespeichert, aus in privaten Tabs."],

        // ── Home / address ──
        "ads & trackers blocked":
            ["fr": "pubs et traqueurs bloqués",
             "es": "anuncios y rastreadores bloqueados",
             "de": "Werbung & Tracker blockiert"],
        "Scroll for news": ["fr": "Faites défiler pour les actus", "es": "Desplázate para ver noticias", "de": "Für News scrollen"],
        "Scroll down for news": ["fr": "Descendez pour les actus", "es": "Baja para ver noticias", "de": "Nach unten für News"],
        "Pull down or tap to search":
            ["fr": "Tirez vers le bas ou appuyez pour rechercher",
             "es": "Tira hacia abajo o toca para buscar",
             "de": "Nach unten ziehen oder tippen zum Suchen"],
        "Nothing you do here is saved":
            ["fr": "Rien de ce que vous faites ici n'est enregistré",
             "es": "Nada de lo que hagas aquí se guarda",
             "de": "Hier wird nichts gespeichert"],
        "Favorite": ["fr": "Favori", "es": "Favorito", "de": "Favorit"],
        "Top site": ["fr": "Site fréquent", "es": "Sitio frecuente", "de": "Top-Seite"],
        "Top Sites": ["fr": "Sites fréquents", "es": "Sitios frecuentes", "de": "Top-Seiten"],
        "Paste and Go": ["fr": "Coller et ouvrir", "es": "Pegar e ir", "de": "Einfügen und öffnen"],
        "Open or search your clipboard":
            ["fr": "Ouvrir ou rechercher le presse-papiers",
             "es": "Abrir o buscar el portapapeles",
             "de": "Zwischenablage öffnen oder suchen"],

        // ── Knowledge / AI ──
        "Wikipedia": ["fr": "Wikipédia", "es": "Wikipedia", "de": "Wikipedia"],
        "Grokipedia": ["fr": "Grokipedia", "es": "Grokipedia", "de": "Grokipedia"],
        "Knowledge card": ["fr": "Fiche encyclopédique", "es": "Tarjeta de conocimiento", "de": "Wissenskarte"],
        "Apple Intelligence is preparing its on-device model — the AI Overview appears once it's ready.":
            ["fr": "Apple Intelligence prépare son modèle sur l'appareil — l'aperçu IA s'affichera une fois prêt.",
             "es": "Apple Intelligence está preparando su modelo en el dispositivo; el resumen de IA aparecerá cuando esté listo.",
             "de": "Apple Intelligence bereitet das On-Device-Modell vor — der KI-Überblick erscheint, sobald es bereit ist."],
        "Turn on Apple Intelligence in iOS Settings to see an AI Overview here.":
            ["fr": "Activez Apple Intelligence dans les Réglages iOS pour voir un aperçu IA ici.",
             "es": "Activa Apple Intelligence en Ajustes de iOS para ver un resumen de IA aquí.",
             "de": "Aktiviere Apple Intelligence in den iOS-Einstellungen, um hier einen KI-Überblick zu sehen."],
        "The overview came back empty. Tap to try again.":
            ["fr": "L'aperçu est vide. Appuyez pour réessayer.",
             "es": "El resumen ha salido vacío. Toca para reintentar.",
             "de": "Der Überblick war leer. Tippen zum erneuten Versuch."],
        "The on-device model didn't respond. Tap to try again.":
            ["fr": "Le modèle sur l'appareil n'a pas répondu. Appuyez pour réessayer.",
             "es": "El modelo en el dispositivo no respondió. Toca para reintentar.",
             "de": "Das On-Device-Modell hat nicht geantwortet. Tippen zum erneuten Versuch."],
        "The on-device model declined this content (Apple Intelligence safety filter).":
            ["fr": "Le modèle a refusé ce contenu (filtre de sécurité d'Apple Intelligence).",
             "es": "El modelo rechazó este contenido (filtro de seguridad de Apple Intelligence).",
             "de": "Das Modell hat diesen Inhalt abgelehnt (Sicherheitsfilter von Apple Intelligence)."],
        "This page is too long for the on-device model.":
            ["fr": "Cette page est trop longue pour le modèle sur l'appareil.",
             "es": "Esta página es demasiado larga para el modelo en el dispositivo.",
             "de": "Diese Seite ist zu lang für das On-Device-Modell."],
        "Cancelled.": ["fr": "Annulé.", "es": "Cancelado.", "de": "Abgebrochen."],

        // ── Settings bits used on Search pane ──
        "Off": ["fr": "Désactivé", "es": "Desactivado", "de": "Aus"],
        "Moderate": ["fr": "Modéré", "es": "Moderado", "de": "Mittel"],
        "Strict": ["fr": "Strict", "es": "Estricto", "de": "Streng"],
        "App and search languages are independent — e.g. English interface with French results. Interface translations cover English, Français, Español, and Deutsch for now; system controls follow after a relaunch.":
            ["fr": "Les langues de l'app et des résultats sont indépendantes — p. ex. interface en anglais et résultats en français. Les traductions d'interface couvrent l'anglais, le français, l'espagnol et l'allemand pour l'instant ; les contrôles système suivent après un redémarrage.",
             "es": "Los idiomas de la app y de los resultados son independientes — p. ej. interfaz en inglés y resultados en francés. Las traducciones de interfaz cubren inglés, francés, español y alemán por ahora; los controles del sistema se actualizan al reiniciar.",
             "de": "App- und Suchsprache sind unabhängig — z. B. englische Oberfläche mit französischen Ergebnissen. Oberflächenübersetzungen decken vorerst Englisch, Französisch, Spanisch und Deutsch ab; Systemsteuerelemente folgen nach einem Neustart."],
        "By default both follow your iPhone language (any system language). You can optionally override App Language and Search Results separately. Built-in UI translations cover English, Français, Español, and Deutsch; other languages still drive search, knowledge cards, and AI in that language.":
            ["fr": "Par défaut, les deux suivent la langue de l'iPhone (toute langue système). Vous pouvez les modifier séparément. Les traductions d'interface couvrent l'anglais, le français, l'espagnol et l'allemand ; les autres langues pilotent quand même la recherche, les fiches et l'IA.",
             "es": "Por defecto ambos siguen el idioma del iPhone (cualquier idioma del sistema). Puedes cambiarlos por separado. Las traducciones de interfaz cubren inglés, francés, español y alemán; otros idiomas siguen impulsando la búsqueda, las fichas y la IA.",
             "de": "Standardmäßig folgen beide der iPhone-Sprache (jede Systemsprache). Optional getrennt überschreibbar. UI-Übersetzungen: Englisch, Französisch, Spanisch, Deutsch; andere Sprachen steuern trotzdem Suche, Wissensbox und KI."],

        // ── Settings chrome (full localization pass) ──
        "System language": ["fr": "Langue du système", "es": "Idioma del sistema", "de": "Systemsprache"],
        "Active language": ["fr": "Langue active", "es": "Idioma activo", "de": "Aktive Sprache"],
        "Status": ["fr": "État", "es": "Estado", "de": "Status"],
        "Interface": ["fr": "Interface", "es": "Interfaz", "de": "Oberfläche"],
        "Search & content": ["fr": "Recherche et contenu", "es": "Búsqueda y contenido", "de": "Suche & Inhalt"],
        "Resolved": ["fr": "Résolu", "es": "Resuelto", "de": "Aufgelöst"],
        "Wikipedia language": ["fr": "Langue Wikipédia", "es": "Idioma de Wikipedia", "de": "Wikipedia-Sprache"],
        "Search language code": ["fr": "Code langue de recherche", "es": "Código de idioma de búsqueda", "de": "Suchsprachcode"],
        "Search languages": ["fr": "Rechercher des langues", "es": "Buscar idiomas", "de": "Sprachen suchen"],
        "By default Searxly follows your iPhone language for the interface, search, knowledge cards, and on-device AI. Override only if you want something different.":
            ["fr": "Par défaut, Searxly suit la langue de l'iPhone pour l'interface, la recherche, les fiches et l'IA. Ne changez que si vous voulez autre chose.",
             "es": "Por defecto Searxly sigue el idioma del iPhone para la interfaz, la búsqueda, las fichas y la IA. Cambia solo si quieres algo distinto.",
             "de": "Standardmäßig folgt Searxly der iPhone-Sprache für Oberfläche, Suche, Karten und KI. Nur überschreiben, wenn du etwas anderes willst."],
        "UI chrome translations ship for English, Français, Español, and Deutsch. Every other language still drives content correctly.":
            ["fr": "Les traductions d'interface couvrent l'anglais, le français, l'espagnol et l'allemand. Les autres langues pilotent quand même le contenu.",
             "es": "Las traducciones de interfaz cubren inglés, francés, español y alemán. Los demás idiomas siguen impulsando el contenido.",
             "de": "UI-Übersetzungen: Englisch, Französisch, Spanisch, Deutsch. Andere Sprachen steuern den Inhalt trotzdem korrekt."],
        "Controls SearXNG results language, Wikipedia/Grokipedia cards, Accept-Language, and AI fallback language. Automatic follows App Language (and thus System when App Language is System).":
            ["fr": "Contrôle la langue des résultats SearXNG, des fiches Wikipédia/Grokipedia, Accept-Language et l'IA. Automatique suit la langue de l'app (donc le système).",
             "es": "Controla el idioma de resultados SearXNG, fichas Wikipedia/Grokipedia, Accept-Language y la IA. Automático sigue el idioma de la app (y el sistema).",
             "de": "Steuert SearXNG-Ergebnisse, Wikipedia/Grokipedia, Accept-Language und KI. Automatisch folgt der App-Sprache (also dem System)."],
        "Online Suggestions": ["fr": "Suggestions en ligne", "es": "Sugerencias en línea", "de": "Online-Vorschläge"],
        "Site Icons in Results": ["fr": "Icônes de site dans les résultats", "es": "Iconos de sitio en resultados", "de": "Site-Icons in Ergebnissen"],
        "Knowledge Cards": ["fr": "Fiches encyclopédiques", "es": "Tarjetas de conocimiento", "de": "Wissenskarten"],
        "Prefer Grokipedia": ["fr": "Préférer Grokipedia", "es": "Preferir Grokipedia", "de": "Grokipedia bevorzugen"],
        "News on Start Page": ["fr": "Actus sur la page d'accueil", "es": "Noticias en la página de inicio", "de": "News auf der Startseite"],
        "Safe Search is applied by your search instance. Content Filter additionally screens results on this device with a bundled open-source blocklist — nothing is looked up online. Online Suggestions sends what you type to your instance for completions (off by default). Site Icons fetches each result site's icon anonymously. Knowledge Cards summarize entity searches — Grokipedia first, Wikipedia as fallback (never in private tabs).":
            ["fr": "Safe Search est appliqué par votre instance. Le filtre de contenu écarte en plus des résultats sur cet appareil via une liste open source embarquée — aucune consultation en ligne. Les suggestions envoient ce que vous tapez à l'instance (désactivé par défaut). Les icônes chargent chaque favicon anonymement. Les fiches résument les entités — Grokipedia d'abord, Wikipédia en secours (jamais en privé).",
             "es": "Safe Search lo aplica tu instancia. El filtro de contenido además descarta resultados en este dispositivo con una lista open source integrada — nada se consulta en línea. Las sugerencias envían lo que escribes a la instancia (desactivado por defecto). Los iconos cargan favicons de forma anónima. Las fichas resumen entidades — Grokipedia primero, Wikipedia de respaldo (nunca en privado).",
             "de": "Safe Search wendet deine Instanz an. Der Inhaltsfilter sortiert zusätzlich auf diesem Gerät per mitgelieferter Open-Source-Liste aus — nichts wird online nachgeschlagen. Online-Vorschläge senden Tippen an die Instanz (standardmäßig aus). Site-Icons laden Favicons anonym. Wissenskarten fassen Entitäten zusammen — Grokipedia zuerst, Wikipedia als Fallback (nie privat)."],
        "Scroll down from the start page for a topic-by-topic headline feed pulled from your search instance. Headlines are kept in memory only — never saved to disk — and the feed never appears in private tabs.":
            ["fr": "Descendez depuis l'accueil pour un fil de titres par sujet depuis votre instance. En mémoire seulement — jamais disque — jamais en privé.",
             "es": "Baja desde el inicio para un feed de titulares por tema de tu instancia. Solo en memoria — nunca en disco — nunca en privado.",
             "de": "Von der Startseite nach unten scrollen für Themen-Schlagzeilen von deiner Instanz. Nur im Speicher — nie auf Disk — nie privat."],
        "Turn topics off to hide them from the start-page news feed. The top-story banner only draws from the hard-news topics you keep on.":
            ["fr": "Désactivez des sujets pour les retirer du fil. La bannière ne tire que des sujets d'actualité que vous gardez.",
             "es": "Desactiva temas para ocultarlos del feed. El banner solo usa los temas de noticias que dejas activos.",
             "de": "Themen aus, um sie aus dem Feed zu nehmen. Das Banner nutzt nur eingeschaltete Hard-News-Themen."],
        "Result title preview": ["fr": "Aperçu du titre", "es": "Vista previa del título", "de": "Titelvorschau"],
        "This is how result snippets will read at the selected size.":
            ["fr": "Voici comment les extraits s'affichent à la taille choisie.",
             "es": "Así se leen los extractos con el tamaño elegido.",
             "de": "So lesen sich Snippets in der gewählten Größe."],
        "Applies to Searxly's interface — results, cards, suggestions. Web page text size is set per site from the lock icon on the page.":
            ["fr": "S'applique à l'interface Searxly — résultats, fiches, suggestions. La taille des pages web se règle par site via le cadenas.",
             "es": "Afecta a la interfaz de Searxly — resultados, fichas, sugerencias. El tamaño de página web se ajusta por sitio desde el candado.",
             "de": "Gilt für die Searxly-Oberfläche — Ergebnisse, Karten, Vorschläge. Webseiten-Textgröße pro Site über das Schloss."],
        "Block Ads & Trackers": ["fr": "Bloquer pubs et traqueurs", "es": "Bloquear anuncios y rastreadores", "de": "Werbung & Tracker blockieren"],
        "YouTube Ad Blocking": ["fr": "Blocage des pubs YouTube", "es": "Bloqueo de anuncios de YouTube", "de": "YouTube-Werbeblocker"],
        "Fingerprint Protection": ["fr": "Protection d'empreinte", "es": "Protección de huella", "de": "Fingerabdruck-Schutz"],
        "Do-Not-Sell Signal (GPC)": ["fr": "Signal Ne pas vendre (GPC)", "es": "Señal No vender (GPC)", "de": "Do-Not-Sell-Signal (GPC)"],
        "Hide Cookie Banners": ["fr": "Masquer les bannières cookies", "es": "Ocultar banners de cookies", "de": "Cookie-Banner ausblenden"],
        "HTTPS-Only": ["fr": "HTTPS uniquement", "es": "Solo HTTPS", "de": "Nur HTTPS"],
        "Remove Tracking Parameters": ["fr": "Retirer les paramètres de suivi", "es": "Quitar parámetros de seguimiento", "de": "Tracking-Parameter entfernen"],
        "Skip AMP Pages": ["fr": "Ignorer les pages AMP", "es": "Omitir páginas AMP", "de": "AMP-Seiten überspringen"],
        "Connections & Links": ["fr": "Connexions et liens", "es": "Conexiones y enlaces", "de": "Verbindungen & Links"],
        "Sites with Lowered Shields": ["fr": "Sites aux boucliers baissés", "es": "Sitios con escudos bajados", "de": "Sites mit gesenkten Schilden"],
        "Raise": ["fr": "Relever", "es": "Subir", "de": "Anheben"],
        "Raise Shields Everywhere": ["fr": "Relever les boucliers partout", "es": "Subir escudos en todas partes", "de": "Schilde überall anheben"],
        "Save History": ["fr": "Enregistrer l'historique", "es": "Guardar historial", "de": "Verlauf speichern"],
        "Block Pop-ups": ["fr": "Bloquer les pop-ups", "es": "Bloquear ventanas emergentes", "de": "Pop-ups blockieren"],
        "Restore Tabs at Launch": ["fr": "Restaurer les onglets au lancement", "es": "Restaurar pestañas al abrir", "de": "Tabs beim Start wiederherstellen"],
        "Clear Website Data on Exit": ["fr": "Effacer les données de site à la sortie", "es": "Borrar datos web al salir", "de": "Website-Daten beim Beenden löschen"],
        "History Cleared": ["fr": "Historique effacé", "es": "Historial borrado", "de": "Verlauf gelöscht"],
        "Website Data Cleared": ["fr": "Données de site effacées", "es": "Datos web borrados", "de": "Website-Daten gelöscht"],
        "Clear Website Data": ["fr": "Effacer les données de site", "es": "Borrar datos web", "de": "Website-Daten löschen"],
        "App Lock": ["fr": "Verrouillage de l'app", "es": "Bloqueo de la app", "de": "App-Sperre"],
        "Lock Private Tabs": ["fr": "Verrouiller les onglets privés", "es": "Bloquear pestañas privadas", "de": "Private Tabs sperren"],
        "Require %@ to open Searxly.":
            ["fr": "Exiger %@ pour ouvrir Searxly.",
             "es": "Requerir %@ para abrir Searxly.",
             "de": "%@ zum Öffnen von Searxly verlangen."],
        "App Lock needs Face ID, Touch ID, or a device passcode.":
            ["fr": "Le verrouillage nécessite Face ID, Touch ID ou un code appareil.",
             "es": "El bloqueo necesita Face ID, Touch ID o un código del dispositivo.",
             "de": "App-Sperre braucht Face ID, Touch ID oder Gerätecode."],
        "Require %@ to reveal private tabs after you leave Searxly. Their contents stay hidden in the tab switcher until you unlock.":
            ["fr": "Exiger %@ pour révéler les onglets privés après avoir quitté Searxly. Leur contenu reste masqué jusqu'au déverrouillage.",
             "es": "Requerir %@ para revelar pestañas privadas al volver. Su contenido sigue oculto hasta desbloquear.",
             "de": "%@ verlangen, um private Tabs nach dem Verlassen freizugeben. Inhalt bleibt bis zur Entsperrung verborgen."],
        "Unlock with %@": ["fr": "Déverrouiller avec %@", "es": "Desbloquear con %@", "de": "Mit %@ entsperren"],
        "Searxly's AI runs entirely on this device with Apple Intelligence — nothing is sent to any server, ever, which is also why it works in private tabs.":
            ["fr": "L'IA de Searxly tourne entièrement sur cet appareil avec Apple Intelligence — rien n'est envoyé à un serveur, d'où le mode privé.",
             "es": "La IA de Searxly corre por completo en este dispositivo con Apple Intelligence — no se envía nada a un servidor, por eso funciona en privado.",
             "de": "Searxlys KI läuft ganz auf diesem Gerät mit Apple Intelligence — nichts geht an einen Server, daher auch privat."],
        "A short answer above web results, grounded strictly in the result snippets with cited sources and follow-up searches. Generates automatically for question-like searches; other searches get a Generate button.":
            ["fr": "Une courte réponse au-dessus des résultats, ancrée dans les extraits avec sources et suites. Auto pour les questions ; sinon un bouton Générer.",
             "es": "Una respuesta breve sobre los resultados, anclada en extractos con fuentes y búsquedas siguientes. Automática en preguntas; si no, Generar.",
             "de": "Kurze Antwort über Ergebnissen, strikt aus Snippets mit Quellen und Folgesuchen. Automatisch bei Fragen; sonst Generieren."],
        "Page tools appear in the ⋯ menu while browsing: Find highlights matches with the system navigator, Reader extracts a clean article, Summarize and Ask use only the page text on-device.":
            ["fr": "Les outils de page sont dans le menu ⋯ : Rechercher met en surbrillance, Lecteur extrait l'article, Résumer et Demander n'utilisent que le texte local.",
             "es": "Las herramientas de página están en ⋯: Buscar resalta, Lector extrae el artículo, Resumir y Preguntar usan solo el texto en el dispositivo.",
             "de": "Seitenwerkzeuge im ⋯-Menü: Suchen markiert, Reader extrahiert den Artikel, Zusammenfassen und Fragen nutzen nur den Text auf dem Gerät."],
        "Ad & tracker blocking uses bundled uBlock Origin filter lists (EasyList, EasyPrivacy, Peter Lowe, uBO) — fully local, nothing is downloaded. Fingerprint Protection randomizes canvas and audio readouts each session. GPC tells sites not to sell or share your data. Changes apply to new tabs.":
            ["fr": "Le blocage utilise des listes uBlock intégrées (EasyList, EasyPrivacy, Peter Lowe, uBO) — tout local. L'empreinte est randomisée chaque session. GPC demande de ne pas vendre vos données. S'applique aux nouveaux onglets.",
             "es": "El bloqueo usa listas uBlock incluidas (EasyList, EasyPrivacy, Peter Lowe, uBO) — todo local. La huella se aleatoriza cada sesión. GPC pide no vender tus datos. Aplica a pestañas nuevas.",
             "de": "Blockierung nutzt gebündelte uBlock-Listen (EasyList, EasyPrivacy, Peter Lowe, uBO) — rein lokal. Fingerabdruck wird pro Session randomisiert. GPC signalisiert: Daten nicht verkaufen. Gilt für neue Tabs."],
        "Removes cookie-consent pop-ups and the scroll locks they add. Never clicks “Accept” for you — your Do-Not-Sell (GPC) signal already states your preference.":
            ["fr": "Retire les pop-ups cookies et leurs verrous de défilement. Ne clique jamais sur « Accepter » — le signal GPC exprime déjà votre préférence.",
             "es": "Quita pop-ups de cookies y sus bloqueos de scroll. Nunca pulsa «Aceptar» por ti — GPC ya expresa tu preferencia.",
             "de": "Entfernt Cookie-Pop-ups und Scroll-Sperren. Klickt nie „Akzeptieren“ — GPC signalisiert bereits deine Präferenz."],
        "HTTPS-Only upgrades insecure links and asks before ever loading plain HTTP. Link cleaning strips identifiers like utm_ and fbclid. AMP pages are replaced by the publisher's real page.":
            ["fr": "HTTPS-uniquement met à niveau les liens et demande avant tout HTTP. Le nettoyage retire utm_ et fbclid. Les AMP cèdent la place à la vraie page.",
             "es": "Solo HTTPS actualiza enlaces e interroga antes de HTTP. La limpieza quita utm_ y fbclid. AMP se sustituye por la página real.",
             "de": "Nur-HTTPS upgradet Links und fragt vor HTTP. Link-Bereinigung entfernt utm_ und fbclid. AMP wird durch die echte Seite ersetzt."],
        "Ad & tracker blocking is reduced on these sites. Reload their tabs after raising.":
            ["fr": "Le blocage est réduit sur ces sites. Rechargez les onglets après avoir relevé les boucliers.",
             "es": "El bloqueo se reduce en estos sitios. Recarga las pestañas tras subir escudos.",
             "de": "Blockierung ist auf diesen Sites reduziert. Tabs nach dem Anheben neu laden."],
        "History stays on this device only, encrypted at rest. Pop-up blocking stops sites opening extra windows. Clear on Exit wipes cookies and site data from previous sessions when Searxly starts, and disables tab restore.":
            ["fr": "L'historique reste chiffré sur l'appareil. Les pop-ups sont bloqués. Effacer à la sortie vide cookies et données au démarrage, et désactive la restauration d'onglets.",
             "es": "El historial queda cifrado en el dispositivo. Se bloquean pop-ups. Borrar al salir limpia cookies al arrancar y desactiva restaurar pestañas.",
             "de": "Verlauf bleibt verschlüsselt auf dem Gerät. Pop-ups werden blockiert. Beim Beenden löschen leert Cookies beim Start und deaktiviert Tab-Wiederherstellung."],
        "Reopens your last normal tabs encrypted on disk. Private tabs are never restored.":
            ["fr": "Rouvre vos derniers onglets normaux chiffrés sur le disque. Les onglets privés ne sont jamais restaurés.",
             "es": "Reabre tus últimas pestañas normales cifradas en disco. Las privadas nunca se restauran.",
             "de": "Öffnet die letzten normalen Tabs verschlüsselt von der Disk. Private Tabs werden nie wiederhergestellt."],
        "Search instance URL": ["fr": "URL de l'instance", "es": "URL de la instancia", "de": "Instanz-URL"],
        "Reset to default": ["fr": "Réinitialiser par défaut", "es": "Restablecer predeterminado", "de": "Auf Standard zurücksetzen"],
        "Search instance": ["fr": "Instance de recherche", "es": "Instancia de búsqueda", "de": "Suchinstanz"],
        "Using the Searxly search instance (search.searxly.app). You can point this at any SearXNG instance with the JSON API enabled — including one you self-host.":
            ["fr": "Instance Searxly (search.searxly.app). Vous pouvez viser toute instance SearXNG avec l'API JSON — y compris auto-hébergée.",
             "es": "Instancia Searxly (search.searxly.app). Puedes apuntar a cualquier SearXNG con API JSON — incluida una autoalojada.",
             "de": "Searxly-Instanz (search.searxly.app). Jede SearXNG-Instanz mit JSON-API ist möglich — auch selbst gehostet."],
        "Advanced — search instance": ["fr": "Avancé — instance de recherche", "es": "Avanzado — instancia de búsqueda", "de": "Erweitert — Suchinstanz"],
        "Content Filter": ["fr": "Filtre de contenu", "es": "Filtro de contenido", "de": "Inhaltsfilter"],
        "Searches use %@.": ["fr": "Les recherches utilisent %@.", "es": "Las búsquedas usan %@.", "de": "Suchen nutzen %@."],
        "Searxly's changes to SearXNG (its theme and configuration) are published at the source link above under the same AGPL-3.0 license — you're free to download, run, and redistribute them.":
            ["fr": "Les changements Searxly à SearXNG (thème et config) sont publiés au lien source sous AGPL-3.0 — téléchargez, exécutez, redistribuez librement.",
             "es": "Los cambios de Searxly a SearXNG (tema y config) están en el enlace fuente bajo AGPL-3.0 — descarga, ejecuta y redistribuye libremente.",
             "de": "Searxlys Änderungen an SearXNG (Theme und Config) stehen unter dem Quellenlink unter AGPL-3.0 — frei herunterladen, ausführen, weitergeben."],
        "Last updated: %@": ["fr": "Dernière mise à jour : %@", "es": "Última actualización: %@", "de": "Zuletzt aktualisiert: %@"],
        "View online": ["fr": "Voir en ligne", "es": "Ver en línea", "de": "Online ansehen"],
        "Page options": ["fr": "Options de la page", "es": "Opciones de la página", "de": "Seitenoptionen"],
        "Opening Reader…": ["fr": "Ouverture du Lecteur…", "es": "Abriendo Lector…", "de": "Reader wird geöffnet…"],
        "%d min read": ["fr": "%d min de lecture", "es": "%d min de lectura", "de": "%d Min. Lesezeit"],
        "No matches": ["fr": "Aucune correspondance", "es": "Sin coincidencias", "de": "Keine Treffer"],
        "%d matches": ["fr": "%d correspondances", "es": "%d coincidencias", "de": "%d Treffer"],
        "Close all tabs and clear website data?":
            ["fr": "Fermer tous les onglets et effacer les données de site ?",
             "es": "¿Cerrar todas las pestañas y borrar datos web?",
             "de": "Alle Tabs schließen und Website-Daten löschen?"],
        "Closes every tab (including private) and erases cookies, caches, and site data. Bookmarks and history are kept.":
            ["fr": "Ferme chaque onglet (y compris privé) et efface cookies, caches et données. Signets et historique sont conservés.",
             "es": "Cierra todas las pestañas (incluidas privadas) y borra cookies, cachés y datos. Se conservan marcadores e historial.",
             "de": "Schließt jeden Tab (auch privat) und löscht Cookies, Caches und Site-Daten. Lesezeichen und Verlauf bleiben."],
        "Open in another app?": ["fr": "Ouvrir dans une autre app ?", "es": "¿Abrir en otra app?", "de": "In anderer App öffnen?"],

        // ── Onboarding film ──
        "Skip": ["fr": "Passer", "es": "Omitir", "de": "Überspringen"],
        "Continue": ["fr": "Continuer", "es": "Continuar", "de": "Weiter"],
        "Start browsing": ["fr": "Commencer à naviguer", "es": "Empezar a navegar", "de": "Surfen starten"],
        "Watch again": ["fr": "Revoir", "es": "Ver de nuevo", "de": "Nochmal ansehen"],
        "Tap to continue":
            ["fr": "Touchez pour continuer", "es": "Toca para continuar", "de": "Zum Fortfahren tippen"],
        "Double-tap to continue":
            ["fr": "Touchez deux fois pour continuer",
             "es": "Pulsa dos veces para continuar",
             "de": "Zum Fortfahren doppeltippen"],
        "Go back": ["fr": "Revenir", "es": "Volver", "de": "Zurück"],
        "Summary": ["fr": "Résumé", "es": "Resumen", "de": "Zusammenfassung"],
        "PRIVATE. YOURS.": ["fr": "PRIVÉ. À VOUS.", "es": "PRIVADO. TUYO.", "de": "PRIVAT. DEINS."],
        "A private browser for iPhone":
            ["fr": "Un navigateur privé pour iPhone",
             "es": "Un navegador privado para iPhone",
             "de": "Ein privater Browser für das iPhone"],
        "No accounts": ["fr": "Sans compte", "es": "Sin cuentas", "de": "Keine Konten"],
        "No tracking": ["fr": "Sans pistage", "es": "Sin rastreo", "de": "Kein Tracking"],
        "On-device AI": ["fr": "IA sur l'appareil", "es": "IA en el dispositivo", "de": "On-Device-KI"],
        "blocked": ["fr": "bloqués", "es": "bloqueados", "de": "blockiert"],
        "Replay onboarding":
            ["fr": "Revoir l'introduction",
             "es": "Volver a ver la introducción",
             "de": "Einführung erneut abspielen"],
        "Private search": ["fr": "Recherche privée", "es": "Búsqueda privada", "de": "Private Suche"],
        "Blocked before it loads":
            ["fr": "Bloqué avant le chargement",
             "es": "Bloqueado antes de cargar",
             "de": "Blockiert, bevor es lädt"],
        "Ads, trackers, and fingerprinting are stopped on this device, with filter lists that ship inside the app.":
            ["fr": "Pubs, traqueurs et empreinte numérique sont arrêtés sur cet appareil, avec des listes de filtres intégrées à l'app.",
             "es": "Anuncios, rastreadores y huellas digitales se detienen en este dispositivo, con listas de filtros incluidas en la app.",
             "de": "Werbung, Tracker und Fingerprinting werden auf diesem Gerät gestoppt — mit Filterlisten, die in der App stecken."],
        "Search without a profile":
            ["fr": "Cherchez sans profil", "es": "Busca sin perfil", "de": "Suchen ohne Profil"],
        "No accounts. No ads in results. No telemetry. Queries go through private search — not a surveillance engine.":
            ["fr": "Pas de comptes. Pas de pubs dans les résultats. Pas de télémétrie. Les requêtes passent par la recherche privée — pas un moteur de surveillance.",
             "es": "Sin cuentas. Sin anuncios en resultados. Sin telemetría. Las consultas van por búsqueda privada — no un motor de vigilancia.",
             "de": "Keine Konten. Keine Werbung in Ergebnissen. Keine Telemetrie. Anfragen gehen durch private Suche — keine Überwachungsmaschine."],
        "No profile": ["fr": "Sans profil", "es": "Sin perfil", "de": "Kein Profil"],
        "No ads": ["fr": "Sans pubs", "es": "Sin anuncios", "de": "Keine Werbung"],
        "No telemetry": ["fr": "Sans télémétrie", "es": "Sin telemetría", "de": "Keine Telemetrie"],
        "What is a private search engine?":
            ["fr": "Qu'est-ce qu'un moteur de recherche privé ?",
             "es": "¿Qué es un buscador privado?",
             "de": "Was ist eine private Suchmaschine?"],
        "SearXNG — open-source metasearch":
            ["fr": "SearXNG — métamoteur open source",
             "es": "SearXNG — metabuscador open source",
             "de": "SearXNG — Open-Source-Metasuche"],
        "How tracking-free search works":
            ["fr": "Comment fonctionne la recherche sans pistage",
             "es": "Cómo funciona la búsqueda sin rastreo",
             "de": "So funktioniert trackingfreie Suche"],
        "AI Overview, page summaries, and “ask about this page” run with Apple Intelligence on-device. The page never leaves your phone — which is why it works in private tabs.":
            ["fr": "Aperçu IA, résumés et « poser une question » tournent avec Apple Intelligence sur l'appareil. La page ne quitte jamais le téléphone — d'où le mode privé.",
             "es": "Resumen de IA, resúmenes de página y «preguntar sobre la página» corren con Apple Intelligence en el dispositivo. La página no sale del teléfono — por eso funciona en privado.",
             "de": "KI-Überblick, Zusammenfassungen und „Fragen zur Seite“ laufen mit Apple Intelligence on-device. Die Seite verlässt nie das Telefon — daher privat nutzbar."],
        "Yours": ["fr": "À vous", "es": "Tuyo", "de": "Deins"],
        "Yours alone": ["fr": "Rien qu'à vous", "es": "Solo tuyo", "de": "Nur deins"],
        "Bookmarks and history stay encrypted on this device. Private tabs leave no trace. There is no Searxly account — and nothing to sell.":
            ["fr": "Signets et historique restent chiffrés ici. Les onglets privés ne laissent aucune trace. Pas de compte Searxly — et rien à vendre.",
             "es": "Marcadores e historial quedan cifrados aquí. Las pestañas privadas no dejan rastro. No hay cuenta Searxly — ni nada que vender.",
             "de": "Lesezeichen und Verlauf bleiben hier verschlüsselt. Private Tabs hinterlassen keine Spur. Kein Searxly-Konto — und nichts zu verkaufen."],
        "Private.": ["fr": "Privé.", "es": "Privado.", "de": "Privat."],
        "Yours.": ["fr": "À vous.", "es": "Tuyo.", "de": "Deins."],
        "No accounts. No tracking. Just the web.":
            ["fr": "Pas de comptes. Pas de pistage. Juste le web.",
             "es": "Sin cuentas. Sin rastreo. Solo la web.",
             "de": "Keine Konten. Kein Tracking. Nur das Web."],

        // ── Privacy report + page info + HTTPS ──
        "tracking requests blocked":
            ["fr": "requêtes de pistage bloquées",
             "es": "solicitudes de rastreo bloqueadas",
             "de": "Tracking-Anfragen blockiert"],
        "Top Trackers Blocked":
            ["fr": "Principaux traqueurs bloqués",
             "es": "Principales rastreadores bloqueados",
             "de": "Top blockierte Tracker"],
        "Counted on-device from tracker requests attempted against pages you visited while shields were up — an undercount of what the filter lists actually block. Nothing here ever leaves this device.":
            ["fr": "Compté sur l'appareil à partir des requêtes de traqueurs pendant que les boucliers étaient actifs — sous-estimation de ce que les listes bloquent. Rien ne quitte cet appareil.",
             "es": "Contado en el dispositivo a partir de peticiones de rastreadores con escudos activos — es una subestimación. Nada sale de este dispositivo.",
             "de": "On-device gezählt aus Tracker-Anfragen bei aktiven Schilden — Unterschätzung der Listen. Nichts verlässt dieses Gerät."],
        "Connection is encrypted":
            ["fr": "Connexion chiffrée", "es": "Conexión cifrada", "de": "Verbindung verschlüsselt"],
        "Connection is not fully secure":
            ["fr": "Connexion pas entièrement sécurisée",
             "es": "Conexión no del todo segura",
             "de": "Verbindung nicht vollständig sicher"],
        "Trackers blocked on this page":
            ["fr": "Traqueurs bloqués sur cette page",
             "es": "Rastreadores bloqueados en esta página",
             "de": "Tracker auf dieser Seite blockiert"],
        "Shields for %@":
            ["fr": "Boucliers pour %@", "es": "Escudos para %@", "de": "Schilde für %@"],
        "Lowering shields turns off ad & tracker blocking for this site only (reloads the page).":
            ["fr": "Baisser les boucliers désactive le blocage pubs/traqueurs pour ce site uniquement (recharge la page).",
             "es": "Bajar escudos desactiva el bloqueo de anuncios/rastreadores solo para este sitio (recarga la página).",
             "de": "Schilde senken schaltet Werbe-/Tracker-Blockierung nur für diese Site aus (lädt die Seite neu)."],
        "Remembered for %@ — pages on this site always load this way.":
            ["fr": "Mémorisé pour %@ — les pages de ce site se chargent toujours ainsi.",
             "es": "Recordado para %@ — las páginas de este sitio siempre cargan así.",
             "de": "Für %@ gemerkt — Seiten dieser Site laden immer so."],
        "Site Data Erased":
            ["fr": "Données du site effacées", "es": "Datos del sitio borrados", "de": "Site-Daten gelöscht"],
        "Erase Site Data & Reload":
            ["fr": "Effacer les données du site et recharger",
             "es": "Borrar datos del sitio y recargar",
             "de": "Site-Daten löschen & neu laden"],
        "Deletes cookies, caches, and storage that %@ keeps on this device, then reloads it signed out and fresh.":
            ["fr": "Supprime cookies, caches et stockage que %@ garde sur cet appareil, puis recharge déconnecté et propre.",
             "es": "Borra cookies, cachés y almacenamiento que %@ guarda en este dispositivo y recarga limpio.",
             "de": "Löscht Cookies, Caches und Speicher von %@ auf diesem Gerät und lädt abgemeldet und frisch."],
        "Site doesn't support HTTPS":
            ["fr": "Le site ne prend pas en charge HTTPS",
             "es": "El sitio no admite HTTPS",
             "de": "Die Site unterstützt kein HTTPS"],
        "This site": ["fr": "Ce site", "es": "Este sitio", "de": "Diese Site"],
        "“%@” couldn't be loaded securely. Load it over an unencrypted connection just for this session?":
            ["fr": "« %@ » n'a pas pu être chargé en sécurité. Le charger en non chiffré pour cette session ?",
             "es": "No se pudo cargar “%@” de forma segura. ¿Cargarlo sin cifrado solo en esta sesión?",
             "de": "„%@“ konnte nicht sicher geladen werden. Für diese Sitzung unverschlüsselt laden?"],
    ]
}
