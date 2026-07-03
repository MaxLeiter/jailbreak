"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { NAV, SITE } from "@/content/site";

export function Sidebar() {
  const path = usePathname();

  return (
    <aside className="rail">
      <Link href="/" className="brand" aria-label="Xios wiki home">
        <span className="brand-mark">Project wiki</span>
        <span className="brand-name">
          XI<b>OS</b>
        </span>
        <span className="brand-sub">
          X11 and Wayland, running native on jailbroken iOS.
        </span>
      </Link>

      <nav className="nav" aria-label="Sections">
        <span className="nav-group-label">Contents</span>
        {NAV.map((item) => {
          const active =
            item.href === "/" ? path === "/" : path.startsWith(item.href);
          return (
            <Link key={item.href} href={item.href} data-active={active}>
              <span className="idx">{item.idx}</span>
              <span>{item.label}</span>
            </Link>
          );
        })}
      </nav>

      <div className="rail-foot">
        <div>
          Repo:{" "}
          <a href={SITE.repo} target="_blank" rel="noreferrer">
            repo.maxleiter.com
          </a>
        </div>
        <div>
          Made by{" "}
          <a href="https://maxleiter.com" target="_blank" rel="noreferrer">
            Max Leiter
          </a>
        </div>
      </div>
    </aside>
  );
}
