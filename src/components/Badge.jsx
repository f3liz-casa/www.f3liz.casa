export function Badge({ badge }) {
  if (!badge) return null;
  return <span className={`badge ${badge.type}`}>{badge.label}</span>;
}
