import Link from "next/link";
import type { ReactNode } from "react";
import { siblings } from "@/content/site";

/** External link that opens in a new tab. */
export function Ext({
  href,
  children,
}: {
  href: string;
  children: ReactNode;
}) {
  return (
    <a href={href} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}

export function PageHeader({
  tag,
  title,
  lede,
}: {
  tag: string;
  index?: string;
  title: string;
  lede: ReactNode;
}) {
  return (
    <header className="page-header">
      <div className="kicker">
        <span className="tag">{tag}</span>
      </div>
      <h1 className="page-title">{title}</h1>
      <p className="lede">{lede}</p>
    </header>
  );
}

export function Section({
  num,
  title,
  id,
  children,
}: {
  num: string;
  title: string;
  id?: string;
  children: ReactNode;
}) {
  return (
    <section className="section" id={id}>
      <div className="section-head">
        <span className="section-num" aria-hidden="true">
          {num}
        </span>
        <h2>{title}</h2>
      </div>
      {children}
    </section>
  );
}

type State = "live" | "wip" | "planned";
const STATE_LABEL: Record<State, string> = {
  live: "Live on device",
  wip: "In progress",
  planned: "Planned",
};

export function Badge({
  state,
  children,
}: {
  state: State;
  children?: ReactNode;
}) {
  return (
    <span className={`badge badge--${state}`}>
      <span className="dot" />
      {children ?? STATE_LABEL[state]}
    </span>
  );
}

export function Panel({
  label,
  fig,
  flush,
  children,
}: {
  label?: string;
  fig?: string;
  flush?: boolean;
  children: ReactNode;
}) {
  return (
    <div className={`panel${flush ? " panel--flush" : ""}`}>
      {label && (
        <div className="fig-label" style={flush ? { padding: "16px 20px 0" } : undefined}>
          <span>{label}</span>
          {fig && (
            <span>
              <b>{fig}</b>
            </span>
          )}
        </div>
      )}
      {children}
    </div>
  );
}

export function Callout({
  k,
  children,
}: {
  k?: string;
  children: ReactNode;
}) {
  return (
    <div className="callout">
      {k && <span className="callout-k">{k}</span>}
      <p>{children}</p>
    </div>
  );
}

/** A quiet, jargon-free aside that glosses a dense idea in plain language. */
export function PlainTerms({ children }: { children: ReactNode }) {
  return (
    <aside className="plain" aria-label="In plain terms">
      <span className="plain-k">In plain terms</span>
      <p>{children}</p>
    </aside>
  );
}

export function NextLinks({ path }: { path: string }) {
  const { prev, next } = siblings(path);
  return (
    <nav className="next-links" aria-label="Pager">
      {prev ? (
        <Link href={prev.href} className="prev">
          <span className="nl-k">← Previous</span>
          <span className="nl-t">{prev.label}</span>
        </Link>
      ) : (
        <span />
      )}
      {next ? (
        <Link href={next.href} className="next">
          <span className="nl-k">Next →</span>
          <span className="nl-t">{next.label}</span>
        </Link>
      ) : (
        <span />
      )}
    </nav>
  );
}
