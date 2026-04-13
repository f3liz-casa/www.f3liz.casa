import { t } from "../data/i18n";
import { projects } from "../data/projects";
import { Badge } from "./Badge";

export function ProjectList({ lang }) {
  return (
    <div className="proj-list">
      {projects.map((p) => (
        <a key={p.name} className="proj-card" href={p.href} target="_blank" rel="noreferrer">
          <div className="proj-left">
            <div className="proj-name-row">
              <span className="proj-name">{p.name}</span>
              <span className="proj-lang">{p.lang}</span>
            </div>
            <div className="proj-desc">{t(p.desc, lang)}</div>
          </div>
          <Badge badge={p.badge} />
          <span className="proj-paw">ฅ^•ﻌ•^ฅ</span>
        </a>
      ))}
    </div>
  );
}
