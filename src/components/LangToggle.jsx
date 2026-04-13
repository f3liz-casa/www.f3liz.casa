import { LANGS } from "../data/i18n";

export function LangToggle({ lang, setLang }) {
  return (
    <div className="lang-row">
      {LANGS.map((l) => (
        <button
          key={l.key}
          className={`lang-btn${lang === l.key ? " active" : ""}`}
          onClick={() => setLang(l.key)}
        >
          {l.label}
        </button>
      ))}
    </div>
  );
}
