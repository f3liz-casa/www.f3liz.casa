import { LANGS, htmlLang } from "../data/i18n";

export function LangToggle({ lang, setLang }) {
  return (
    <div className="lang-row" role="group" aria-label="Language">
      {LANGS.map((l) => {
        const isActive = lang === l.key;
        return (
          <button
            key={l.key}
            type="button"
            className="lang-btn"
            lang={htmlLang(l.key)}
            aria-pressed={isActive}
            onClick={() => setLang(l.key)}
          >
            {l.label}
          </button>
        );
      })}
    </div>
  );
}
