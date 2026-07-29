import type { ReactNode } from "react";
import { TERMS, type TermKey } from "@/content/terms";

/**
 * A glossed term. <T k="iosurface" /> prints the canonical label; pass children
 * when the sentence needs different wording ("IOSurfaces", "the compositor").
 *
 * The gloss itself lives in content/terms.ts so it reads the same on every page.
 */
export function T({ k, children }: { k: TermKey; children?: ReactNode }) {
  const t = TERMS[k];
  return <abbr title={t.def}>{children ?? t.label}</abbr>;
}

/** The same definitions, rendered as a list. Used by the glossary section. */
export function TermList({ keys }: { keys: TermKey[] }) {
  return (
    <dl className="deflist">
      {keys.map((k) => (
        <div className="row" key={k}>
          <dt>{TERMS[k].label}</dt>
          <dd>{TERMS[k].def}</dd>
        </div>
      ))}
    </dl>
  );
}
