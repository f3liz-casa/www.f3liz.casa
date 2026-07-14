import { links } from "../data/links";

export function ConnectLinks({ tr }) {
  return (
    <ul className="links-grid" role="list">
      {links.map((l) => (
        <li key={l.href}>
          <a
            className="link-chip"
            href={l.href}
            {...(/^https?:\/\//.test(l.href) && { target: "_blank", rel: "noreferrer" })}
          >
            <span aria-hidden="true">{l.icon}</span>
            <span>{l.label}</span>
          </a>
        </li>
      ))}
      <li>
        <a
          className="tea-btn"
          href="https://buymeacoffee.com/nyanrus"
          target="_blank"
          rel="noreferrer"
          aria-label={tr.milkteaAria}
        >
          {tr.milktea}
        </a>
      </li>
    </ul>
  );
}
