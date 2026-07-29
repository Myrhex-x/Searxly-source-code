//
//  MediaPlayback.swift
//  SearxlyiOS
//
//  Background audio + Picture in Picture for web media.
//
//  Two things stand between a <video> in a WKWebView and Safari-grade media behaviour:
//
//  1. Leaving the app. TabsModel pauses ALL media when the app backgrounds — that is the fix for
//     "backgrounded Searxly heats the phone and drains the battery all day", where a page quietly
//     autoplaying media kept WebKit's media session, and so the whole app, awake indefinitely.
//     Background audio wants the exact opposite, so the exemption is deliberately narrow: only the
//     ACTIVE tab, only when it was genuinely playing at the moment we backgrounded, and only when
//     the user asked for it (or put the video in Picture in Picture, which says the same thing).
//     Every other tab is paused exactly as before, so a page autoplaying in a background tab can
//     never be what holds the app awake.
//
//     Playback state is tracked LIVE from play/pause events rather than probed when the app
//     backgrounds: evaluating JavaScript while the app is being suspended is a race we would lose.
//
//  2. Picture in Picture. WKWebView permits it, but sites with custom players — YouTube among them —
//     never expose the control, so on iOS there is simply no way in. `pictureInPictureJS` reaches
//     past the site's own UI and asks the media element directly via WebKit's presentation-mode API.
//
//  The watcher is main-frame only. Third-party iframe players (an embedded YouTube on a blog) are
//  therefore not counted as "playing", and fall back to the old behaviour — paused on background.
//  That is the safe direction to be wrong in, and it keeps us out of the business of reconciling
//  play/pause state across an arbitrary number of frames.
//

import AVFoundation
import Foundation
import WebKit

@MainActor
enum MediaPlayback {

    static let messageHandlerName = "searxlyMedia"

    /// Installs the play/pause reporter on a new web view's configuration.
    static func apply(to configuration: WKWebViewConfiguration, handler: MediaMessageHandler) {
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.userContentController.add(handler, name: messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: watcherScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    /// Starting category, set at launch and whenever the setting changes. `.playback` is the only
    /// category that survives the app leaving the foreground; it also means media ignores the
    /// ring/silent switch, which is what Safari does and what someone who turned this on is asking
    /// for.
    ///
    /// This alone is NOT enough to keep playing in the background — see `setAudioSessionActive`.
    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if SearchSettings.shared.backgroundMedia {
                try session.setCategory(.playback, mode: .moviePlayback)
            } else {
                try session.setCategory(.ambient)
            }
        } catch {
            // A failed category change costs us background audio, nothing else — the media
            // suspension path still runs and the app behaves as it did before the feature.
        }
    }

    /// Claims the audio session while media plays, and hands it back when it stops.
    ///
    /// Setting the category at launch is not sufficient, for two separate reasons — either one on
    /// its own is enough to make the feature look completely dead:
    ///
    ///   1. A session that is never ACTIVATED does not keep the process running. iOS suspends the
    ///      app the moment it backgrounds and playback stops, no matter which media we did or did
    ///      not suspend. That is exactly what "it stops the second you leave the app" looks like,
    ///      and it happens whether the video is muted or not.
    ///   2. WKWebView installs its own audio-session category when media starts, so whatever we set
    ///      at launch has already been overwritten by the time it would matter.
    ///
    /// Both are answered by (re)asserting the category and activating at the moment playback
    /// begins, which is why this is driven off the watcher's play/pause events rather than done
    /// once up front.
    ///
    /// Taking the session interrupts other apps' audio, so it is claimed only while something is
    /// actually playing and only when the user opted in (or put a video in Picture in Picture);
    /// giving it back notifies whatever we interrupted so Music or a podcast resumes on its own.
    static func setAudioSessionActive(_ active: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if active {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } else {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        } catch {
            // Losing the session costs background playback and nothing else.
        }
    }

    /// Called on every play/pause transition. Leaves the session untouched unless this is media the
    /// user asked to keep alive, so an ordinary muted autoplay never interrupts anyone's music.
    static func syncAudioSession(playing: Bool, inPictureInPicture: Bool) {
        guard SearchSettings.shared.backgroundMedia || inPictureInPicture else { return }
        setAudioSessionActive(playing)
    }

    /// Toggles Picture in Picture on the page's main video. Returns the resulting presentation
    /// mode, or `nil` when the page has no video / WebKit refused.
    ///
    /// Picks whatever is actually playing over whatever is merely biggest, so a page with a muted
    /// hero-banner loop above the real player does not win.
    static let pictureInPictureJS = """
    (function() {
        try {
            var best = null, bestScore = -1;
            var vids = document.querySelectorAll('video');
            for (var i = 0; i < vids.length; i++) {
                var v = vids[i];
                var r = v.getBoundingClientRect();
                // Playing beats big: the offset dwarfs any plausible on-screen area.
                var score = (r.width * r.height) + (v.paused ? 0 : 1e9);
                if (score > bestScore) { bestScore = score; best = v; }
            }
            if (!best) return 'none';
            if (typeof best.webkitSetPresentationMode !== 'function') return 'unsupported';
            var mode = best.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture';
            best.webkitSetPresentationMode(mode);
            return mode;
        } catch (e) {
            return 'error';
        }
    })();
    """

    /// Reports "is anything playing" and "is anything in Picture in Picture" transitions.
    ///
    /// Media events do not bubble, so the listeners are registered in the CAPTURE phase on
    /// `document` — that catches every <video>/<audio>, including ones added later by the page,
    /// without a MutationObserver or a polling timer.
    private static let watcherScript = """
    (function() {
        'use strict';
        if (window.__searxlyMediaWatcher) return;
        window.__searxlyMediaWatcher = true;

        var lastPlaying = null, lastPiP = null;

        function anyPlaying() {
            var els = document.querySelectorAll('video, audio');
            for (var i = 0; i < els.length; i++) {
                var m = els[i];
                if (!m.paused && !m.ended) return true;
            }
            return false;
        }

        function anyPiP() {
            var els = document.querySelectorAll('video');
            for (var i = 0; i < els.length; i++) {
                if (els[i].webkitPresentationMode === 'picture-in-picture') return true;
            }
            return false;
        }

        function report() {
            var playing = anyPlaying(), pip = anyPiP();
            if (playing === lastPlaying && pip === lastPiP) return;  // only transitions cross the bridge
            lastPlaying = playing;
            lastPiP = pip;
            try {
                window.webkit.messageHandlers.searxlyMedia.postMessage({ playing: playing, pip: pip });
            } catch (e) {}
        }

        ['play', 'playing', 'pause', 'ended', 'emptied', 'webkitpresentationmodechanged']
            .forEach(function(evt) { document.addEventListener(evt, report, true); });

        // A page can be restored from the back/forward cache mid-playback with no further events.
        window.addEventListener('pageshow', report);
        window.addEventListener('pagehide', function() {
            if (lastPlaying !== false || lastPiP !== false) {
                lastPlaying = false; lastPiP = false;
                try {
                    window.webkit.messageHandlers.searxlyMedia.postMessage({ playing: false, pip: false });
                } catch (e) {}
            }
        });
    })();
    """
}

// MARK: - Bridge

/// Receives play/pause/PiP transitions from the watcher script. A separate NSObject because the
/// user content controller retains its message handlers (the weak model reference breaks the cycle).
final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
    weak var model: BrowserModel?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == MediaPlayback.messageHandlerName,
              let body = message.body as? [String: Any] else { return }
        let playing = body["playing"] as? Bool ?? false
        let pip = body["pip"] as? Bool ?? false
        MainActor.assumeIsolated {
            model?.isPlayingMedia = playing
            model?.isInPictureInPicture = pip
            // Claim/release the audio session here rather than at background time: by the time the
            // app is being suspended it is far too late to start holding a session.
            MediaPlayback.syncAudioSession(playing: playing, inPictureInPicture: pip)
        }
    }
}
