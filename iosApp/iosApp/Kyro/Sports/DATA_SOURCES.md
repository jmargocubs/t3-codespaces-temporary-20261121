# Sports Hub Data Sources

This file records the assumptions for Kyro's private, noncommercial, sideloaded
build. It is not an App Store or redistribution plan. Public network access and
permission to reuse data are different questions; a keyless endpoint is not by
itself a licence.

Checked 2026-11-10.

## Integrated sources

### ESPN site API

Host: `https://site.api.espn.com`

Sports Hub already uses ESPN's site scoreboard endpoints for NFL, NBA, NHL,
MLB, FBS college football, ATP, WTA and the verified soccer registry. The Stats and News tabs now use the
same provider event identity for these additional endpoints:

- `/apis/site/v2/sports/{sport}/{league}/summary?event={espnEventID}`
- `/apis/site/v2/sports/{sport}/{league}/news?team={espnTeamID}&limit=20`

The summary response supplies team statistics and player box-score tables for
NFL, NBA, NHL, MLB and FBS when ESPN has opened a box score. It also supplies
an event recap when one exists. Team-news results are retained only when ESPN's
article categories contain a team ID from the validated selected event. Generic
league stories are dropped. Kyro displays headlines and dates, attributes ESPN,
and opens the publisher link; it does not copy article bodies or fabricate
summaries.

Matching is deliberately strict:

1. An ESPN game uses its namespaced ESPN event ID directly.
2. A Sleeper NFL fallback game may resolve through the existing ESPN scoreboard
   only when exactly one event has the same two canonical team abbreviations and
   starts within 30 minutes.
3. The summary must return the requested event ID and the same two teams before
   any statistic or headline is shown.
4. Ambiguous or mismatched responses become an unavailable state.

The detail cache is bounded, coalesces identical requests, sends ETags, honors
`Cache-Control: max-age`, keeps recent stale data for one hour after a transient
failure, and limits each response to 2 MiB. Live details are eligible to refresh
after 20 seconds when the provider does not specify a longer freshness period;
scheduled events use five minutes and final events use a longer cache. HTTP 429
or other failures are not retried in a loop.

For soccer, the route is `/apis/site/v2/sports/soccer/{competition}/scoreboard`
and the matching summary/news routes use the same competition slug. Kyro only
queries the selected local day, caps concurrent competition requests at three,
and stores the slug on each normalized game so a similarly named club or a
men's/women's match cannot cross-wire details or playback.

**Permission caveat:** these site endpoints are public and require no key, but
they are undocumented and ESPN does not publish a current self-service licence
for them. Disney's current consumer terms grant personal, noncommercial use but
also restrict automated extraction without permission. The old ESPN Developer
Center/API announcement does not establish current permission for these
endpoints. This implementation is therefore limited to the owner's private,
on-device compatibility use and must not be represented as licensed for public
distribution. Written permission or a documented replacement is still the
clean long-term answer.

- Disney terms: <https://disneytermsofuse.com/english-canada/>
- Historical ESPN API announcement: <https://espnpressroom.com/press-release/espn-launches-developer-center-and-api-program/>

### Sleeper

Host: `https://api.sleeper.app`

Sleeper remains the NFL cold-start fallback for schedule, scores, teams and
league state. Its documented read-only API is free for noncommercial use, needs
no token, and asks clients to remain below 1,000 calls per minute. Kyro keeps its
existing response caching, ETag handling and conservative call pattern. Sleeper
does not provide a player game box score through the endpoints currently used.

- Documentation and terms: <https://docs.sleeper.com/>

## Detail coverage

| League | Scoreboard | Team stats | Player box score | Event/team news |
| --- | --- | --- | --- | --- |
| NFL | ESPN; Sleeper fallback | ESPN summary | ESPN summary | ESPN recap + team-tagged headlines |
| NBA | ESPN | ESPN summary | ESPN summary | ESPN recap + team-tagged headlines |
| NHL | ESPN | ESPN summary | ESPN summary | ESPN recap + team-tagged headlines |
| MLB | ESPN | ESPN summary | ESPN summary | ESPN recap + team-tagged headlines |
| FBS college football | ESPN | ESPN summary when published | ESPN summary when published | ESPN recap + team-tagged headlines |
| ATP / WTA | ESPN | Set scores already in Game | Not enabled: ESPN match IDs return no supported summary | Not enabled |
| Soccer (verified registry) | ESPN scoreboard, selected day | ESPN summary team stats when published | ESPN roster match stats when published | ESPN recap + team-tagged headlines |

### Verified soccer competition registry

The data-driven registry currently contains these ESPN routes (HTTP 200 with a
valid league payload was observed on 2026-11-10): `eng.1`, `esp.1`, `ger.1`,
`ita.1`, `fra.1`, `ned.1`, `por.1`, `sco.1`, `bel.1`, `tur.1`, `aut.1`,
`gre.1`, `usa.1`, `mex.1`, `bra.1`, `bra.2`, `arg.1`, `col.1`, `chi.1`,
`uru.1`, `jpn.1`, `aus.1`, `chn.1`, `ind.1`, `uefa.champions`,
`uefa.europa`, `uefa.europa.conf`, `uefa.super_cup`, `conmebol.libertadores`,
`conmebol.sudamericana`, `concacaf.champions_cup`, `afc.champions`,
`caf.champions`, `fifa.cwc`, `uefa.euro`, `conmebol.america`, `concacaf.gold`,
`caf.nations`, `afc.asian.cup`, `usa.nwsl`, `eng.w.1`, `esp.w.1`, `fra.w.1`,
`fifa.wwc`, and `uefa.weuro`. Rejected/unverified probes such as `swi.1`,
`sau.1`, `jpn.2`, `kor.1`, `ger.w.1`, `ita.w.1`, `uefa.wchamp`, and `fifa.wc`
are intentionally not advertised as working. The registry can grow by adding
a verified row, without a new provider or UI code path.

A scheduled event can legitimately have no box score yet. That is different
from a failed or mismatched request and is worded accordingly in the UI.

## Evaluated zero-cost candidates

### TheSportsDB

The free API explicitly permits development projects and explicitly requires a
paid subscription only for published app-store apps, so Kyro's private sideload
fits the stated distribution rule. The free service is limited to 30 requests
per minute and many search/list endpoints return only a small number of rows.
It covers many sports and offers event, event-stat, lineup and timeline lookups.

It is not integrated yet because Kyro has ESPN/Sleeper IDs, TheSportsDB has no
documented crosswalk for those IDs, and sampled current schedules were not
complete enough to make a name/date join reliable. It remains the best stated-
permission candidate for a future cached secondary source. Artwork has separate
licence and trademark conditions and should not be pulled in casually.

- Terms: <https://api.thesportsdb.com/docs_terms_of_use.php>
- API and rate limits: <https://api.thesportsdb.com/documentation>

### CollegeFootballData.com

The free tier provides 1,000 calls per month and broad college game/team/player
data, but every call requires an API key. It is a good FBS enrichment candidate
after Kyro has a secure local secret setting and a durable monthly request
budget. No key is embedded in the app or repository.

- Getting started: <https://api.collegefootballdata.com/getting-started>
- Authentication: <https://github.com/CFBD/cfbd-net/blob/main/docs/authentication.md>

### football-data.org

The free soccer plan is free indefinitely, includes 12 competitions, delayed
scores/schedules/tables, and permits 10 authenticated requests per minute. It
requires an API token and visible `Data provided by football-data.org`
attribution. It is suitable when soccer becomes a first-class Sports Hub league,
but the free plan does not include the detailed live statistics requested here.

- Policies: <https://docs.football-data.org/general/v4/policies.html>
- Coverage: <https://www.football-data.org/coverage>
- Attribution: <https://www.football-data.org/documentation/faq>

### MLB and NHL first-party site feeds

`statsapi.mlb.com` and `api-web.nhle.com` are publicly reachable and keyless,
but neither league currently publishes clear external-developer documentation
and permission for the site feeds used by community projects. They were not
integrated merely because they answer HTTP requests. They may be reconsidered
if the leagues publish applicable personal-use API terms.

### Tennis datasets

The maintained mirrors of the Jeff Sackmann ATP/WTA datasets use CC BY-NC-SA
4.0, which is compatible with noncommercial use when attribution and ShareAlike
conditions are followed. They are historical/batch datasets rather than a
reliable live event-detail service, so they do not solve the selected-game box
score problem. ESPN set scoring remains the current tennis detail.

## Playback isolation

Detail loading is owned by the Stats/News content store below the pinned player.
It does not start, stop, replace or configure the Live TV session, stream
matching, AetherEngine, fullscreen or Picture in Picture. A detail error changes
only the selected tab's state. The Feed view remains mounted behind the other
tabs, preserving its filters and scroll position.
