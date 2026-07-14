import { Fragment } from "preact";
import { credits } from "../data/credits";
import { LANGS, htmlLang } from "../data/i18n";

const langLabel = Object.fromEntries(LANGS.map((l) => [l.key, l.label]));

export function Credits() {
  return (
    <ul className="credit-list" role="list">
      {credits.map((c) => (
        <li key={c.lang} className="credit-item">
          <span className="credit-tag" lang={htmlLang(c.lang)}>
            {langLabel[c.lang] ?? c.lang}
          </span>
          <a
            className="credit-name"
            href={c.url}
            target="_blank"
            rel="noreferrer"
            lang={htmlLang(c.lang)}
          >
            {c.ruby ? (
              <ruby>
                {c.ruby.map((seg, i) => (
                  <Fragment key={i}>
                    {seg.base}
                    {seg.rt && <rt>{seg.rt}</rt>}
                  </Fragment>
                ))}
              </ruby>
            ) : (
              c.name
            )}
          </a>
        </li>
      ))}
    </ul>
  );
}
