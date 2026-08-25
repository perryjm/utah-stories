---
name: ksl-feed
description: Use when the user types /ksl-feed, or asks to update the Utah Stories feeds, refresh the KSL Utah news feed, refresh the Deseret News Faith feed, or sync the utah-stories RSS feeds. Scrapes the initially-rendered KSL Utah News and Deseret News Faith listings via Playwright, skips stories already present in either feed, writes original non-verbatim summaries for new articles, prunes items older than two weeks, then commits and pushes the changed feed files from ~/sandbox/utah-stories/.
---

# Utah Stories Feed Updater

Incrementally maintains two separate RSS 2.0 feeds in `~/sandbox/utah-stories/`:

- `ksl-utah-news.xml` from `https://www.ksl.com/news/utah`
- `deseretnews-faith.xml` from `https://www.deseret.com/faith/`

One invocation updates both sources. Each run uses only the initially-rendered
listing, adds stories that have not already been processed, trims each feed to a
two-week shelf life, validates both files, and pushes the changed feed files.
Running the skill repeatedly is safe and does not reprocess an existing story.
When invoked by `scripts/ksl-feed-sync.py`, the visible parent wrapper process is
the expected caller, not a competing sync. Do not defer or ask to wait because
that process is active; use the wrapper's lock and clean-worktree guard for
concurrency.

## Copyright constraint — read first

KSL and Deseret Digital article bodies are copyrighted. **Never copy article
paragraphs, deks, descriptions, or lengthy quotes into either feed.** For every
new story, after reading the article, write a **3-5 sentence summary in your own
words** covering the key facts (who/what/when/where, notable figures, and named
sources) and put it in the item's `description` field. A short attributed phrase
is acceptable when useful, but the summary as a whole must be your own synthesis,
not a close paraphrase of the source. The listing teaser is not a substitute for
an original summary.

## Source rules

| Source | Listing | Output | Deduplication |
| --- | --- | --- | --- |
| KSL Utah News | `https://www.ksl.com/news/utah` | `ksl-utah-news.xml` | Numeric article ID extracted from each permalink |
| Deseret News Faith | `https://www.deseret.com/faith/` | `deseretnews-faith.xml` | Normalized canonical permalink |

The Deseret `/faith/atom.xml` endpoint is not a dependable well-formed source and
may contain article content. Do not use it for summaries or feed descriptions.
Use the section page and individual article pages instead.

## Steps

1. **Load both existing feeds before browsing.** For each output file, extract
   every `<guid isPermaLink="true">` and `<link>`. Treat the KSL numeric article
   ID as the identity because KSL can expose one story under multiple URL shapes.
   For Deseret, normalize the absolute URL by removing a query string and
   fragment, lowercasing the host, and normalizing a trailing slash; use the
   article page's canonical URL when one is provided. Never visit or summarize a
   story until its source-specific identity has been checked against the existing
   set.

2. **Open the source listings with Playwright.** Navigate to both listing URLs
   and take snapshots. On KSL, use the initially-rendered "Most Recent" list. On
   Deseret, collect only article links whose paths match the Faith section's
   dated article shape (`/faith/YYYY/MM/DD/...`). Do not click "Load More
   Stories", paginate, or use footer/recommended links as additional coverage.
   Repeated runs over time provide coverage without a bulk historical scrape.

3. **Filter genuinely new stories before article navigation.** Extract each
   KSL numeric ID and each Deseret normalized permalink, compare them with the
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
   - Restrict body extraction to the article itself, excluding navigation,
     related-story cards, comments, and advertisements.
   - If a required headline, author, date, or body cannot be identified, record
     an explicit error and stop rather than creating a success-shaped item.

5. **Build each new RSS item.** Use the article page's headline and canonical
   permalink for `title`, `link`, and `<guid isPermaLink="true">`; use the
   cleaned author name(s) for `dc:creator`; put the original 3-5 sentence
   synthesis in a CDATA-wrapped `description`; and convert the selected source
   timestamp to RFC 822 using `America/Denver` so daylight-saving offsets are
   correct. If a CDATA value contains `]]>`, split the terminator safely rather
   than emitting invalid XML. Insert new items at the top of their own channel
   in descending publication time.

6. **Close the browser in all paths.** After both source listings and all new
   article pages have been processed, call `mcp__playwright__browser_close`.
   Close it before local pruning, XML editing, or git work. If extraction fails
   after a browser was opened, close the browser before reporting the failure.

7. **Prune both feeds.** Compute the current 14-day cutoff and parse every
   existing item's RFC 822 `pubDate`. Remove items older than the cutoff from
   each feed, not only from the newly discovered stories. Report the pruned
   count separately for KSL and Deseret.

8. **Update build metadata only for changed feeds.** Set each changed channel's
   `lastBuildDate` to the current RFC 822 time in `America/Denver`. Leave an
   unchanged feed byte-for-byte stable so a no-op run does not create a needless
   commit.

9. **Validate both outputs before any commit.** Parse both files with Python's
   XML parser and verify that each item has exactly the expected title, link,
   guid, description, creator, and pubDate fields; every guid is unique; dates
   are parseable; and the item-count delta equals additions minus age prunes.
   Confirm that every Deseret item belongs to the Faith section and every KSL
   item has a KSL article URL. Do not continue to git operations if validation
   fails.

10. **Commit and push only feed outputs.** From `~/sandbox/utah-stories/`, stage
    only `ksl-utah-news.xml` and `deseretnews-faith.xml`, commit the files that
    changed with a source-neutral message such as
    `Add N KSL and M Deseret stories, prune P expired`, and push
    `origin main`. Skip the commit when neither feed changed. Never stage
    snapshots, logs, or unrelated worktree files.

11. **Report the complete result.** Include additions and titles per source,
    duplicate counts per source, age-prune counts per source, XML validation,
    browser closure, and commit/push status. If either source failed, identify
    it and do not claim a successful dual-feed sync.
