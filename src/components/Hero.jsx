export function Hero({ tr }) {
  return (
    <div className="hero">
      <div className="hero-eyebrow">{tr.eyebrow}</div>
      <div className="hero-title">
        f3liz<span className="dev">.casa</span>
      </div>
      <div>
        <span className="hero-pronounce">/ felis /</span>
      </div>
      <div style={{ height: "1.5rem" }} />
      <div className="hero-card">
        <div className="hero-wish">{tr.wish}</div>
        <div className="hero-nyaice">{tr.nyaice}</div>
      </div>
    </div>
  );
}
