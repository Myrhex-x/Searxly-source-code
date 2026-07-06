//
//  AppLocale.swift
//  SearxlyiOS
//
//  In-app interface language, independent from the search-results language (Settings ▸ Language):
//  "System" by default, or any explicit choice — applied LIVE to Searxly's own strings via `L()`
//  (views calling it observe languageCode, so the whole UI re-renders on change), and mirrored
//  into AppleLanguages so system furniture (Form controls, share sheet, WKWebView Accept-Language)
//  follows on the next launch — the same mechanism as macOS AppLanguage.
//
//  Translations are an in-code table keyed by the ENGLISH string (missing key/lang ⇒ English),
//  so call sites read naturally: Text(L("New Tab")).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppLocale {
    static let shared = AppLocale()

    private static let overrideKey = "searxly.ios.appLanguage"

    /// "" = follow the system. Otherwise an ISO 639-1 code from `supported`.
    var override: String {
        didSet {
            UserDefaults.standard.set(override, forKey: Self.overrideKey)
            if override.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([override, "en"], forKey: "AppleLanguages")
            }
        }
    }

    /// The language the interface renders in right now.
    var languageCode: String {
        if !override.isEmpty { return override }
        let sys = Locale.preferredLanguages.first ?? "en"
        return String(sys.prefix(2)).lowercased()
    }

    private init() {
        override = UserDefaults.standard.string(forKey: Self.overrideKey) ?? ""
    }

    /// Languages offered in the picker (translation coverage varies; English is the fallback).
    static let supported: [SearchLanguage] = SearchLanguage.all.filter { $0.code != "auto" }
}

/// Translate an interface string. The English text is the key; unknown key or language falls
/// back to English. Calling this inside a view body subscribes the view to language changes.
@MainActor
func L(_ english: String) -> String {
    let lang = AppLocale.shared.languageCode
    guard lang != "en" else { return english }
    return L10nTable.strings[english]?[lang] ?? english
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
        "Ask About This Page": ["fr": "Poser une question sur la page", "es": "Preguntar sobre esta página", "de": "Fragen zu dieser Seite"],
        "Ask about this page…": ["fr": "Poser une question sur la page…", "es": "Pregunta sobre esta página…", "de": "Frage zu dieser Seite…"],
        "What are the key points?": ["fr": "Quels sont les points clés ?", "es": "¿Cuáles son los puntos clave?", "de": "Was sind die Kernpunkte?"],
        "Explain this simply": ["fr": "Explique simplement", "es": "Explícalo de forma sencilla", "de": "Einfach erklären"],
        "Any caveats or criticism mentioned?": ["fr": "Des réserves ou critiques mentionnées ?", "es": "¿Se mencionan objeciones o críticas?", "de": "Werden Einwände oder Kritik erwähnt?"],
        "menu": ["fr": "menu", "es": "menú", "de": "Menü"],
        "Reader": ["fr": "Lecteur", "es": "Lector", "de": "Reader"],
        "No readable article on this page.": ["fr": "Aucun article lisible sur cette page.", "es": "No hay un artículo legible en esta página.", "de": "Kein lesbarer Artikel auf dieser Seite."],
        "Private tabs are locked": ["fr": "Les onglets privés sont verrouillés", "es": "Las pestañas privadas están bloqueadas", "de": "Private Tabs sind gesperrt"],
        "Private Tab": ["fr": "Onglet privé", "es": "Pestaña privada", "de": "Privater Tab"],
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
    ]
}
