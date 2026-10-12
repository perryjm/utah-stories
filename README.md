# Utah Stories feeds

This repository maintains four separate RSS feeds built from public article
listings:

- `ksl-utah-news.xml` — [KSL Utah News](https://www.ksl.com/news/utah)
- `deseretnews-faith.xml` — [Deseret News Faith](https://www.deseret.com/faith/)
- `wsj-cio-journal.xml` — [The Wall Street Journal: CIO Journal](https://www.wsj.com/cio-journal)
- `forbes-technology-council.xml` — [Forbes Technology Council](https://www.forbes.com/councils/forbestechcouncil/)

The `/ksl-feed` skill updates all four feeds in one run. It visits only the
initially-rendered listings and genuinely new article pages, writes brief
source-grounded summaries with short attributed quotes when available, prunes
items older than two weeks, validates the XML, and pushes only the feed files.
Article paragraphs, listing deks, descriptions, and lengthy quotes must not be
copied into the feeds because the source articles are copyrighted. WSJ pages may
require a subscription; the skill uses only text visible without bypassing access
controls.

## Install the tracked skill

The repository copy is the source of truth. Install it into the local Claude
skills directory with:

```sh
./scripts/install-ksl-feed-skill.sh
```

The installer can target a test location with `CLAUDE_SKILLS_DIR=/path/to/skills`.

## Run manually

After installation, invoke `/ksl-feed` from the Claude CLI. The skill reports
additions, duplicate skips, age-based pruning, browser closure, XML validation,
and push status for all four sources.

## Scheduled run

`scripts/local.utahstories.ksl-feed.plist` runs
`scripts/ksl-feed-sync.py` hourly. The wrapper enforces a 24-hour minimum between
successful runs, uses a process lock, refuses a dirty worktree, and stages only
`ksl-utah-news.xml` and `deseretnews-faith.xml`. Keep the existing launchd label
when reloading the job:

```sh
launchctl unload "$PWD/scripts/local.utahstories.ksl-feed.plist"
launchctl load "$PWD/scripts/local.utahstories.ksl-feed.plist"
```

The wrapper and skill share the repository's existing runbook and log locations.
