# Build 20 stabilization — device validation

Build 20's PiP and AVAudioSession behavior cannot be established by simulator
notifications or compilation. Use a physical iPhone and record the OS version,
Build 20/21 identifier, media route (native or software), player type (Live TV
or library media), audio session category/mode/activation, AVPlayer item status,
`timeControlStatus`/rate, current position, PiP delegate events, interruption
type/options, route-change reason, and `secondaryAudioShouldBeSilencedHint`.
Do not include stream URLs, credentials, or account identifiers in the capture.

## PiP / audio matrix (required before closing the issue)

1. **X/Twitter video:** Start playback, enter PiP, play an X video with sound,
   then stop it. Verify Kyro preserves the same player and position, resumes
   only when permitted, and PiP Play restores playback when the session can be
   activated. Record whether interruption begin/end notifications occur and
   their options; do not infer an interruption end from the competing video
   stopping.
2. **Another streaming app:** Repeat with a second video/audio app. Distinguish
   secondary-audio hints, interruption events, route changes, and stalls.
3. **Phone call / system interruption:** Enter PiP, receive and end a call (and
   separately invoke Siri if available). Confirm automatic resume only when the
   interruption grants `.shouldResume` and playback was active beforehand.
4. **Manual pause:** Pause Kyro before the other app or call takes audio. Verify
   Kyro remains paused after the event ends and after returning to Kyro.
5. **PiP Play recovery:** With competing audio stopped, tap Play in PiP. Verify
   the original player resumes without a reload, duplicate audio, or resume
   loop. Repeat when another app still owns audible output; Kyro must not fight
   that app.
6. **Restore to full player:** Use PiP's return control while playing and while
   paused. Verify the correct route, player, position, and pause intent return.
7. Repeat cases 1–6 with both **Live TV** and **library media** where supported.

Capture the device Console/Analytics crash report for any process termination.
Also distinguish a closed PiP window from a stopped stream and from an app
crash; the user's original report alone does not establish which occurred.

## Live TV navigation

On the same device, open Guide, Search, Favorites, Channels, and Settings from
Live TV Home. Verify each has an accessible contextual route back to Live TV
Home, preserves its browsing/search state and any active playback, and never
selects Kyro Home. Verify no second bottom navigation bar appears.

## More menu

With an authorized server/profile that enables Downloads, and then with one
that does not, verify More shows Downloads only in the enabled case. Remove
Calendar from the customizable primary menu and verify it remains reachable
from More. Verify Collections is absent from More while its existing
contextual library access remains. Verify unsupported and unauthorized roots
are not exposed and Downloads deep links still resolve to the Downloads route.
