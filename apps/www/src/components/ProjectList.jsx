import { t } from "../data/i18n";
import { projects } from "../data/projects";
import { Badge } from "./Badge";

export function ProjectList({ lang }) {
  return (
    <ul className="proj-list" role="list">
      {projects.map((p, index) => {
        const description = t(p.desc, lang);
        const isExternal = /^https?:\/\//.test(p.href);
        // kaona: hidden paw appears on hover, only on the first card.
        // One smita per screen — see gentle-humor-research.md §5.1.
        const showPaw = index === 0;
        return (
          <li key={p.name}>
            <a
              className="proj-card"
              href={p.href}
              {...(isExternal && { target: "_blank", rel: "noreferrer" })}
              aria-label={`${p.name} — ${description}`}
            >
              <div className="proj-left">
                <div className="proj-name-row">
                  <span className="proj-name">{p.name}</span>
                  <span className="proj-lang">{p.lang}</span>
                </div>
                <span className="proj-desc">{description}</span>
              </div>
              <Badge badge={p.badge} />
              {showPaw && <span className="proj-paw" aria-hidden="true">ฅ^•ﻌ•^ฅ</span>}
            </a>
          </li>
        );
      })}
    </ul>
  );
}
