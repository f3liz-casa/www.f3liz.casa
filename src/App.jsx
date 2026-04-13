import { useState } from "preact/hooks";
import { locale, t, LANGS } from "./data/i18n";
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

  function setLang(newLang) {
    history.replaceState(null, "", "?lang=" + newLang);
    setLangState(newLang);
  }

  return (
    <div className="page">
      <TopBar lang={lang} setLang={setLang} />
      <div className="lang-fixed">
        <LangToggle lang={lang} setLang={setLang} />
      </div>
      <main className="main">
        <Hero tr={tr} />
        <div className="divider" />

        <div className="section-head">{tr.projects}</div>
        <ProjectList lang={lang} />
        <div className="divider" />

        <div className="section-head">{tr.connect}</div>
        <ConnectLinks tr={tr} />
        <div className="divider" />

        <div className="section-head">{tr.credits}</div>
        <Credits />

        <div className="thanks">{tr.thanks}</div>

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

