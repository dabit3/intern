# Testing Launcher

## Clean install

```sh
git clone https://github.com/dabit3/launcher.git
cd launcher
xcodebuild -version                      # Xcode 16+ (verified with 26.6 on macOS 26.5, ARM64)
brew install xcodegen                    # 2.46.0; only needed if you edit project.yml
xcodegen generate                        # regenerates Launcher.xcodeproj from project.yml
```

The generated `Launcher.xcodeproj` is committed, so `xcodegen` is optional for a plain build.

## Automated checks

All three must pass. The default run does not touch the network: `LiveJevTests` skip unless the two variables in the next section are set.

```sh
xcodebuild -project Launcher.xcodeproj -scheme Launcher -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Launcher.xcodeproj -scheme Launcher -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
# expected: Executed 58 tests, with 0 failures (5 skipped without JEV_LIVE)

xcrun swift-format lint --strict --recursive Sources Tests
# expected: no output, exit 0
```

`xcodebuild test` prints a few `com.apple.linkd.autoShortcut` service warnings while launching the host app on macOS 26; they are harmless.

### What the unit tests cover

| File | Covers |
|---|---|
| `Tests/CalculatorTests.swift` | precedence, parentheses, `^`, unary minus, `sqrt`, `x` as multiply, `15% of 240` / `percent of` / `200 * 10%`, `calc` and `=` prefixes, original expression preserved for display, plain words and lone numbers rejected, number formatting |
| `Tests/RankingTests.swift` | fuzzy scoring (exact > prefix > subsequence, stopwords, word initials, subsequence contiguity); `Ranker.prefilter` adds the calculation and web-search candidates, respects the 13-candidate cap and returns nothing for an empty query; `Ranker.rank` is pure fuzzy without a judgment and follows Jev's target probability with one |
| `Tests/JevQuestionsTests.swift` | one request carries exactly the `target`, `action`, `ready`, `scope` and `match_cN` questions; candidate ids are `c0…cN` plus `none`; `state` encodes the query, note, context and candidate summaries; the 15-candidate cap; response parsing maps short ids back to real candidate ids, tolerates missing `action`/`ready`, returns nil without `target`; `timeOfDay` buckets |
| `Tests/SetsAndHistoryTests.swift` | Chrome epoch round-trip; history candidates (title, host, `visited N h ago`, keywords, untitled falls back to host); reading a copied `History` SQLite file with the window and `hidden` filters, missing file returns nothing; `TimeWindow.parse` for relative, named and bounded phrases (`yesterday` has both ends), remainder text; windowed prefilter drops dated items outside the window but keeps toggles, window-only queries (`everything from the past hour`); set ranking: group row first on `all` intent with members checked and web search last, group under the single hit when Jev is torn, no group (and no checkmarks) when P(all) is low or only one row fits or there is no judgment; mixed-kind group titles; request carries `scope` and `match_cN` for real candidates only and `time_window`; parsing set and match probabilities, tolerant of responses without them |
| `Tests/LiveJevTests.swift` | opt-in probes against the real API on the real index (see below) |
| `Tests/StatsAndIndexTests.swift` | latency stats empty state, p50/p95 (nearest-rank), token totals and cost at $0.042/M input tokens, failure and stale counters, decisions/sec window, 500-sample cap; `LocalIndex.recency` phrasing; file candidates built from a temp directory (title, kind, subtitle, keywords); the nine system toggles are present; `Executor.wifiDevice` parses `networksetup -listallhardwareports` output |

## Live probes

`Tests/LiveJevTests.swift` runs the set and single queries from the README against the real API using the machine's real index, prints every candidate with its target and match probability, and asserts the expected shape (group row on top for the Ambassador and last-hour-files queries, no group for `the pdf I just downloaded`, `dark`, `wifi off`). It needs the fixtures below and the two variables forwarded into the test runner:

```sh
TEST_RUNNER_JEV_LIVE=1 TEST_RUNNER_TYPESAFE_API_KEY="$TYPESAFE_API_KEY" \
  xcodebuild -project Launcher.xcodeproj -scheme Launcher -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  -only-testing:LauncherTests/LiveJevTests test
```

## Manual verification (live Jev)

Requires `TYPESAFE_API_KEY` in the shell. Everything below was run on the VM; screenshots of each step are in `docs/`.

### 1. Fixtures

The PDF query needs several files of different ages to disambiguate. Create them once:

```sh
printf 'placeholder\n' > ~/Downloads/Q3-Roadmap-Review.pdf
printf 'placeholder\n' > ~/Downloads/invoice-2026-08.pdf   && touch -t 202608011200 ~/Downloads/invoice-2026-08.pdf
printf 'x' > ~/Downloads/xcode-installer.dmg               && touch -t 202609101200 ~/Downloads/xcode-installer.dmg
printf 'x' > ~/Downloads/screenshot-2026-09-17.png
printf 'placeholder\n' > ~/Desktop/Lease-Agreement.pdf     && touch -t 202607011200 ~/Desktop/Lease-Agreement.pdf
```

For the set queries, two more files modified within the last hour and some Chrome history. The VM had no browsing history, so it was seeded (Chrome must be quit; this **replaces** the `urls`/`visits` tables of the Default profile, so only do it on a throwaway machine):

```sh
touch ~/Downloads/Design-Review-Notes.pdf ~/Downloads/Hiring-Plan-Q4.pdf
python3 - <<'EOF'
import os, sqlite3, time
H = os.path.expanduser("~/Library/Application Support/Google/Chrome/Default/History")
EPOCH, now = 11644473600, time.time()
ct = lambda h: int((now - h * 3600 + EPOCH) * 1_000_000)
rows = [
  ("https://cognition.ai/blog/devin-ambassador-program", "Introducing the Devin Ambassador Program", 2),
  ("https://docs.devin.ai/ambassadors/getting-started", "Devin Ambassadors: Getting Started", 5),
  ("https://community.devin.ai/t/ambassador-kickoff-call", "Ambassador kickoff call notes - Devin Community", 20),
  ("https://cognition.ai/blog/devin-ambassador-program?ref=tw", "Introducing the Devin Ambassador Program", 70),
  ("https://www.youtube.com/watch?v=lofi", "lofi hip hop radio - beats to relax/study to", 1),
  ("https://github.com/dabit3/jev-experiments", "dabit3/jev-experiments", 3),
  ("https://news.ycombinator.com/", "Hacker News", 4),
  ("https://docs.typesafe.ai/concepts/system-one", "System One - TypeSafe Docs", 6),
  ("https://en.wikipedia.org/wiki/Transformer_(deep_learning)", "Transformer (deep learning) - Wikipedia", 30),
]
db = sqlite3.connect(H)
db.execute("DELETE FROM visits"); db.execute("DELETE FROM urls")
for i, (u, t, h) in enumerate(rows, 1):
  db.execute("INSERT INTO urls(id,url,title,visit_count,typed_count,last_visit_time,hidden) VALUES(?,?,?,?,?,?,0)", (i, u, t, 1, 0, ct(h)))
  db.execute("INSERT INTO visits(url,visit_time,transition) VALUES(?,?,?)", (i, ct(h), 805306368))
db.commit()
EOF
```

### 2. Launch

```sh
./run.sh --show
```

Expected: a translucent 680 pt-wide panel appears centred, slightly above the middle of the screen, with the placeholder `Say what you mean…`, five clickable example chips, `N apps, files and settings indexed` (85 on the VM) and `Jev · one judgment per keystroke` in the footer. `⌥Space` hides and shows it from any app. The menu bar shows a ⚡ item.

If the empty state says `TYPESAFE_API_KEY is not set — local matching only`, the key was not inherited; export it in the same shell or paste it in ⚡ → Settings….

Click a chip: the query fills in and the panel grows to fit the rows (56 pt each, at most seven) and shrinks again when the field is cleared.

### 3. The five queries

Type each query, wait for the leading `N ms` value in the footer to update, and check the top row.

| Query | Expected top row | Expected badge |
|---|---|---|
| `dark` | Toggle Dark Mode | green ↵, ≥ 90% |
| `wifi off` | Turn Wi-Fi Off above Turn Wi-Fi On | green ↵, ≥ 90% |
| `15% of 240` | `= 36` (orange `=` icon) | green ↵ |
| `the pdf I just downloaded` | `Q3-Roadmap-Review.pdf` (newest) above the other PDFs | green ↵ |
| `sleep` | Sleep | green ↵ |

The percentage on the right of each row is Jev's target probability; the selected row shows it in full, the others dimmed. A small blue dot at the right of the field is visible while a request is in flight; the header bolt turns green with the badge. `N decisions` increments once per keystroke and the leading latency settles around 100 ms after the first (TLS) request. At human typing speed the `(N stale)` count stays in single digits. Hover the footer for decisions/s and tokens per decision.

### 3b. Sets

| Query | Expected |
|---|---|
| `open devin ambassador links I visited in the past 24 hours` | top row `Open all 3 links` with green ↵ and 100%; the three Ambassador pages directly under it with blue checkmarks; GitHub / Hacker News / TypeSafe docs rows unchecked; the `?ref=tw` duplicate from 70 h ago absent (`docs/set-ambassador.png`) |
| `the files I downloaded in the last hour` | `Open all 3 files` on top; the three PDFs modified in the last hour checked; older PDFs absent |
| `the pdf I just downloaded` | unchanged: `Q3-Roadmap-Review.pdf` on top, **no** group row, no checkmarks |
| `pages about typesafe I read today` | `System One - TypeSafe Docs` on top, no group row (one match) |
| ↓ on a set query | selection moves through the members one by one; ↵ on a member opens just that one |

### 4. Enter executes

- `open devin ambassador links I visited in the past 24 hours` then ↵ on `Open all 3 links`: Chrome comes forward with three new tabs (the fixture URLs 404, which is fine). Nothing opens before ↵. Without Chrome installed the default browser opens them instead.
- `the files I downloaded in the last hour` then ↵: the three PDFs open in Preview.
- `15% of 240` then ↵: panel hides, `pbpaste` prints `36`.
- `dark` then ↵: the first time, macOS prompts to allow Launcher to control System Events; approve and the appearance flips. ↵ again flips it back.
- `wifi off` then ↵: Wi-Fi turns off (`networksetup -getairportpower en0` prints `Off`). `wifi on` then ↵ restores it.
- Any app row then ↵: the app activates.

Do not press ↵ on `sleep` or `Lock Screen` in a remote session unless you can wake the machine.

### 5. Failure handling (fuzzy fallback)

- `export TYPESAFE_API_KEY=invalid; ./run.sh --show`, type `dark`: rows appear in fuzzy order with no probabilities or badge, the footer shows `HTTP 401` in red, and the panel never stalls. Type `the pdf I just downloaded`: the two PDFs that tie on fuzzy score keep their index order, which is the difference Jev makes.
- Disconnect the network and type: same fuzzy fallback, footer shows the transport error instead. Once requests succeed again the footer returns to the latency line with `(N failed)` in the decision count.

## Permissions

| Feature | Permission | When prompted |
|---|---|---|
| Dark Mode, Sleep, Empty Trash | Automation → System Events / Finder (`NSAppleEventsUsageDescription`) | first execution of that toggle |
| Wi-Fi on/off | none on macOS 26; `networksetup` may ask for an admin password on some versions | on execution |
| Indexing `~/Downloads`, `~/Desktop`, `~/Documents` | none (app is unsandboxed); Desktop/Documents may prompt for folder access on first index | first panel show |
| Chrome history | none; `~/Library/Application Support` is readable without a prompt. Safari history would need Full Disk Access and is not read | — |
| ⌥Space hotkey | none (Carbon `RegisterEventHotKey`) | never |

No Accessibility, Screen Recording, or Full Disk Access is required. The VM user password (`MACOS_DEVIN_ADMIN_PASSWORD`) was not needed during verification.
