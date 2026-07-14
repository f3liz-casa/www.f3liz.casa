import { LangToggle } from "./LangToggle";

export function TopBar({ lang, setLang }) {
  return (
    <header className="topbar">
      <a href="/" className="topbar-logo" aria-label="f3liz.casa — home">
        f3liz<span className="suffix">.casa</span>
      </a>
      <LangToggle lang={lang} setLang={setLang} />
    </header>
  );
}
