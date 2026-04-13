export function Badge({ badge }) {
  if (!badge) return <span style={{ width: 0 }} />;
  return <span className={`badge ${badge.type}`}>{badge.label}</span>;
}
