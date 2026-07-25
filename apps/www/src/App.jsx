import { useEffect, useState } from "preact/hooks";
import { locale, LANGS, htmlLang } from "./data/i18n";
import { TopBar } from "./components/TopBar";
import { LangToggle } from "./components/LangToggle";
import { Hero } from "./components/Hero";
import { ProjectList } from "./components/ProjectList";
import { ConnectLinks } from "./components/ConnectLinks";
import { Credits } from "./components/Credits";

const VALID_KEYS = new Set(LANGS.map((l) => l.key));
const MAJOR_LANGS = ["en", "ja", "ko"];

function detectMajorLang() {
  for (const tag of navigator.languages ?? [navigator.language]) {
    const primary = tag.split("-")[0].toLowerCase();
    if (MAJOR_LANGS.includes(primary)) return primary;
  }
  return "en";
}

function getLangFromURL() {
  const param = new URLSearchParams(window.location.search).get("lang");
  return param && VALID_KEYS.has(param) ? param : detectMajorLang();
}

export default function App() {
  const [lang, setLangState] = useState(getLangFromURL);
  const tr = locale(lang);

  useEffect(() => {
    document.documentElement.lang = htmlLang(lang);
  }, [lang]);

  function setLang(newLang) {
    history.replaceState(null, "", "?lang=" + newLang);
    setLangState(newLang);
  }

  return (
    <div className="page">
      <TopBar lang={lang} setLang={setLang} tr={tr} />
      <div className="lang-fixed">
        <LangToggle lang={lang} setLang={setLang} />
      </div>

      <main className="main">
        <section className="section" aria-labelledby="hero-heading">
          <Hero tr={tr} headingId="hero-heading" />
        </section>

        <section className="section" aria-labelledby="projects-heading">
          <h2 id="projects-heading" className="section-head">{tr.projects}</h2>
          <ProjectList lang={lang} />
        </section>

        <section className="section" aria-labelledby="connect-heading">
          <h2 id="connect-heading" className="section-head">{tr.connect}</h2>
          <ConnectLinks tr={tr} />
        </section>

        <section className="section" aria-labelledby="credits-heading">
          <h2 id="credits-heading" className="section-head">
            {tr.credits}
            {tr.creditsNote && (
              <span className="section-note"> ({tr.creditsNote})</span>
            )}
          </h2>
          <Credits />
        </section>

        <p className="thanks">{tr.thanks}</p>

        <footer className="foot">
          <span>f3liz.casa</span>
          <a href="https://github.com/nyanrus" target="_blank" rel="noreferrer">
            {tr.madeBy}
          </a>
        </footer>
      </main>
    </div>
  );
}
