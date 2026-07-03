import type { Metadata } from "next";
import { Badge, NextLinks, Panel, PageHeader, Section } from "@/components/ui";
import { COMPONENTS, VALIDATED } from "@/content/status";

export const metadata: Metadata = { title: "Status" };

export default function Status() {
  return (
    <>
      <PageHeader
        tag="Status"
        index="06"
        title="What runs, what's in flight"
        lede="A snapshot of every major piece and where it stands. Live means it has been exercised on the device; in progress means it builds or partly runs; planned means it is designed but not yet standing up."
      />

      <Section num="06.1" title="Component reference">
        <div className="table-wrap">
          <table className="ref">
            <thead>
              <tr>
                <th>Component</th>
                <th>Role</th>
                <th>Track</th>
                <th>State</th>
              </tr>
            </thead>
            <tbody>
              {COMPONENTS.map((c) => (
                <tr key={c.name}>
                  <td>
                    <span className="mono">{c.name}</span>
                  </td>
                  <td className="desc">{c.role}</td>
                  <td className="desc">{c.track}</td>
                  <td>
                    <Badge state={c.state} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      <Section num="06.2" title="Validated on device">
        <Panel label="Reference device: iPad 7 (A10), iPadOS 17.6.1" fig="on-device">
          <ul style={{ margin: 0, paddingLeft: 20, lineHeight: 1.7, color: "var(--ink-2)" }}>
            {VALIDATED.map((v) => (
              <li key={v} style={{ marginBottom: 8 }}>
                {v}
              </li>
            ))}
          </ul>
        </Panel>
      </Section>

      <NextLinks path="/status" />
    </>
  );
}
