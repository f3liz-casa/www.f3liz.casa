import { LangToggle } from "./LangToggle";

export function TopBar({ lang, setLang, tr }) {
  return (
    <header className="topbar">
      <a href="/" className="topbar-logo" aria-label="f3liz.casa — home">
        f3liz<span className="suffix">.casa</span>
      </a>
      <nav className="site-nav" aria-label={tr.sectionNavAria}>
        <a href="#projects-heading">{tr.projects}</a>
        <a href="#connect-heading">{tr.connect}</a>
      </nav>
      <LangToggle lang={lang} setLang={setLang} />
    </header>
  );
}
