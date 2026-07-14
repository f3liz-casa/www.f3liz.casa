export function Hero({ tr, headingId }) {
  return (
    <div className="hero">
      <p className="hero-eyebrow">{tr.eyebrow}</p>
      <h1 id={headingId} className="hero-title">
        f3liz<span className="suffix">.casa</span>
      </h1>
      <p>
        <span
          className="hero-pronounce"
          lang="la"
          title="Latin for 'cat'"
          aria-label="pronunciation: felis — Latin for cat"
        >
          /felis/
        </span>
      </p>
      <div className="hero-card">
        <p className="hero-wish">{tr.wish}</p>
      </div>
    </div>
  );
}
