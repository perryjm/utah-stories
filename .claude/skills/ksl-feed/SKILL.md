---
name: ksl-feed
description: Use when the user types /ksl-feed, or asks to update the Utah Stories feeds, refresh the KSL Utah news feed, refresh the Deseret News Faith feed, refresh the Wall Street Journal CIO Journal feed, refresh the Forbes Technology Council feed, or sync the utah-stories RSS feeds. Scrapes the initially-rendered KSL Utah News, Deseret News Faith, WSJ CIO Journal, and Forbes Technology Council listings via Playwright, skips stories already present in any feed, writes brief source-grounded summaries with short direct quotes when available, prunes items older than two weeks, then commits and pushes the changed feed files from ~/sandbox/utah-stories/.
---

# Utah Stories Feed Updater

Incrementally maintains four separate RSS 2.0 feeds in `~/sandbox/utah-stories/`:

- `ksl-utah-news.xml` from `https://www.ksl.com/news/utah`
- `deseretnews-faith.xml` from `https://www.deseret.com/faith/`
- `wsj-cio-journal.xml` from `https://www.wsj.com/cio-journal`
- `forbes-technology-council.xml` from `https://www.forbes.com/councils/forbestechcouncil/`

One invocation updates all four sources. Each run uses only the initially-rendered
listings, adds stories that have not already been processed, trims each feed to a
two-week shelf life, validates all files, and pushes the changed feed files.
Running the skill repeatedly is safe and does not reprocess an existing story.
When invoked by `scripts/ksl-feed-sync.py`, the visible parent wrapper process is
the expected caller, not a competing sync. Do not defer or ask to wait because
that process is active; use the wrapper's lock and clean-worktree guard for
concurrency.

## Copyright constraint — read first

The source articles are copyrighted. **Do not copy article paragraphs, deks, or
descriptions into any feed.** For every new story, after reading the article,
write a brief, source-grounded summary of no more than 3 sentences in the item's
`description` field. Prefer the source's own wording where it makes the summary
more informative: include up to two short, exact, attributed direct quotes when
the article provides them, while keeping the total description concise and
avoiding lengthy or consecutive copied passages. Use the article's own words for
names, figures, technical terms, and distinctive characterizations, but keep the
surrounding facts compressed in your own synthesis. Never invent or silently
alter a quote. The listing teaser is not a substitute for the article.

## Source rules

| Source | Listing | Output | Deduplication |
| --- | --- | --- | --- |
| KSL Utah News | `https://www.ksl.com/news/utah` | `ksl-utah-news.xml` | Numeric article ID extracted from each permalink |
| Deseret News Faith | `https://www.deseret.com/faith/` | `deseretnews-faith.xml` | Normalized canonical permalink |
| Wall Street Journal: CIO Journal | `https://www.wsj.com/cio-journal` | `wsj-cio-journal.xml` | Normalized canonical permalink or stable article ID |
| Forbes Technology Council | `https://www.forbes.com/councils/forbestechcouncil/` | `forbes-technology-council.xml` | Normalized canonical permalink or stable article ID |

The Deseret `/faith/atom.xml` endpoint is not a dependable well-formed source and
may contain article content. Do not use it for summaries or feed descriptions.
Use the section page and individual article pages instead.

The WSJ section and individual articles may require a subscription and may expose
only a headline, metadata, excerpt, or selected text in the browser. Use only
material actually visible on the public page; do not bypass a paywall. If an
article does not expose enough source material to write a factual summary, record
an explicit error for that story and skip it rather than guessing. Do not use the
legacy WSJ RSS endpoint as a substitute for the section listing.

Forbes pages may include contributor profiles and promoted links alongside
articles. Collect only article links from the Forbes Technology Council section.
Use only material visible on the public page and do not bypass access controls.

## Steps

1. **Load all existing feeds before browsing.** For each output file, extract
   every `<guid isPermaLink="true">` and `<link>`. Treat the KSL numeric article
   ID as the identity because KSL can expose one story under multiple URL shapes.
   For Deseret, normalize the absolute URL by removing a query string and
   fragment, lowercasing the host, and normalizing a trailing slash; use the
   article page's canonical URL when one is provided. Never visit or summarize a
   story until its source-specific identity has been checked against the existing
   set.

2. **Open the source listings with Playwright.** These are public listings that
   need no login, so if more than one Playwright-family MCP server is
   connected, prefer an isolated/ephemeral-profile one (e.g. a plain
   `@playwright/mcp` server with no `--user-data-dir`) over one configured
   against a real personal browser profile (e.g. a `--user-data-dir` pointed at
   a live Brave/Chrome profile) — the latter can fail to launch a second
   instance whenever that browser is already open elsewhere, which is common
   during a scheduled run. Navigate to all four listing URLs and take snapshots. On
   Deseret, collect only article links whose paths match the Faith section's
   dated article shape (`/faith/YYYY/MM/DD/...`). Do not click "Load More
   Stories", paginate, or use footer/recommended links as additional coverage.
   On WSJ, collect only article links belonging to the CIO Journal section from
   the initially rendered listing; do not follow unrelated recommendations.
   On Forbes, collect only article links belonging to the Forbes Technology
   Council section from the initially rendered listing; do not follow contributor
   profiles, sponsored links, or unrelated recommendations.
   Repeated runs over time provide coverage without a bulk historical scrape.

3. **Filter genuinely new stories before article navigation.** Extract each
   KSL numeric ID, each Deseret normalized permalink, each WSJ article identity,
   and each Forbes article identity, compare them with the
   sets loaded in step 1, and keep only new identities. Do not re-fetch,
   re-visit, or re-summarize an existing story. Count skipped duplicates by
   source for the final report.

4. **Visit each new article and collect facts.** Use the article page, not the
   listing teaser, as the source of truth:

   - For KSL, read the article headline, body paragraphs, byline, and the full
     Posted/Updated date line. Use the later of Posted and Updated when both are
     present.
   - For Deseret, read the article `<h1>`, article body paragraphs, author/byline,
     and publication metadata. Prefer `dateModified` only when it is later than
     `datePublished`; otherwise use `datePublished`. The visible article
     timestamp is a fallback only when structured metadata is absent.
   - For WSJ, read the article `<h1>`, visible article text or excerpt, byline,
     and publication metadata. Prefer structured publication metadata when
     present. Capture short direct quotes only from text visible on the page.
   - For Forbes, read the article `<h1>`, visible article text or excerpt,
     contributor/byline, and publication metadata. Prefer structured publication
     metadata when present. Capture short direct quotes only from text visible on
     the page.
   - Restrict body extraction to the article itself, excluding navigation,
     related-story cards, comments, and advertisements.
   - If a required headline, author, date, or sufficient source text cannot be identified, record
     an explicit error and stop rather than creating a success-shaped item.

5. **Build each new RSS item.** Use the article page's headline and canonical
   permalink for `title`, `link`, and `<guid isPermaLink="true">`; use the
   cleaned author name(s) for `dc:creator`; put the brief source-grounded
   synthesis in a CDATA-wrapped `description`; and convert the selected source
   timestamp to RFC 822 using `America/Denver` so daylight-saving offsets are
   correct. If a CDATA value contains `]]>`, split the terminator safely rather
   than emitting invalid XML. Insert new items at the top of their own channel
   in descending publication time.

6. **Close the browser in all paths.** After all four source listings and all new
   article pages have been processed, call `mcp__playwright__browser_close`.
   Close it before local pruning, XML editing, or git work. If extraction fails
   after a browser was opened, close the browser before reporting the failure.

7. **Prune all four feeds.** Compute the current 14-day cutoff and parse every
   existing item's RFC 822 `pubDate`. Remove items older than the cutoff from
   each feed, not only from the newly discovered stories. Report the pruned
   count separately for each source.

8. **Update build metadata only for changed feeds.** Set each changed channel's
   `lastBuildDate` to the current RFC 822 time in `America/Denver`. Leave an
   unchanged feed byte-for-byte stable so a no-op run does not create a needless
   commit.

9. **Validate all outputs before any commit.** Parse all files with Python's
   XML parser and verify that each item has exactly the expected title, link,
   guid, description, creator, and pubDate fields; every guid is unique; dates
   are parseable; and the item-count delta equals additions minus age prunes.
   Confirm that every Deseret item belongs to the Faith section and every KSL
   item has a KSL article URL, and every WSJ item has a WSJ article URL and CIO
   Journal source identity, and every Forbes item has a Forbes article URL and
   Technology Council source identity. Do not continue to git operations if
   validation fails.

10. **Commit and push only feed outputs.** From `~/sandbox/utah-stories/`, stage
    only the four feed files, commit the files that
    changed with a source-neutral message such as
    `Add N KSL, M Deseret, Q WSJ, and R Forbes stories, prune P expired`, and push
    `origin main`. Skip the commit when no feed changed. Never stage
    snapshots, logs, or unrelated worktree files.

11. **Report the complete result.** Include additions and titles per source,
    duplicate counts per source, age-prune counts per source, XML validation,
    browser closure, and commit/push status. If either source failed, identify
    it and do not claim a successful four-feed sync.

12. **End with a machine-readable completion line.** The wrapper script
    (`scripts/ksl-feed-sync.py`) parses your final output for this exact line to
    decide whether to record the run as successful; get it right or a real
    failure will be silently recorded as success and the daily sync will stop
    running.

    - If, and only if, all four listings were genuinely opened and checked (via
      Playwright) and either the feeds were updated and validated per step 9,
      or there were validly zero new stories to add, end your response with
      exactly this line on its own:

      `KSL-FEED-SYNC: SUCCESS`

    - If you could not complete a real check of all four sources for any reason —
      required tools unavailable (e.g. no Playwright MCP tools connected),
      a source unreachable, validation failure, git error, or anything else
      that stopped you short of step 9 — do NOT print the success line. End
      with:

      `KSL-FEED-SYNC: FAILED — <short reason>`

      Never print the success line to be polite, to avoid raising an alarm, or
      because "nothing changed" when you didn't actually get to check. Only
      print it when the check genuinely happened.
