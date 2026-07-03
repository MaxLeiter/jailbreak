"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { NAV, SITE } from "@/content/site";

export function Sidebar() {
  const path = usePathname();
  const [open, setOpen] = useState(false);

  const isActive = (href: string) =>
    href === "/" ? path === "/" : path.startsWith(href);
  const current = NAV.find((n) => isActive(n.href)) ?? NAV[0];

  return (
    <aside className="rail" data-open={open}>
      <button
        type="button"
        className="rail-toggle"
        aria-expanded={open}
        aria-controls="site-nav"
        onClick={() => setOpen((v) => !v)}
      >
        <span className="rt-brand">
          xi<b>OS</b>
        </span>
        <span className="rt-current">{current.label}</span>
        <span className="rt-icon" aria-hidden="true">
          {open ? "Close" : "Menu"}
        </span>
      </button>

      <div className="rail-body" id="site-nav">
        <Link
          href="/"
          className="brand"
          aria-label="xiOS wiki home"
          onClick={() => setOpen(false)}
        >
          <span className="brand-mark">Project wiki</span>
          <span className="brand-name">
            x<b>iOS</b>
          </span>
          <span className="brand-sub">
            X11 and Wayland, running native on jailbroken iOS.
          </span>
        </Link>

        <nav className="nav" aria-label="Sections">
          <span className="nav-group-label">Contents</span>
          {NAV.map((item) => {
            const active = isActive(item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                data-active={active}
                aria-current={active ? "page" : undefined}
                onClick={() => setOpen(false)}
              >
                <span className="idx" aria-hidden="true">
                  {item.idx}
                </span>
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
      </div>
    </aside>
  );
}
