import { credits } from "../data/credits";
import { LANGS } from "../data/i18n";

const langLabel = Object.fromEntries(LANGS.map((l) => [l.key, l.label]));

export function Credits() {
  return (
    <div className="credit-list">
      {credits.map((c) => (
        <div key={c.lang} className="credit-item">
          <span className="credit-tag">{langLabel[c.lang] ?? c.lang}</span>
          <a
            className="credit-name"
            href={c.url}
            target="_blank"
            rel="noreferrer"
          >
            {c.name}
          </a>
        </div>
      ))}
    </div>
  );
}
