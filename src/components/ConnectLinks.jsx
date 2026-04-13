import { links } from "../data/links";

export function ConnectLinks({ tr }) {
  return (
    <div className="links-grid">
      {links.map((l) => (
        <a key={l.href} className="link-chip" href={l.href} target="_blank" rel="noreferrer">
          {l.icon}
          {l.label}
        </a>
      ))}
      <a className="tea-btn" href="https://buymeacoffee.com/nyanrus" target="_blank" rel="noreferrer">
        🧋 {tr.milktea}
      </a>
    </div>
  );
}
