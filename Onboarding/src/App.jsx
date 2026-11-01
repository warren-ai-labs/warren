import { useEffect, useState } from "react";
import { useI18n } from "./i18n.jsx";
import { fetchChangelog, readCachedChangelog, writeCachedChangelog } from "./changelog.js";
import TerminalDemo from "./TerminalDemo.jsx";

const REPO_URL = "https://github.com/warren-ai-labs/warren";
const RELEASES_URL = `${REPO_URL}/releases/latest`;

function useDownload() {
  const [state, setState] = useState("idle");

  async function start() {
    if (state !== "idle") return;
    setState("loading");
    try {
      const response = await fetch("/api/download", {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!response.ok) throw new Error(`release API ${response.status}`);
      const release = await response.json();
      if (!release?.url) throw new Error("no release url");
      setState("ready");
      window.location.assign(release.url);
    } catch {
      setState("error");
      window.location.assign(RELEASES_URL);
    }
    window.setTimeout(() => setState("idle"), 4000);
  }

  return [state, start];
}

// Reveals are armed by script so the page still reads with no JavaScript and
// nothing stays hidden under prefers-reduced-motion. The check runs on scroll
// instead of on IntersectionObserver: a jump of a full screen or more must not
// skip a heading that never entered the trigger band.
function useReveal() {
  useEffect(() => {
    const root = document.documentElement;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) return;
    const pending = new Set(document.querySelectorAll("[data-reveal]"));
    if (!pending.size) return;
    root.classList.add("reveal-armed");

    let queued = false;
    const check = () => {
      queued = false;
      const limit = window.innerHeight * 0.92;
      for (const element of [...pending]) {
        if (element.getBoundingClientRect().top >= limit) continue;
        element.classList.add("is-in");
        pending.delete(element);
      }
      if (pending.size) return;
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
    };
    const schedule = () => {
      if (queued) return;
      queued = true;
      window.requestAnimationFrame(check);
    };

    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    check();
    return () => {
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      root.classList.remove("reveal-armed");
    };
  }, []);
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" fill="currentColor">
      <path d="M8 1.5a.75.75 0 0 1 .75.75v6.19l2.22-2.22a.75.75 0 1 1 1.06 1.06l-3.5 3.5a.75.75 0 0 1-1.06 0l-3.5-3.5a.75.75 0 1 1 1.06-1.06l2.22 2.22V2.25A.75.75 0 0 1 8 1.5Z" />
      <path d="M2.5 10.75a.75.75 0 0 1 .75.75v1.5c0 .414.336.75.75.75h8a.75.75 0 0 0 .75-.75v-1.5a.75.75 0 0 1 1.5 0v1.5A2.25 2.25 0 0 1 12 15.25H4a2.25 2.25 0 0 1-2.25-2.25v-1.5a.75.75 0 0 1 .75-.75Z" />
    </svg>
  );
}

function DownloadButton({ label, small = false, icon = false }) {
  const { t } = useI18n();
  const [state, start] = useDownload();
  const text = {
    idle: label,
    loading: t("download.loading"),
    ready: t("download.ready"),
    error: t("download.fallback"),
  }[state];
  return (
    <button
      type="button"
      className={`btn primary${small ? " small" : ""}`}
      onClick={start}
      disabled={state !== "idle"}
    >
      {icon ? <DownloadIcon /> : null}
      {text}
    </button>
  );
}

function Nav({ current = "home" }) {
  const { locale, setLocale, t } = useI18n();
  const onHome = current === "home";
  const base = onHome ? "" : "/";
  return (
    <header className="nav">
      <div className="wrap">
        <a className="brand" href={onHome ? "#top" : "/"}>
          <img src="/favicon.svg" alt="" width="20" height="20" />
          <span>Warren</span>
        </a>
        <nav className="nav-links" aria-label={t("nav.label")}>
          <a href={`${base}#anywhere`}>{t("nav.howItWorks")}</a>
          <a href={`${base}#demo`}>{t("nav.demo")}</a>
          <a
            className={onHome ? "" : "is-current"}
            href="/changelog"
            aria-current={onHome ? undefined : "page"}
          >
            {t("nav.changelog")}
          </a>
          <a href={REPO_URL} target="_blank" rel="noreferrer">
            GitHub
          </a>
        </nav>
        <div className="nav-right">
          <button
            type="button"
            className="lang-toggle"
            onClick={() => setLocale(locale === "zh" ? "en" : "zh")}
            lang={locale === "zh" ? "en" : "zh-CN"}
          >
            {locale === "zh" ? "English" : "中文"}
          </button>
          <DownloadButton label={t("nav.download")} small />
        </div>
      </div>
    </header>
  );
}

// The one live thing on the page: a session that outlives the window it runs in.
function SessionFragment() {
  const { t } = useI18n();
  const [away, setAway] = useState(false);
  const [visited, setVisited] = useState(false);
  const rows = t("frag.rows");

  function toggle() {
    setAway((current) => {
      if (!current) setVisited(true);
      return !current;
    });
  }

  return (
    <div className="frag-wrap" data-reveal>
      <div
        className={`frag${away ? " is-away" : ""}`}
        data-ui=""
        role="group"
        aria-label={t("frag.label")}
      >
        <div className="frag-head">
          <span className="frag-title">{t("frag.title")}</span>
          <span className="frag-clock">{away ? t("frag.closed") : t("frag.host")}</span>
        </div>
        <ul className="frag-rows">
          {rows.map((row) => (
            <li className={`frag-row${row.live ? " is-live" : ""}`} key={row.name}>
              <span className="frag-name">{row.name}</span>
              <span className="frag-meta">
                {row.agent} · {row.age}
              </span>
              <span className="frag-state">{row.state}</span>
            </li>
          ))}
        </ul>
        <div className="frag-log" aria-live="polite">
          <p className="frag-msg is-said">{t("frag.prompt")}</p>
          <p className="frag-msg">{t("frag.reply")}</p>
          {visited ? <p className="frag-msg is-new">{t("frag.away")}</p> : null}
          {visited && !away ? <p className="frag-msg is-note">{t("frag.back")}</p> : null}
        </div>
        <div className="frag-foot">
          <button type="button" className="frag-btn" onClick={toggle} aria-pressed={away}>
            {away ? t("frag.reopen") : t("frag.quit")}
          </button>
          <span className="frag-hint">{t("frag.hint")}</span>
        </div>
      </div>
    </div>
  );
}

function Hero() {
  const { t } = useI18n();
  const version = t("changelog.entries")[0]?.version;
  return (
    <section className="hero">
      <div className="wrap">
        <h1>
          <span className="hero-line">
            <span>{t("hero.titleA")}</span>
          </span>
          <span className="hero-line is-dim">
            <span>{t("hero.titleB")}</span>
          </span>
        </h1>
        <div className="hero-body">
          <div className="hero-copy">
            <p className="hero-lede" data-reveal>
              {t("hero.lede")}
            </p>
            <div className="actions" data-reveal>
              <DownloadButton label={t("hero.download")} icon />
              <a className="btn-link" href={REPO_URL} target="_blank" rel="noreferrer">
                {t("hero.source")}
              </a>
            </div>
            <p className="requirements" data-reveal>
              {version ? `v${version} · ` : ""}
              {t("hero.requirements")}
            </p>
          </div>
          <SessionFragment />
        </div>
      </div>
    </section>
  );
}

function Anywhere() {
  const { t } = useI18n();
  return (
    <section id="anywhere" className="block">
      <div className="wrap">
        <div className="head">
          <h2 data-reveal>{t("anywhere.title")}</h2>
          <p data-reveal>{t("anywhere.lede")}</p>
        </div>
        <div className="screens">
          <figure className="pane" data-reveal>
            <div className="pane-head">
              <span className="pane-title">{t("anywhere.browser")}</span>
              <span className="pane-path">warren / fix/resume-after-restart</span>
            </div>
            <img
              src="/screenshot-web-agent.png"
              alt={t("anywhere.browserAlt")}
              width="2880"
              height="1800"
              loading="lazy"
            />
          </figure>
          <figure className="pane pane-phone" data-reveal style={{ "--reveal-delay": "80ms" }}>
            <div className="pane-head">
              <span className="pane-title">{t("anywhere.phone")}</span>
            </div>
            <img
              src="/screenshot-mobile-agent.png"
              alt={t("anywhere.phoneAlt")}
              width="776"
              height="1688"
              loading="lazy"
            />
          </figure>
        </div>
        <p className="note" data-reveal>
          {t("anywhere.note")}
        </p>
      </div>
    </section>
  );
}

function Lifecycle() {
  const { t } = useI18n();
  const rows = t("lifecycle.rows");
  return (
    <section id="lifecycle" className="block">
      <div className="wrap">
        <div className="head">
          <h2 data-reveal>{t("lifecycle.title")}</h2>
          <p data-reveal>{t("lifecycle.lede")}</p>
        </div>
        <ul className="ledger" aria-label={t("lifecycle.label")}>
          {rows.map((row, index) => (
            <li
              className={`ledger-row${row.ends ? " ends" : ""}`}
              key={row.action}
              data-reveal
              style={{ "--reveal-delay": `${index * 60}ms` }}
            >
              <span className="ledger-action">{row.action}</span>
              <span className="ledger-state">
                <span className="running-dot" aria-hidden="true" />
                {row.ends ? t("lifecycle.ends") : t("lifecycle.running")}
              </span>
              <span className="ledger-why">{row.why}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

function Film() {
  const { t } = useI18n();
  const [playing, setPlaying] = useState(false);
  return (
    <figure data-reveal>
      <div className="film">
        {playing ? (
          <video
            src="/warren-promo.mp4"
            poster="/warren-promo-poster.jpg"
            controls
            autoPlay
            playsInline
          />
        ) : (
          // The film has sound, so it waits for a click rather than autoplaying.
          <button type="button" className="film-poster" onClick={() => setPlaying(true)}>
            <img src="/warren-promo-poster.jpg" alt="" loading="lazy" />
            <span className="film-play">
              <svg
                viewBox="0 0 16 16"
                width="16"
                height="16"
                fill="currentColor"
                aria-hidden="true"
              >
                <path d="M4.5 2.8v10.4a.6.6 0 0 0 .9.52l8.6-5.2a.6.6 0 0 0 0-1.04l-8.6-5.2a.6.6 0 0 0-.9.52Z" />
              </svg>
              {t("film.play")}
            </span>
          </button>
        )}
      </div>
      <figcaption>{t("film.caption")}</figcaption>
    </figure>
  );
}

function Demo() {
  const { t } = useI18n();
  return (
    <section id="demo" className="block">
      <div className="wrap">
        <div className="head">
          <h2 data-reveal>{t("demo.title")}</h2>
          <p data-reveal>{t("demo.lede")}</p>
        </div>
        <div className="duo">
          <Film />
          <TerminalDemo />
        </div>
      </div>
    </section>
  );
}

function Details() {
  const { t } = useI18n();
  const items = t("details.items");
  return (
    <section id="details" className="block">
      <div className="wrap details">
        <div className="details-head">
          <h2 data-reveal>{t("details.title")}</h2>
          <p data-reveal>{t("details.lede")}</p>
        </div>
        <div className="specs">
          {items.map((item, index) => (
            <div
              className="spec"
              key={item.title}
              data-reveal
              style={{ "--reveal-delay": `${(index % 2) * 60}ms` }}
            >
              <h3>{item.title}</h3>
              <p>{item.body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function HowItConnects() {
  const { t } = useI18n();
  return (
    <section id="how" className="block">
      <div className="wrap">
        <div className="head">
          <h2 data-reveal>{t("how.title")}</h2>
          <p data-reveal>{t("how.lede")}</p>
        </div>
        <div className="diagram" data-reveal>
          <div className="diagram-stack">
            {t("how.clients").map((client) => (
              <strong key={client}>{client}</strong>
            ))}
          </div>
          <div className="diagram-link">
            <span>WebSocket v1</span>
          </div>
          <div className="diagram-host">
            <strong>warren-headless</strong>
            <span>{t("how.host")}</span>
          </div>
          <div className="diagram-link">
            <span>Ghostline</span>
          </div>
          <div className="diagram-sessions">
            {[0, 1, 2].map((index) => (
              <span key={index}>
                <i className="running-dot" aria-hidden="true" />
                {t("how.session")}
              </span>
            ))}
            <small>{t("how.store")}</small>
          </div>
        </div>
        <p className="note" data-reveal>
          {t("how.note")}
        </p>
      </div>
    </section>
  );
}

function Start() {
  const { t } = useI18n();
  return (
    <section className="start">
      <div className="wrap">
        <h2 data-reveal>{t("close.title")}</h2>
        <div className="actions" data-reveal>
          <DownloadButton label={t("hero.download")} />
          <a className="btn-link" href="/changelog">
            {t("close.changelog")}
          </a>
        </div>
        <p className="requirements" data-reveal>
          {t("close.license")}
        </p>
      </div>
    </section>
  );
}

function Footer() {
  const { t } = useI18n();
  return (
    <footer className="footer">
      <div className="wrap">
        <span className="brand">
          <img src="/favicon.svg" alt="" width="16" height="16" />
          Warren
        </span>
        <span>warrenai.xyz</span>
        <nav aria-label={t("footer.label")}>
          <a href="/changelog">{t("nav.changelog")}</a>
          <a href={REPO_URL} target="_blank" rel="noreferrer">
            GitHub
          </a>
          <a href={`${REPO_URL}/blob/main/LICENSE`} target="_blank" rel="noreferrer">
            {t("footer.license")}
          </a>
        </nav>
      </div>
    </footer>
  );
}

function formatReleaseDate(dateISO, locale) {
  if (!dateISO) return "";
  const date = new Date(`${dateISO}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) return dateISO;
  return new Intl.DateTimeFormat(locale === "zh" ? "zh-CN" : "en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  }).format(date);
}

function ChangelogPage() {
  const { locale, t } = useI18n();
  const fallbackEntries = t("changelog.entries");
  const cachedEntries = readCachedChangelog()?.entries;
  const initialEntries = cachedEntries?.length ? cachedEntries : fallbackEntries;
  const [entries, setEntries] = useState(initialEntries);
  const [loadState, setLoadState] = useState(initialEntries.length ? "ready" : "loading");

  useEffect(() => {
    const controller = new AbortController();
    fetchChangelog(controller.signal)
      .then((nextEntries) => {
        writeCachedChangelog(nextEntries);
        setEntries(nextEntries);
        setLoadState("ready");
      })
      .catch((error) => {
        if (error.name === "AbortError") return;
        setLoadState(entries.length ? "stale" : "error");
      });
    return () => controller.abort();
  }, []);

  return (
    <>
      <Nav current="changelog" />
      <main className="wrap">
        <section className="changelog-hero">
          <h1>{t("changelog.title")}</h1>
          <p>{t("changelog.lede")}</p>
        </section>
        {loadState === "stale" ? <p className="changelog-status">{t("changelog.stale")}</p> : null}
        {loadState === "error" ? <p className="changelog-status">{t("changelog.error")}</p> : null}
        <section className="changelog-list" aria-label={t("changelog.title")}>
          {entries.map((entry) => (
            <article className="release-entry" key={entry.version}>
              <div className="release-meta">
                <span className="release-version">v{entry.version}</span>
                <time dateTime={entry.dateISO ?? undefined}>
                  {formatReleaseDate(entry.dateISO, locale)}
                </time>
                <a
                  className="release-link"
                  href={`${REPO_URL}/releases/tag/v${entry.version}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {t("changelog.viewRelease")} <span aria-hidden="true">↗</span>
                </a>
              </div>
              <div className="release-body">
                <h2>{entry.title ?? `${t("changelog.releaseTitle")} ${entry.version}`}</h2>
                {entry.summary ? <p className="release-summary">{entry.summary}</p> : null}
                {entry.sections.map((section, sectionIndex) => (
                  <section
                    className="release-section"
                    key={`${entry.version}-${section.title}-${sectionIndex}`}
                  >
                    <h3>{section.title}</h3>
                    <ul>
                      {section.items.map((item) => (
                        <li key={item}>{item}</li>
                      ))}
                    </ul>
                  </section>
                ))}
              </div>
            </article>
          ))}
        </section>
      </main>
      <Footer />
    </>
  );
}

function HomePage() {
  useEffect(() => {
    // The old #terminal link pointed straight at the WASM demo on page load.
    // Keep that legacy URL at the top; the #demo link remains opt-in.
    if (window.location.hash !== "#terminal") return;
    window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
    window.scrollTo({ top: 0, left: 0, behavior: "auto" });
  }, []);

  return (
    <>
      <Nav />
      <main id="top">
        <Hero />
        <Anywhere />
        <Lifecycle />
        <Demo />
        <Details />
        <HowItConnects />
        <Start />
      </main>
      <Footer />
    </>
  );
}

export default function App() {
  useReveal();
  const path = window.location.pathname.replace(/\/+$/, "") || "/";
  return path === "/changelog" ? <ChangelogPage /> : <HomePage />;
}
