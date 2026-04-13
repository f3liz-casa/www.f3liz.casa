import { LangToggle } from "./LangToggle";

export function TopBar({ lang, setLang }) {
  return (
    <header className="topbar">
      <div className="topbar-logo">
        f3liz<span>.casa</span>
      </div>
      <LangToggle lang={lang} setLang={setLang} />
    </header>
  );
}
