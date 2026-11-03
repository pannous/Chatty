# watchOS: private APIs & "press a button, talk to Claude"

Researched 2026-10-30.

## BREAKTHROUGH (2026-10-30): Crown press interception without entitlement
Found in our own watchOS 27.0 header dump (`headers/watchOS-27.0`, made by `tools/dump-headers.sh`):
- `CSLSButtonTapAssertion` (CarouselServices): `-initWithButtons:completion:` + `-activate`.
  Button mask 1 = Crown, 3 = Crown + side button (values taken from PepperUICore callers).
  The completion fires on a press; the assertion is consumed, re-arm after each press.
- Carousel's `CSLButtonTapAssertionService listener:shouldAcceptNewConnection:` checks NO entitlement
  (disassembled). PepperUICore menus use it inside ordinary apps.
- By contrast `CSLSButtonListener` (global button handlers) requires `com.apple.carousel.button-listener`.
- Only works while our app is frontmost (presses elsewhere still go to the system).
- Verified in the simulator: `probes/crown-intercept.sh` (3 presses → counter 3, app stays frontmost).
- NOT yet verified on a real watch: the sandbox there may deny the mach lookup of
  `com.apple.Carousel.ButtonTapAssertion` (simulator sandboxing is laxer).

### Gestures (measured in simulator, `probes/crown-gestures.sh`)
- Tap assertion only receives `tap` events. Carousel turns presses < ~0.3 s apart into `double tap`
  (app switcher) and holds into long press (Siri, `SiriLongPressButtonSource`); neither reaches the assertion.
- So CrownTalk's "double press" = deliberate two taps 0.3–0.8 s apart; a lone tap is passed on by
  `CSLSNavigationService navigateToLocation:0` (watch face). `UIApplication -suspend` is ignored for the main scene.
- Taking over long press / real double tap needs `CSLSButtonListener` → entitlement
  `com.apple.carousel.button-listener` (not grantable to third-party apps). `CSLSRawButtonEventListener`
  is in-process only; `CSLSSuspendSystemGestureAssertion` covers screen-edge swipes, not buttons.

### Launching / returning to the app
- `CSLSNavigationService navigateToLocation:1 dockBundleID:<id> activateDockApp:YES` brings any app
  frontmost, even when not running (no entitlement check seen; `probes/navigate.m`).
  Locations: 0 watch face, 1 dock/app, 2 app grid, 4 Control Center.
- Public: any `WKBackgroundModes` entry makes the app "sticky" (`_examineBackgroundModesForStickiness:`),
  enabling Settings › General › Return to Clock › <app> › Return to App.

### Speech in / out
- Claude Messages API: text/image/document blocks only — no audio input, no STT, no TTS (checked 2026-10-30).
- watchOS SDK ships no Speech.framework (runtime has it, private). TTS: public `AVSpeechSynthesizer` (AVFAudio).
- STT plan: PepperUICore `PUICDictationViewController` (the dictation sheet every TextField uses, in-process):
  `-initWithDelegate:`, `-startDictation`; delegate `quickboard:textEntered:` / `quickboardInputCancelled:`.
  Fallbacks: public SwiftUI `TextFieldLink` (one extra tap), `AFDictationConnection` (AssistantServices),
  or record audio and transcribe on the iPhone (SpeechAnalyzer) via WatchConnectivity.

### OpenAI voice pipeline (measured 2026-10-30, Mac → api.openai.com, key in gitignored `.env`)
- Watch records AAC/M4A (AVAudioFile/AVAudioRecorder, verified in watch sim: `probes/audio-formats.swift`);
  OpenAI transcription accepts it. `say` needs `--data-format=aac` or OpenAI rejects the file.
- Watch decodes OpenAI TTS `aac` (ADTS) with AVAudioPlayer; `pcm` (24 kHz s16le mono) suits AVAudioEngine streaming.
- Latency: transcribe 1.5 s; `gpt-5.5` (reasoning low) Responses streaming first text ~2 s, total 3.6 s;
  `gpt-4o-mini-tts` pcm first byte 0.9 s. Sequential ≈ 6.8 s to first sound, streamed ≈ 4–4.5 s.
  `gpt-5.4-mini` was slower (3.7 s to first token).
- Responses API: text is in `output[type=message].content[type=output_text].text` (a `reasoning` item comes first).
- Realtime speech-to-speech (`gpt-realtime-2.1`) needs a WebSocket; watchOS only allows low-level networking
  (incl. URLSessionWebSocketTask) for audio-streaming / VoIP apps (TN3135), enforced on device, not in the simulator.

Simulator hygiene: a booted watch simulator left running (worse: Siri woken by the long-press test) spins
Carousel/corespeechd/assistantd at ~100 % CPU each. Every probe now shuts its simulator down on exit (`trap`).

Tooling quirks: `ipsw class-dump`/`a2s`/`disass` panic or print nothing on the watchOS 27 sim cache;
`ipsw dyld extract` + `xcrun llvm-objdump -d --start-address` works; constants resolved at runtime
via `probes/print-entitlement-names.m`. Headless button presses: `axe button home --udid …`.

## Private APIs: no remapping of hardware buttons outside our app
- Digital Crown press (Home / Siri on hold) and side button (Control Center / SOS) are handled by the
  system shell (Carousel/PepperUICore). No public or known private API lets a third-party app intercept them.
- Private frameworks can be dlopen'ed in a sideloaded (Xcode-signed) app, but the app stays sandboxed
  and lacks the entitlements Carousel uses, so button remapping is still impossible.
- No usable jailbreak for modern watchOS (only old Series 3 era / watchOS 6-7 tooling existed).
- Public crown access is rotation only: `digitalCrownRotation()` / `WKCrownSequencer`.

## Official hooks that get close
| Trigger | How |
|---|---|
| Crown long-press → Siri | Siri runs a Shortcut by name ("Claude") or an App Shortcut (App Intents) from our own app |
| Ultra Action button | watchOS 26: native `ControlWidget` backed by an App Intent; or assign a Shortcut |
| Control Center / Smart Stack | same watchOS 26 Control |
| Double tap (S9+/Ultra 2) | `.handGestureShortcut(.primaryAction)` on the record button (only while app is on screen) |
| Complication | tap launches app straight into recording |

## Zero-code version
Shortcuts on the watch: Dictate Text → Get Contents of URL (POST api.anthropic.com/v1/messages,
x-api-key header) → Get Dictionary Value content.0.text → Speak Text. Name it "Claude", then
hold crown and say "Claude".

## Header browsers (limneos-style) for watchOS
- developer.limneos.net covers iOS only (no watchOS/tvOS selector; blocks plain curl, needs a browser UA).
- No current online watchOS header browser found. Stale dumps only:
  - github.com/LeoNatan/Apple-Runtime-Headers `watchOS/PrivateFrameworks/` (archived 2022)
  - github.com/nickfrey/WatchOS-Headers (Carousel*, PepperUICore, NanoTimeKit; watchOS 1 era)
  - WebKit `Source/WebKit/Platform/spi/watchos/PepperUICoreSPI.h` (watchOS 8+, maintained)
- Fresh dump path: `brew install blacktop/tap/ipsw`, `xcodebuild -downloadPlatform watchOS`
  (simulator runtime, several GB), then `ipsw class-dump` on its dyld shared cache.
  Local Xcode has WatchOS27.0.sdk but the SDK ships no PrivateFrameworks.

## Existing third-party projects
- github.com/Erscheinung/ClaudeWatch (standalone voice LLM app)
- github.com/shobhit99/claude-watch, zackproser.com/blog/handwave (talk to Claude Code sessions on the Mac)
- github.com/crmitchelmore/justspeaktoit issue #964 (watchOS 26 Controls / Action button notes)

## Device findings (Series 7, 2026-10-30)
- AirPods output: `.playAndRecord` with `.allowBluetoothA2DP` alone stays on the watch speaker;
  adding `.allowBluetoothHFP` routes answers to the AirPods (their mic records too). Confirmed by the user.
- `AVAudioUnitEQ` is unavailable on watchOS: volume boost is done by scaling samples in `SpeechPlayer`.
- Screen-off cut the last words of answers: a `WKExtendedRuntimeSession` (WKBackgroundModes mindfulness) keeps the app alive.
- `xcrun devicectl device capture screenshot` works for the watch; `log collect --device-udid` needs root.
- Realtime WebSocket on the watch: `URLSessionWebSocketTask` fails with "The Internet connection appears to be offline"
  while plain URLSession HTTPS works (TN3135). TN3135 allows it for audio-streaming apps, likely only while a
  long-form audio session is active: untested.
- Long-form activation without headphones: "Resource not available"; the session is left inactive and the next
  engine start fails with AVAudioSession error 561145203 ('!res') unless re-activated.
- Device logs: `tools/watch-log.sh` pulls Documents/chatty.log written by `trace()`.
- Xcode console confirms: the Realtime WebSocket is "Path was denied by NECP policy" (TN3135), not a network outage.
- After `setCategory(.playback, policy: .longFormAudio)` a plain `setCategory(.playAndRecord, mode:options:)` fails
  with -50: the long-form policy sticks; pass `policy: .default` explicitly.
- 2026-11-03: main dropped both the Realtime path (WebSocket blocked by NECP on device anyway) and the long-form
  "podcast" route for answers; AirPods still get the answers through `.allowBluetoothHFP` (HFP quality).
  The Realtime/relay experiment lives on branch `me`.
